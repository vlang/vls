// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json
import time

const v_keywords = ['asm', 'as', 'assert', 'atomic', 'break', 'const', 'continue', 'defer', 'dump',
	'else', 'enum', 'false', 'fn', 'for', 'go', 'goto', 'if', 'ilike', 'implements', 'import',
	'in', 'interface', 'is', 'isreftype', 'like', 'lock', 'match', 'module', 'mut', 'nil', 'none',
	'or', 'pub', 'return', 'rlock', 'select', 'shared', 'sizeof', 'spawn', 'static', 'struct',
	'true', 'type', 'typeof', 'union', 'unsafe', 'volatile']!

const v_builtins = ['close', 'copy', 'eprintln', 'eprint', 'error', 'error_with_code', 'exit',
	'flush_stderr', 'flush_stdout', 'free', 'isnil', 'panic', 'print', 'println']!

// operation_at_pos handles LSP requests at a given position (completion, hover, signature, definition).
fn (mut app App) operation_at_pos(method Method, request Request) Response {
	params := json.decode(TextDocumentPositionParams, request.params) or {
		$if debug { log('Failed to decode TextDocumentPositionParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	if params.text_document.uri == '' {
		$if debug { log('operation_at_pos: missing textDocument.uri') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	line_nr := params.position.line + 1
	col := params.position.char
	path := params.text_document.uri

	// Intercept completion on import lines
	if method == .completion {
		if content := app.open_files[path] {
			lines := content.split_into_lines()
			if line_nr - 1 < lines.len {
				current_line := lines[line_nr - 1]
				if current_line.trim_space().starts_with('import') {
					work_dir := os.dir(uri_to_path(path))
					completions := get_import_completions(current_line, work_dir)
					if completions.len > 0 {
						return Response{
							id:     request.id
							result: CompletionList{
								is_incomplete: false
								items:         completions
							}
						}
					}
				}
			}
		}
	}

	line_info := match method {
		.completion {
			'${line_nr}:${col}'
		}
		.hover {
			'${line_nr}:hv^${col}'
		}
		.signature_help {
			'${line_nr}:fn^${col}'
		}
		.definition, .declaration, .type_definition, .implementation {
			'${line_nr}:gd^${col}'
		}
		else {
			''
		}
	}

	mut result := app.run_v_line_info(method, path, line_info)
	if method == .completion {
		// Check the character immediately before the cursor.
		// If it is not '.', the user is not doing member access, so augment
		// the compiler result with V keywords and builtins.
		cursor_line := params.position.line
		content := app.open_files[path] or { '' }
		lines := content.split_into_lines()
		trigger_char := if cursor_line < lines.len && col > 0 {
			line := lines[cursor_line]
			byte_col := utf8_char_to_byte_index(line, col - 1)
			if byte_col < line.len {
				line[byte_col].ascii_str()
			} else {
				''
			}
		} else {
			''
		}
		if trigger_char != '.' {
			mut details := []Detail{}
			if result is []Detail {
				details = result as []Detail
			}
			details << make_keyword_completions()
			// Build dedup map from compiler + keyword results.
			mut seen_labels := map[string]bool{}
			for d in details {
				seen_labels[d.label] = true
			}
			working_dir := os.dir(uri_to_path(path))
			// Augment with fn completions from sibling files in the same module.
			if working_dir != '' {
				module_fns := app.collect_module_fn_completions(path, working_dir)
				for d in module_fns {
					if d.label !in seen_labels {
						details << d
						seen_labels[d.label] = true
					}
				}
			}
			// Also include functions declared in the current file itself.
			// The compiler's -line-info does not always return all local functions
			// (e.g. at the start of a function body or when syntax errors exist).
			current_content := app.open_files[path] or { '' }
			for d in parse_module_fn_completions(current_content) {
				if d.label !in seen_labels {
					details << d
					seen_labels[d.label] = true
				}
			}
			return Response{
				id:     request.id
				result: CompletionList{
					is_incomplete: false
					items:         details
				}
			}
		}
		// Dot-triggered: keep compiler items and augment with imported module members,
		// so `os.` (or aliased imports) provides useful completions.
		mut dot_items := []Detail{}
		if result is []Detail {
			dot_items = result as []Detail
		}
		if cursor_line < lines.len && col > 0 {
			line := lines[cursor_line]
			module_alias := get_word_before_dot(line, col - 1)
			if module_alias != '' {
				module_aliases := parse_import_aliases(content)
				if module_path := module_aliases[module_alias] {
					working_dir := os.dir(uri_to_path(path))
					mut seen_labels := map[string]bool{}
					for d in dot_items {
						seen_labels[d.label] = true
					}
					for d in get_imported_module_member_completions(module_path, working_dir) {
						if d.label !in seen_labels {
							dot_items << d
							seen_labels[d.label] = true
						}
					}
				}
			}
		}
		return Response{
			id:     request.id
			result: CompletionList{
				is_incomplete: false
				items:         dot_items
			}
		}
	}
	$if debug {
		log(result.str())
	}
	return Response{
		id:     request.id
		result: result
	}
}

struct ImportedModuleBinding {
	alias       string
	module_path string
}

// get_word_before_dot returns the identifier immediately before a '.' character.
// `dot_col` is the character index of the dot itself.
fn get_word_before_dot(line string, dot_col int) string {
	if line == '' || dot_col < 0 {
		return ''
	}
	dot_byte := utf8_char_to_byte_index(line, dot_col)
	if dot_byte >= line.len || line[dot_byte] != `.` {
		return ''
	}
	if dot_byte == 0 || !is_ident_char(line[dot_byte - 1]) {
		return ''
	}
	mut start := dot_byte - 1
	for start > 0 && is_ident_char(line[start - 1]) {
		start--
	}
	return line[start..dot_byte]
}

// parse_import_aliases returns alias -> module path for simple V import statements.
// Examples: `import os` => os -> os, `import net.http` => http -> net.http,
// `import net.http as nh` => nh -> net.http.
fn parse_import_aliases(content string) map[string]string {
	mut aliases := map[string]string{}
	for binding in parse_import_bindings(content) {
		if binding.alias != '' && binding.module_path != '' {
			aliases[binding.alias] = binding.module_path
		}
	}
	return aliases
}

fn parse_import_bindings(content string) []ImportedModuleBinding {
	mut bindings := []ImportedModuleBinding{}
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if !trimmed.starts_with('import ') {
			continue
		}
		rest := trimmed[7..].trim_space()
		if rest == '' {
			continue
		}
		if rest.contains(' as ') {
			parts := rest.split(' as ')
			if parts.len < 2 {
				continue
			}
			module_path := parts[0].trim_space()
			alias := parts[1].trim_space()
			if module_path != '' && alias != '' {
				bindings << ImportedModuleBinding{
					alias:       alias
					module_path: module_path
				}
			}
			continue
		}
		module_path := rest.split(' ')[0].trim_space()
		if module_path == '' {
			continue
		}
		parts := module_path.split('.')
		alias := if parts.len > 0 { parts.last() } else { '' }
		if alias != '' {
			bindings << ImportedModuleBinding{
				alias:       alias
				module_path: module_path
			}
		}
	}
	return bindings
}

fn get_imported_module_member_completions(module_path string, work_dir string) []Detail {
	mut items := []Detail{}
	module_dir := resolve_import_module_dir(module_path, work_dir)
	if module_dir == '' {
		return items
	}
	mut seen_labels := map[string]bool{}
	for v_file in os.walk_ext(module_dir, '.v') {
		if v_file.ends_with('_test.v') {
			continue
		}
		content := os.read_file(v_file) or { continue }
		for item in parse_public_module_member_completions(content) {
			if item.label in seen_labels {
				continue
			}
			seen_labels[item.label] = true
			items << item
		}
	}
	return items
}

fn resolve_import_module_dir(module_path string, work_dir string) string {
	rel := module_path.replace('.', os.path_separator)
	vlib_dir := os.join_path(v_dir, 'vlib', rel)
	if os.is_dir(vlib_dir) {
		return vlib_dir
	}
	if work_dir != '' {
		local_dir := os.join_path(work_dir, rel)
		if os.is_dir(local_dir) {
			return local_dir
		}
	}
	return ''
}

fn parse_public_module_member_completions(content string) []Detail {
	mut items := []Detail{}
	mut in_pub_const_block := false
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed == '' || trimmed.starts_with('//') {
			continue
		}
		if trimmed == 'pub const (' {
			in_pub_const_block = true
			continue
		}
		if in_pub_const_block {
			if trimmed == ')' {
				in_pub_const_block = false
				continue
			}
			name := extract_const_name(trimmed)
			if name != '' {
				items << Detail{
					kind:   21 // CompletionItemKind.Constant
					label:  name
					detail: 'pub const'
				}
			}
			continue
		}
		if trimmed.starts_with('pub fn ') {
			after_fn := trimmed[7..]
			if after_fn.starts_with('(') {
				continue
			}
			paren_idx := after_fn.index('(') or { continue }
			fn_name := after_fn[..paren_idx].trim_space()
			if fn_name == '' || fn_name.contains(' ') || fn_name.contains('[') {
				continue
			}
			detail_str := trimmed.all_before('{').trim_space()
			insert := build_fn_snippet(fn_name, after_fn[paren_idx..])
			items << Detail{
				kind:               3 // CompletionItemKind.Function
				label:              fn_name
				detail:             detail_str
				insert_text:        insert
				insert_text_format: if insert.contains('$') { 2 } else { 1 }
			}
			continue
		}
		if trimmed.starts_with('pub const ') && trimmed != 'pub const (' {
			name := extract_const_name(trimmed[10..])
			if name != '' {
				items << Detail{
					kind:   21
					label:  name
					detail: 'pub const'
				}
			}
		}
	}
	return items
}

// on_did_open handles the LSP didOpen notification, loading file content into the server state.
fn (mut app App) on_did_open(request Request) {
	params := json.decode(DidOpenTextDocumentParams, request.params) or {
		$if debug { log('Failed to decode DidOpenTextDocumentParams: ${err}') }
		return
	}
	uri := params.text_document.uri
	log('on_did_open: ${uri}')
	mut content := ''
	if text := params.text_document.text {
		// Trust the client-provided in-memory text, including empty-string documents.
		content = text
	} else {
		real_path := uri_to_path(uri)
		content = os.read_file(real_path) or {
			$if debug { log('Failed to read file ${real_path}: ${err}') }
			return
		}
	}
	app.open_files[uri] = content
	if version := params.text_document.version {
		app.open_files_versions[uri] = version
	}
	app.open_files_generation++
	app.text = content
	$if debug { log('STORED CONTENT for uri=${uri}, FILE COUNT: ${app.open_files.len}') }
}

// on_did_close handles the LSP didClose notification by removing the file from tracked state.
fn (mut app App) on_did_close(request Request) {
	params := json.decode(DidCloseTextDocumentParams, request.params) or {
		$if debug { log('Failed to decode DidCloseTextDocumentParams: ${err}') }
		return
	}
	uri := params.text_document.uri
	if uri in app.open_files {
		app.open_files.delete(uri)
		app.open_files_generation++
	}
	if uri in app.open_files_versions {
		app.open_files_versions.delete(uri)
	}
}

fn (mut app App) build_diagnostics_notification(uri string, content string) Notification {
	if !app.diagnostics_enabled {
		return Notification{
			method: 'textDocument/publishDiagnostics'
			params: PublishDiagnosticsParams{
				uri:         uri
				version:     if uri in app.open_files_versions {
					?int(app.open_files_versions[uri])
				} else {
					none
				}
				diagnostics: []
			}
		}
	}
	v_errors := app.run_v_check(uri, content)
	log('run_v_check errors:${v_errors}')
	mut diagnostics := []LSPDiagnostic{}
	mut seen_positions := map[string]bool{}
	for v_err in v_errors {
		pos_key := '${v_err.line_nr}:${v_err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		diagnostics << v_error_to_lsp_diagnostic(v_err)
	}
	pd_params := PublishDiagnosticsParams{
		uri:         uri
		version:     if uri in app.open_files_versions {
			?int(app.open_files_versions[uri])
		} else {
			none
		}
		diagnostics: diagnostics
	}
	return Notification{
		method: 'textDocument/publishDiagnostics'
		params: pd_params
	}
}

// Returns instant red wavy errors
fn (mut app App) on_did_change(request Request) ?Notification {
	params := json.decode(DidChangeTextDocumentParams, request.params) or {
		$if debug { log('Failed to decode DidChangeTextDocumentParams: ${err}') }
		return none
	}
	log('on did change(len=${params.content_changes.len})')
	if params.content_changes.len == 0 {
		log('on_did_change() no params')
		return none
	}
	uri := params.text_document.uri
	mut content := app.open_files[uri] or { '' }
	for change in params.content_changes {
		if change.range != none {
			// Incremental change
			rng := change.range or {
				$if debug { log('Skipping malformed incremental change with missing range') }
				continue
			}

			content = apply_incremental_change(content, rng, change.text)
		} else {
			// Full text replacement
			content = change.text
		}
	}
	app.text = content
	app.open_files[uri] = content // Update tracked file
	if version := params.text_document.version {
		app.open_files_versions[uri] = version
	}
	app.open_files_generation++
	notification := app.build_diagnostics_notification(uri, content)
	$if debug { log('returning notification: ${notification}') }
	return notification
}

// on_did_save handles didSave by re-running diagnostics for the saved document.
fn (mut app App) on_did_save(request Request) ?Notification {
	params := json.decode(DidSaveTextDocumentParams, request.params) or {
		$if debug { log('Failed to decode DidSaveTextDocumentParams: ${err}') }
		return none
	}
	uri := params.text_document.uri
	mut content := app.open_files[uri] or { '' }
	if content == '' {
		if text := params.text {
			content = text
			app.open_files[uri] = text
			app.text = text
			app.open_files_generation++
		} else {
			real_path := uri_to_path(uri)
			content = os.read_file(real_path) or {
				$if debug { log('on_did_save: failed to read file ${real_path}: ${err}') }
				return none
			}
			app.open_files[uri] = content
			app.text = content
			app.open_files_generation++
		}
	}
	notification := app.build_diagnostics_notification(uri, content)
	return notification
}

// on_will_save_wait_until handles willSaveWaitUntil by formatting the document
// before it is saved, returning the edits to apply atomically with the save.
fn (mut app App) on_will_save_wait_until(request Request) Response {
	params := json.decode(WillSaveTextDocumentParams, request.params) or {
		$if debug { log('Failed to decode WillSaveTextDocumentParams: ${err}') }
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or {
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	edits, formatted := app.format_content(uri, content)
	if formatted != '' {
		app.open_files[uri] = formatted
		app.text = formatted
		app.open_files_generation++
	}
	return Response{
		id:     request.id
		result: edits
	}
}

// handle_prepare_rename handles textDocument/prepareRename by returning the range
// and placeholder text for the identifier under the cursor, or an empty result
// when the cursor is not on a renameable symbol.
fn (mut app App) handle_prepare_rename(request Request) Response {
	params := json.decode(TextDocumentPositionParams, request.params) or {
		$if debug { log('Failed to decode TextDocumentPositionParams for prepareRename: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	real_path := uri_to_path(params.text_document.uri)
	content := app.open_files[params.text_document.uri] or { os.read_file(real_path) or { '' } }
	lines := content.split_into_lines()
	if params.position.line >= lines.len {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	line_text := lines[params.position.line]
	start, end := find_word_bounds_at_col(line_text, params.position.char)
	if start < 0 || end <= start {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	symbol := line_text[start..end]
	if symbol == '' {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	// Identifiers used for rename must start with a letter or underscore.
	first := symbol[0]
	if !((first >= `a` && first <= `z`) || (first >= `A` && first <= `Z`) || first == `_`) {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	// Reject V keywords and built-in function names — they cannot be renamed.
	if symbol in v_keywords || symbol in v_builtins {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	return Response{
		id:     request.id
		result: PrepareRenameResult{
			range:       LSPRange{
				start: Position{
					line: params.position.line
					char: start
				}
				end:   Position{
					line: params.position.line
					char: end
				}
			}
			placeholder: symbol
		}
	}
}

fn add_workspace_symbol(mut results []WorkspaceSymbol, mut seen_symbols map[string]bool, name string,
	kind int, uri string, rng LSPRange) {
	key := '${name}|${uri}|${rng.start.line}:${rng.start.char}|${kind}'
	if key in seen_symbols {
		return
	}
	seen_symbols[key] = true
	results << WorkspaceSymbol{
		name:     name
		kind:     kind
		location: Location{
			uri:   uri
			range: rng
		}
	}
}

// find_word_bounds_at_col returns [start, end) bounds for the identifier at `col`.
// If `col` is just after an identifier, it still resolves that identifier.
fn find_word_bounds_at_col(line string, col int) (int, int) {
	if line == '' {
		return -1, -1
	}
	mut c := utf8_char_to_byte_index(line, col)
	if c >= line.len {
		c = line.len - 1
	}
	if c < 0 {
		return -1, -1
	}
	if !is_ident_char(line[c]) {
		if c > 0 && is_ident_char(line[c - 1]) {
			c--
		} else {
			return -1, -1
		}
	}
	mut start := c
	mut end := c + 1
	for start > 0 && is_ident_char(line[start - 1]) {
		start--
	}
	for end < line.len && is_ident_char(line[end]) {
		end++
	}
	return utf8_byte_to_char_index(line, start), utf8_byte_to_char_index(line, end)
}

// handle_workspace_symbol searches all tracked and on-disk .v files in the
// open project for symbols whose names contain the query string (case-insensitive)
// and returns them as WorkspaceSymbol items.
fn (mut app App) handle_workspace_symbol(request Request) Response {
	params := json.decode(WorkspaceSymbolParams, request.params) or {
		$if debug { log('Failed to decode WorkspaceSymbolParams: ${err}') }
		return Response{
			id:     request.id
			result: []WorkspaceSymbol{}
		}
	}
	query := params.query.to_lower()
	mut results := []WorkspaceSymbol{}
	mut searched_uris := map[string]bool{}
	mut seen_symbols := map[string]bool{}

	token := app.begin_progress('Searching workspace symbols…')

	// Determine working dirs from open files
	mut working_dirs := map[string]bool{}
	for uri, _ in app.open_files {
		dir := os.dir(uri_to_path(uri))
		if dir != '' && dir != '/' {
			working_dirs[dir] = true
		}
	}
	for root in app.workspace_roots {
		if root != '' && root != '/' {
			working_dirs[root] = true
		}
	}
	mut sorted_open_uris := app.open_files.keys()
	sorted_open_uris.sort()
	mut sorted_working_dirs := working_dirs.keys()
	sorted_working_dirs.sort()

	// Search open files first (in-memory)
	for uri in sorted_open_uris {
		if request.id in app.cancelled_requests {
			app.end_progress(token, '')
			return Response{
				id:     request.id
				result: results
			}
		}
		content := app.open_files[uri]
		searched_uris[uri] = true
		syms := parse_document_symbols(content)
		for sym in syms {
			if query == '' || sym.name.to_lower().contains(query) {
				add_workspace_symbol(mut results, mut seen_symbols, sym.name, sym.kind, uri,
					sym.selection_range)
			}
			// Also include children (struct fields and enum members)
			for child in sym.children {
				if query == '' || child.name.to_lower().contains(query) {
					add_workspace_symbol(mut results, mut seen_symbols,
						'${sym.name}.${child.name}', child.kind, uri, child.selection_range)
				}
			}
		}
	}

	// Search on-disk .v files not already tracked
	for dir in sorted_working_dirs {
		for v_file in os.walk_ext(dir, '.v') {
			if request.id in app.cancelled_requests {
				app.end_progress(token, '')
				return Response{
					id:     request.id
					result: results
				}
			}
			if v_file.ends_with('_test.v') {
				continue
			}
			uri := path_to_uri(v_file)
			if uri in searched_uris {
				continue
			}
			searched_uris[uri] = true
			content := os.read_file(v_file) or { continue }
			syms := parse_document_symbols(content)
			for sym in syms {
				if query == '' || sym.name.to_lower().contains(query) {
					add_workspace_symbol(mut results, mut seen_symbols, sym.name, sym.kind, uri,
						sym.selection_range)
				}
				for child in sym.children {
					if query == '' || child.name.to_lower().contains(query) {
						add_workspace_symbol(mut results, mut seen_symbols,
							'${sym.name}.${child.name}', child.kind, uri, child.selection_range)
					}
				}
			}
		}
	}

	app.end_progress(token, '')

	return Response{
		id:     request.id
		result: results
	}
}

// Helper to apply an incremental change to the document content
fn apply_incremental_change(content string, range LSPRange, new_text string) string {
	lines := content.split_into_lines()
	if lines.len == 0 {
		return new_text
	}
	start := range.start
	mut end_line := range.end.line
	mut end_char := range.end.char
	if start.line < 0 || end_line < 0 || start.line >= lines.len {
		return content
	}
	if end_line >= lines.len {
		end_line = lines.len - 1
		end_char = utf8_byte_to_char_index(lines[end_line], lines[end_line].len)
	}
	start_byte := utf8_char_to_byte_index(lines[start.line], start.char)
	end_byte := utf8_char_to_byte_index(lines[end_line], end_char)
	if end_line < start.line || (end_line == start.line && end_byte < start_byte) {
		return content
	}
	mut before := []string{}
	mut after := []string{}
	if start.line > 0 {
		before = lines[..start.line].clone()
	}
	if end_line + 1 < lines.len {
		after = lines[end_line + 1..].clone()
	}
	prefix := lines[start.line][..start_byte]
	suffix := lines[end_line][end_byte..]
	replacement := prefix + new_text + suffix
	mut result_lines := []string{}
	result_lines << before
	result_lines << replacement.split('\n')
	result_lines << after
	return result_lines.join('\n')
}

// find_references handles the LSP references request, returning all locations of a symbol.
fn (mut app App) find_references(request Request) Response {
	params := json.decode(ReferenceParams, request.params) or {
		$if debug { log('Failed to decode ReferenceParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	path := params.text_document.uri
	real_path := uri_to_path(path)
	line := params.position.line
	col := params.position.char

	// Get symbol name at cursor
	symbol := app.get_word_at_position(real_path, line, col)
	if symbol == '' {
		return Response{
			id:     request.id
			result: 'null'
		}
	}

	// Search all .v files in working directory
	working_dir := os.dir(real_path)
	search_dirs := app.workspace_search_dirs(working_dir)
	anchor := app.resolve_symbol_anchor(path, line, col)
	mut locations := if a := anchor {
		app.search_symbol_in_dirs_semantic(search_dirs, symbol, a, request.id)
	} else {
		app.search_symbol_in_dirs(search_dirs, symbol, request.id)
	}
	if locations.len == 0 {
		locations = app.search_symbol_in_dirs(search_dirs, symbol, request.id)
	}
	if !params.context.include_declaration {
		if a := anchor {
			mut filtered := []Location{}
			for loc in locations {
				if !same_anchor_location(loc, a) {
					filtered << loc
				}
			}
			locations = filtered.clone()
		}
	}
	if locations.len == 0 {
		return Response{
			id:     request.id
			result: 'null'
		}
	}

	return Response{
		id:     request.id
		result: locations
	}
}

// handle_rename handles the LSP rename request, returning edits to rename a symbol.
fn (mut app App) handle_rename(request Request) Response {
	params := json.decode(RenameParams, request.params) or {
		$if debug { log('Failed to decode RenameParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	path := params.text_document.uri
	real_path := uri_to_path(path)
	line := params.position.line
	col := params.position.char
	new_name := params.new_name

	// Get symbol name at cursor
	symbol := app.get_word_at_position(real_path, line, col)
	if symbol == '' {
		return Response{
			id:     request.id
			result: 'null'
		}
	}

	// Find all references
	working_dir := os.dir(real_path)
	search_dirs := app.workspace_search_dirs(working_dir)
	anchor := app.resolve_symbol_anchor(path, line, col)
	mut locations := if a := anchor {
		app.search_symbol_in_dirs_semantic(search_dirs, symbol, a, request.id)
	} else {
		app.search_symbol_in_dirs(search_dirs, symbol, request.id)
	}
	if locations.len == 0 {
		locations = app.search_symbol_in_dirs(search_dirs, symbol, request.id)
	}
	if locations.len == 0 {
		return Response{
			id:     request.id
			result: 'null'
		}
	}

	// Build WorkspaceEdit with both `changes` (compat) and `documentChanges` (preferred).
	mut changes := map[string][]TextEdit{}
	mut doc_changes := []TextDocumentEdit{}
	for loc in locations {
		end_char := if loc.range.end.char > loc.range.start.char {
			loc.range.end.char
		} else {
			loc.range.start.char + utf8_byte_to_char_index(symbol, symbol.len)
		}
		edit := TextEdit{
			range:    LSPRange{
				start: loc.range.start
				end:   Position{
					line: loc.range.start.line
					char: end_char
				}
			}
			new_text: new_name
		}
		if loc.uri in changes {
			changes[loc.uri] << edit
		} else {
			changes[loc.uri] = [edit]
		}
	}
	// Build documentChanges list from the same data.
	for uri, edits in changes {
		version := if uri in app.open_files_versions {
			?int(app.open_files_versions[uri])
		} else {
			none
		}
		doc_changes << TextDocumentEdit{
			text_document: VersionedTextDocumentIdentifier{
				uri:     uri
				version: version
			}
			edits:         edits
		}
	}

	return Response{
		id:     request.id
		result: WorkspaceEdit{
			changes:          changes
			document_changes: doc_changes
		}
	}
}

fn (app &App) get_word_at_position(file_path string, line int, col int) string {
	content := app.open_files[path_to_uri(file_path)] or {
		os.read_file(file_path) or { return '' }
	}
	lines := content.split_into_lines()
	if line >= lines.len {
		return ''
	}

	text := lines[line]
	byte_col := utf8_char_to_byte_index(text, col)
	if byte_col >= text.len {
		return ''
	}

	// Find word boundaries (V identifiers: letters, digits, underscores)
	mut start := byte_col
	mut end := byte_col
	for start > 0 && is_ident_char(text[start - 1]) {
		start--
	}
	for end < text.len && is_ident_char(text[end]) {
		end++
	}

	if start == end {
		return ''
	}
	return text[start..end]
}

fn is_ident_char(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_`
}

fn utf8_char_to_byte_index(s string, char_idx int) int {
	if char_idx <= 0 {
		return 0
	}
	mut byte_idx := 0
	mut char_count := 0
	for byte_idx < s.len && char_count < char_idx {
		b := s[byte_idx]
		if (b & 0x80) == 0 {
			byte_idx++
		} else if (b & 0xe0) == 0xc0 {
			byte_idx += 2
		} else if (b & 0xf0) == 0xe0 {
			byte_idx += 3
		} else if (b & 0xf8) == 0xf0 {
			byte_idx += 4
		} else {
			byte_idx++
		}
		char_count++
	}
	if byte_idx > s.len {
		return s.len
	}
	return byte_idx
}

fn utf8_byte_to_char_index(s string, byte_idx int) int {
	if byte_idx <= 0 {
		return 0
	}
	mut i := 0
	mut char_count := 0
	for i < s.len && i < byte_idx {
		b := s[i]
		if (b & 0x80) == 0 {
			i++
		} else if (b & 0xe0) == 0xc0 {
			i += 2
		} else if (b & 0xf0) == 0xe0 {
			i += 3
		} else if (b & 0xf8) == 0xf0 {
			i += 4
		} else {
			i++
		}
		char_count++
	}
	return char_count
}

// get_word_at_col extracts the identifier at column `col` within a single line.
// Returns '' if the character at `col` is not an identifier character.
fn get_word_at_col(line string, col int) string {
	byte_col := utf8_char_to_byte_index(line, col)
	if byte_col >= line.len {
		return ''
	}
	if !is_ident_char(line[byte_col]) {
		return ''
	}
	mut start := byte_col
	mut end := byte_col
	for start > 0 && is_ident_char(line[start - 1]) {
		start--
	}
	for end < line.len && is_ident_char(line[end]) {
		end++
	}
	if start == end {
		return ''
	}
	return line[start..end]
}

// find_declaration_line searches `lines` for a top-level declaration whose name
// exactly matches `symbol` and returns its 0-based line index, or -1 if not found.
fn find_declaration_line(lines []string, symbol string) int {
	for i, raw_line in lines {
		line := raw_line.trim_space()
		stripped := if line.starts_with('pub ') { line[4..] } else { line }
		decl_prefixes := ['fn ', 'struct ', 'enum ', 'interface ', 'type ', 'const ']
		for prefix in decl_prefixes {
			if stripped.starts_with(prefix) {
				rest := stripped[prefix.len..]
				// Handle method receivers: fn (recv) name(
				actual_rest := if rest.starts_with('(') {
					close := rest.index(')') or { break }
					rest[close + 1..].trim_space()
				} else {
					rest
				}
				name := first_word_paren(actual_rest)
				if name == symbol {
					return i
				}
				break
			}
		}
	}
	return -1
}

// extract_doc_comment walks backward from `decl_line` collecting consecutive
// `//` comment lines (V's vdoc convention) and returns them joined with newlines.
fn extract_doc_comment(lines []string, decl_line int) string {
	mut comments := []string{}
	mut i := decl_line - 1
	for i >= 0 {
		trimmed := lines[i].trim_space()
		if trimmed.starts_with('//') {
			comments << trimmed[2..].trim_space()
			i--
		} else {
			break
		}
	}
	if comments.len == 0 {
		return ''
	}
	comments = comments.reverse()
	// Use Markdown hard line breaks (two trailing spaces + newline) so each
	// comment line renders on its own line in the hover popup.
	return comments.join('  \n')
}

// get_module_name extracts the module name declared in V source content.
// Returns '' if no module declaration is found.
fn get_module_name(content string) string {
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.starts_with('module ') {
			name := trimmed[7..].trim_space()
			if name != '' {
				return name
			}
		}
	}
	return ''
}

// parse_imports extracts the module paths from `import` statements in `content`.
// Returns a list of module paths, e.g. ['os', 'math', 'v.util'].
fn parse_imports(content string) []string {
	mut imports := []string{}
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if !trimmed.starts_with('import ') {
			continue
		}
		rest := trimmed[7..].trim_space()
		// Strip optional `as alias` suffix
		module_path := rest.split(' ')[0].trim_space()
		if module_path != '' {
			imports << module_path
		}
	}
	return imports
}

// get_import_completions returns completion items for an `import` line.
// It lists vlib modules and local project modules matching the typed prefix.
fn get_import_completions(line string, work_dir string) []Detail {
	trimmed := line.trim_space()
	if !trimmed.starts_with('import') {
		return []
	}
	// typed is everything after 'import', e.g. '', 'enc', 'encoding', 'encoding.'
	typed := if trimmed.len > 7 { trimmed[7..].trim_space() } else { '' }

	mut results := []Detail{}

	// Split on '.' to determine nesting level.
	// e.g. 'encoding.' → parts = ['encoding', ''], base = ['encoding'], prefix = ''
	// e.g. 'encoding.b' → parts = ['encoding', 'b'], base = ['encoding'], prefix = 'b'
	// e.g. 'enc' → parts = ['enc'], base = [], prefix = 'enc'
	parts := typed.split('.')
	base_path_parts := parts[..parts.len - 1] // all but last
	prefix := parts.last() // filter on last segment

	// Build vlib search path
	vlib_dir := os.join_path(v_dir, 'vlib')
	search_dir := if base_path_parts.len > 0 {
		os.join_path(vlib_dir, base_path_parts.join(os.path_separator))
	} else {
		vlib_dir
	}

	// List matching subdirectories in vlib
	if os.is_dir(search_dir) {
		entries := os.ls(search_dir) or { [] }
		for entry in entries {
			if !entry.starts_with(prefix) {
				continue
			}
			full_path := os.join_path(search_dir, entry)
			if !os.is_dir(full_path) {
				continue
			}
			// Include dirs that contain at least one non-test .v file directly,
			// or that contain subdirectories (namespaces like encoding/).
			children := os.ls(full_path) or { [] }
			has_v := children.any(it.ends_with('.v') && !it.ends_with('_test.v'))
			has_subdir := children.any(os.is_dir(os.join_path(full_path, it)))
			if !has_v && !has_subdir {
				continue
			}
			results << Detail{
				kind:        9 // CompletionItemKind.Module
				label:       entry
				detail:      'V stdlib module'
				insert_text: entry
			}
		}
	}

	// Also add local project modules (top-level only, when no dots typed yet)
	if work_dir != '' && base_path_parts.len == 0 {
		entries := os.ls(work_dir) or { [] }
		for entry in entries {
			if !entry.starts_with(prefix) || entry.starts_with('.') {
				continue
			}
			full_path := os.join_path(work_dir, entry)
			if !os.is_dir(full_path) {
				continue
			}
			v_files := os.ls(full_path) or { [] }
			has_v := v_files.any(it.ends_with('.v') && !it.ends_with('_test.v'))
			if !has_v {
				continue
			}
			results << Detail{
				kind:        9
				label:       entry
				detail:      'Local module'
				insert_text: entry
			}
		}
	}

	return results
}

// find_doc_comment_for_symbol searches for the vdoc comment for `symbol` across
// multiple sources in priority order:
//  1. current file lines (already split)
//  2. other open files in app.open_files
//  3. all .v files in the project working directory
//  4. vlib/builtin/ (always, for built-in functions like println)
//  5. vlib/<module>/ for each module imported in the current file
fn (app &App) find_doc_comment_for_symbol(symbol string, current_lines []string, current_file_uri string) string {
	// 1. Current file
	decl_line := find_declaration_line(current_lines, symbol)
	if decl_line >= 0 {
		doc := extract_doc_comment(current_lines, decl_line)
		if doc != '' {
			return doc
		}
	}

	// 2 & 3. Other open files then all project .v files
	working_dir := os.dir(uri_to_path(current_file_uri))
	mut searched_uris := map[string]bool{}
	searched_uris[current_file_uri] = true

	// Search open files first (in memory, no disk I/O)
	for uri, content in app.open_files {
		if uri in searched_uris {
			continue
		}
		searched_uris[uri] = true
		lines := content.split_into_lines()
		dl := find_declaration_line(lines, symbol)
		if dl >= 0 {
			doc := extract_doc_comment(lines, dl)
			if doc != '' {
				return doc
			}
		}
	}

	// Search remaining .v files on disk in the working directory
	for v_file in os.walk_ext(working_dir, '.v') {
		uri := path_to_uri(v_file)
		if uri in searched_uris {
			continue
		}
		searched_uris[uri] = true
		content := os.read_file(v_file) or { continue }
		lines := content.split_into_lines()
		dl := find_declaration_line(lines, symbol)
		if dl >= 0 {
			doc := extract_doc_comment(lines, dl)
			if doc != '' {
				return doc
			}
		}
	}

	// 4. vlib/builtin/ — always search for built-in symbols
	builtin_dir := os.join_path(v_dir, 'vlib', 'builtin')
	if os.is_dir(builtin_dir) {
		doc := search_doc_in_vlib_dir(builtin_dir, symbol)
		if doc != '' {
			return doc
		}
	}

	// 5. Imported stdlib modules
	current_content := app.open_files[current_file_uri] or { '' }
	for module_path in parse_imports(current_content) {
		// Convert 'v.util' → 'v/util', 'os' → 'os'
		module_rel := module_path.replace('.', os.path_separator)
		module_dir := os.join_path(v_dir, 'vlib', module_rel)
		if !os.is_dir(module_dir) {
			continue
		}
		doc := search_doc_in_vlib_dir(module_dir, symbol)
		if doc != '' {
			return doc
		}
	}

	return ''
}

// search_doc_in_vlib_dir searches all non-test .v files in `dir` for a
// declaration of `symbol` and returns its vdoc comment, or '' if not found.
fn search_doc_in_vlib_dir(dir string, symbol string) string {
	for v_file in os.walk_ext(dir, '.v') {
		// Skip test files to avoid false positives and improve performance
		if v_file.ends_with('_test.v') {
			continue
		}
		content := os.read_file(v_file) or { continue }
		lines := content.split_into_lines()
		dl := find_declaration_line(lines, symbol)
		if dl >= 0 {
			doc := extract_doc_comment(lines, dl)
			if doc != '' {
				return doc
			}
		}
	}
	return ''
}

// format_content formats the given content via v fmt and returns the TextEdits
// needed to replace the document with its formatted version, plus the formatted
// text. Returns empty edits if the content is already properly formatted.
fn (mut app App) format_content(uri string, content string) ([]TextEdit, string) {
	real_path := uri_to_path(uri)

	temp_file := os.join_path(os.temp_dir(), 'vls_fmt_${os.getpid()}_${os.file_name(real_path)}')
	os.write_file(temp_file, content) or {
		log('Failed to write temp file for formatting: ${err}')
		return []TextEdit{}, ''
	}

	// With -w flag, v fmt writes the formatted content back to the temp file.
	// Read from there instead of relying on stdout capture, which is
	// unreliable on Windows MSYS2.
	result := os.execute(ensure_stderr_captured(build_v_fmt_cmd(temp_file)))

	mut formatted := os.read_file(temp_file) or { result.output }

	os.rm(temp_file) or {
		$if debug { log('Failed to remove temp file: ${err}') }
	}

	if result.exit_code != 0 {
		$if debug { log('v fmt failed with code ${result.exit_code}: ${result.output}') }
		return []TextEdit{}, ''
	}

	if formatted == '' || formatted == content {
		return []TextEdit{}, ''
	}

	lines := content.split_into_lines()
	last_line := lines.len - 1
	last_char := if lines.len > 0 { lines[last_line].len } else { 0 }

	edit := TextEdit{
		range:    LSPRange{
			start: Position{
				line: 0
				char: 0
			}
			end:   Position{
				line: last_line
				char: last_char
			}
		}
		new_text: formatted
	}
	return [edit], formatted
}

// handle_formatting handles the LSP formatting request, returning edits to format the document.
fn (mut app App) handle_formatting(request Request) Response {
	params := json.decode(DocumentFormattingParams, request.params) or {
		log('Failed to decode DocumentFormattingParams: ${err}')
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	path := params.text_document.uri
	real_path := uri_to_path(path)

	content := app.open_files[path] or {
		os.read_file(real_path) or {
			log('Failed to read file for formatting: ${err}')
			return Response{
				id:     request.id
				result: []TextEdit{}
			}
		}
	}

	edits, _ := app.format_content(path, content)
	return Response{
		id:     request.id
		result: edits
	}
}

// handle_document_symbols handles the LSP documentSymbol request, returning top-level symbols.
fn (mut app App) handle_document_symbols(request Request) Response {
	params := json.decode(DocumentSymbolParams, request.params) or {
		log('Failed to decode DocumentSymbolParams: ${err}')
		return Response{
			id:     request.id
			result: []DocumentSymbol{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { '' }
	symbols := parse_document_symbols(content)
	return Response{
		id:     request.id
		result: symbols
	}
}

// handle_inlay_hints handles the LSP inlayHint request, returning type hints for variables.
fn (mut app App) handle_inlay_hints(request Request) Response {
	if !app.inlay_hints_enabled {
		return Response{
			id:     request.id
			result: []InlayHint{}
		}
	}
	params := json.decode(InlayHintParams, request.params) or {
		log('Failed to decode InlayHintParams: ${err}')
		return Response{
			id:     request.id
			result: []InlayHint{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { '' }
	lines := content.split_into_lines()
	start_line := params.range.start.line
	end_line := params.range.end.line

	// Build fn index lazily: current file + open files + vlib modules imported in this file
	file_path := uri_to_path(uri)
	working_dir := os.dir(file_path)
	mut index_files := []string{}

	// Collect all open file paths
	for open_uri, _ in app.open_files {
		p := uri_to_path(open_uri)
		if p != '' && p != file_path {
			index_files << p
		}
	}

	// Only scan project directory if working_dir is a real, accessible directory.
	// Guard against fake URIs (e.g. tests using file:///test.v) which resolve
	// working_dir to '/' and would cause a full filesystem walk.
	if working_dir != '' && working_dir != '/' && os.is_dir(working_dir) {
		project_files := os.walk_ext(working_dir, '.v')
		for pf in project_files {
			if !pf.ends_with('_test.v') && pf != file_path {
				index_files << pf
			}
		}

		// Add vlib modules imported by this file
		imported_mods := parse_imports(content)
		for mod in imported_mods {
			mod_path := mod.replace('.', '/')
			vlib_mod_dir := os.join_path(v_dir, 'vlib', mod_path)
			if os.is_dir(vlib_mod_dir) {
				vlib_files := os.walk_ext(vlib_mod_dir, '.v')
				for vf in vlib_files {
					if !vf.ends_with('_test.v') {
						index_files << vf
					}
				}
			}
		}
	}

	mut fn_index := build_fn_index(index_files)
	// Also index functions defined in the current file (in-memory content).
	parse_fn_signatures_into(content, '', mut fn_index)

	mut hints := []InlayHint{}
	mut in_const_block := false
	for line_idx in start_line .. (end_line + 1) {
		if line_idx >= lines.len {
			break
		}
		raw := lines[line_idx]
		trimmed := raw.trim_space()

		// Skip comments and blank lines
		if trimmed == '' || trimmed.starts_with('//') {
			continue
		}

		// Track const block boundaries
		if trimmed == 'const (' {
			in_const_block = true
			continue
		}
		if in_const_block && trimmed == ')' {
			in_const_block = false
			continue
		}

		mut var_name := ''
		mut rhs := ''

		if in_const_block {
			// Inside `const (` block: lines look like `name = value`
			eq_idx := trimmed.index(' = ') or { continue }
			var_name = trimmed[..eq_idx].trim_space()
			rhs = trimmed[eq_idx + 3..].trim_space()
		} else if trimmed.starts_with('const ') && trimmed.contains(' = ') {
			// Single-line const: `const name = value`
			after_const := trimmed[6..]
			eq_idx := after_const.index(' = ') or { continue }
			var_name = after_const[..eq_idx].trim_space()
			rhs = after_const[eq_idx + 3..].trim_space()
		} else {
			// Short variable declaration: `name := value` or `mut name := value`
			assign_idx := trimmed.index(' := ') or { continue }
			lhs := trimmed[..assign_idx].trim_space()
			rhs = trimmed[assign_idx + 4..].trim_space()
			var_name = lhs
			if lhs.starts_with('mut ') {
				var_name = lhs[4..].trim_space()
			}
		}

		// Skip multi-assignment or invalid identifiers
		if var_name.contains(' ') || var_name.contains(',') || var_name == '' {
			continue
		}

		// Strip error-handling suffix from RHS: `os.read_file(p) or { [] }` → `os.read_file(p)`
		mut clean_rhs := rhs
		if or_idx := rhs.index(' or ') {
			clean_rhs = rhs[..or_idx].trim_space()
		}
		if q_idx := rhs.index(' ?') {
			_ = q_idx // optional chaining — leave as is
		}

		// Try literal inference first, then fn index lookup
		mut inferred := infer_type_from_literal(clean_rhs)
		if inferred == '' {
			inferred = lookup_fn_return_type(clean_rhs, fn_index)
			// Strip result/optional prefix for display: `!string` → `string`, `?string` → `?string`
			if inferred.starts_with('!') {
				inferred = inferred[1..]
			}
		}
		if inferred == '' {
			continue
		}

		// Position the hint right after the variable name in the raw line
		name_col := raw.index(var_name) or { continue }
		hints << InlayHint{
			position:     Position{
				line: line_idx
				char: name_col + var_name.len
			}
			label:        ': ${inferred}'
			kind:         inlay_hint_kind_type
			padding_left: false
		}
	}

	return Response{
		id:     request.id
		result: hints
	}
}

// infer_type_from_literal returns the V type name for a simple literal RHS value,
// or '' if the type cannot be determined without compiler assistance.
fn infer_type_from_literal(rhs string) string {
	r := rhs.trim_space()
	if r == '' {
		return ''
	}
	// Boolean
	if r == 'true' || r == 'false' {
		return 'bool'
	}
	// String literals: single-quote, double-quote, or backtick
	first := r[0]
	if first == `'` || first == `"` || first == '`'[0] {
		return 'string'
	}
	// Already explicitly typed (struct/array/map init): skip
	if r.contains('{') || r.contains('[') {
		return ''
	}
	// Float literal: contains a '.' and digits only
	if r.contains('.') {
		mut is_float := true
		for c in r {
			if !((c >= `0` && c <= `9`) || c == `.` || c == `-` || c == `_`) {
				is_float = false
				break
			}
		}
		if is_float {
			return 'f64'
		}
	}
	// Integer literal: hex (0x), octal (0o), binary (0b), or plain digits
	if r.starts_with('0x') || r.starts_with('0X') || r.starts_with('0o') || r.starts_with('0b') {
		return 'int'
	}
	mut is_int := true
	for c in r {
		if !((c >= `0` && c <= `9`) || c == `-` || c == `_`) {
			is_int = false
			break
		}
	}
	if is_int && r.len > 0 {
		return 'int'
	}
	return ''
}

// extract_fn_call parses a RHS expression like `os.temp_dir()` or `get_value()`
// and returns (module_name, fn_name). Returns ('', '') if not a simple call.
// Skips method calls on receivers (e.g. `obj.method()`).
fn extract_fn_call(rhs string) (string, string) {
	r := rhs.trim_space()
	// Must end with `)` (allowing trailing comments stripped by caller)
	if !r.ends_with(')') {
		return '', ''
	}
	// Find the opening paren
	paren_idx := r.index('(') or { return '', '' }
	call_part := r[..paren_idx]

	if call_part.contains('.') {
		// Could be `module.fn` or `receiver.method` — only handle one dot
		dot_idx := call_part.last_index('.') or { return '', '' }
		mod_part := call_part[..dot_idx]
		fn_part := call_part[dot_idx + 1..]
		// Skip if module part looks like a variable (lowercase first char only heuristic
		// won't work reliably, so we allow both and let the index miss on methods)
		if mod_part == '' || fn_part == '' {
			return '', ''
		}
		return mod_part, fn_part
	}
	// Plain call: `get_value()`
	if call_part == '' {
		return '', ''
	}
	return '', call_part
}

// parse_fn_signatures_into scans V source `content` for simple fn declarations
// and populates `index` with fn_name → return_type and mod_name.fn_name → return_type.
// Only captures non-method, non-multi-return, non-void signatures.
fn parse_fn_signatures_into(content string, mod_name string, mut index map[string]string) {
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		// Match `fn name(` or `pub fn name(`
		mut after_fn := ''
		if trimmed.starts_with('pub fn ') {
			after_fn = trimmed[7..]
		} else if trimmed.starts_with('fn ') {
			after_fn = trimmed[3..]
		} else {
			continue
		}
		// Skip method receivers: `(mut app App) name(`
		if after_fn.starts_with('(') {
			continue
		}
		paren_idx := after_fn.index('(') or { continue }
		fn_name := after_fn[..paren_idx].trim_space()
		if fn_name == '' || fn_name.contains(' ') || fn_name.contains('[') {
			continue
		}
		// Find closing paren to locate return type
		close_paren := after_fn.index(')') or { continue }
		after_params := after_fn[close_paren + 1..].trim_space()
		// after_params could be: `string {`, `!string {`, `?string {`,
		// `(string, int) {` (multi-return — skip), ` {` (void — skip)
		if after_params == '' || after_params.starts_with('{') {
			continue
		}
		// Multi-return: starts with `(`
		if after_params.starts_with('(') {
			continue
		}
		// Strip trailing ` {` or just `{`
		ret := after_params.all_before('{').trim_space()
		if ret == '' {
			continue
		}
		index[fn_name] = ret
		if mod_name != '' {
			index['${mod_name}.${fn_name}'] = ret
		}
	}
}

// build_fn_index scans the given V source files and returns a map of
// fn_name → return_type and module_prefix.fn_name → return_type.
// Only captures simple (non-method, non-multi-return) signatures.
fn build_fn_index(files []string) map[string]string {
	mut index := map[string]string{}
	for fpath in files {
		content := os.read_file(fpath) or { continue }
		mod_name := os.file_name(fpath).replace('.v', '')
		parse_fn_signatures_into(content, mod_name, mut index)
	}
	return index
}

// lookup_fn_return_type looks up the return type of a function call RHS in the
// provided index. For qualified calls like `os.temp_dir()`, it checks both
// `os.temp_dir` and just `temp_dir`.
fn lookup_fn_return_type(rhs string, index map[string]string) string {
	mod_name, fn_name := extract_fn_call(rhs)
	if fn_name == '' {
		return ''
	}
	// Strip any error handling suffix from RHS for lookup: `os.read_file(p) or { ... }`
	// extract_fn_call already handles plain `)` endings; but callers may pass full line
	if mod_name != '' {
		qualified := '${mod_name}.${fn_name}'
		if qualified in index {
			return index[qualified]
		}
	}
	if fn_name in index {
		return index[fn_name]
	}
	return ''
}

// parse_document_symbols scans `content` line by line and extracts top-level
// V declarations: functions, methods, structs, enums, interfaces, constants,
// and type aliases. Struct fields and enum members are returned as children.
fn parse_document_symbols(content string) []DocumentSymbol {
	lines := content.split_into_lines()
	mut symbols := []DocumentSymbol{}
	// Track whether we are inside a struct or enum block to collect children.
	mut in_struct := false
	mut in_enum := false
	mut current_parent_idx := -1 // index into `symbols` for the current parent

	for i, raw_line in lines {
		line := raw_line.trim_space()

		// Skip blank lines and pure comment lines
		if line == '' || line.starts_with('//') {
			continue
		}

		// Closing brace ends a struct/enum body
		if line == '}' {
			in_struct = false
			in_enum = false
			current_parent_idx = -1
			continue
		}

		// Inside a struct body — collect field names
		if in_struct && current_parent_idx >= 0 {
			// Field lines look like `name  Type` or `mut:` / `pub:` etc.
			// Skip access modifier lines
			if line == 'mut:' || line == 'pub:' || line == 'pub mut:' || line == '__global:' {
				continue
			}
			// First token before whitespace is the field name
			field_name := first_word(line)
			if field_name != '' && !field_name.starts_with('//') {
				child := make_symbol(field_name, sym_kind_field, i, raw_line)
				symbols[current_parent_idx].children << child
			}
			continue
		}

		// Inside an enum body — collect member names
		if in_enum && current_parent_idx >= 0 {
			member_name := first_word(line)
			if member_name != '' && !member_name.starts_with('//') {
				child := make_symbol(member_name, sym_kind_enum_member, i, raw_line)
				symbols[current_parent_idx].children << child
			}
			continue
		}

		// Collect an optional leading `pub ` so we can strip it for name extraction
		stripped := if line.starts_with('pub ') { line[4..] } else { line }

		if stripped.starts_with('fn ') {
			name := extract_fn_name(stripped[3..])
			if name == '' {
				continue
			}
			kind := if name.contains(') ') {
				// receiver present → method
				sym_kind_method
			} else {
				sym_kind_function
			}
			symbols << make_symbol(name, kind, i, raw_line)
		} else if stripped.starts_with('struct ') {
			name := first_word(stripped[7..])
			if name != '' {
				symbols << make_symbol(name, sym_kind_struct, i, raw_line)
				// Enter struct body if the opening brace is on the same line
				if line.contains('{') && !line.contains('}') {
					in_struct = true
					in_enum = false
					current_parent_idx = symbols.len - 1
				}
			}
		} else if stripped.starts_with('enum ') {
			name := first_word(stripped[5..])
			if name != '' {
				symbols << make_symbol(name, sym_kind_enum, i, raw_line)
				if line.contains('{') && !line.contains('}') {
					in_enum = true
					in_struct = false
					current_parent_idx = symbols.len - 1
				}
			}
		} else if stripped.starts_with('interface ') {
			name := first_word(stripped[10..])
			if name != '' {
				symbols << make_symbol(name, sym_kind_interface, i, raw_line)
			}
		} else if stripped.starts_with('const ') {
			name := extract_const_name(stripped[6..])
			if name != '' {
				symbols << make_symbol(name, sym_kind_constant, i, raw_line)
			}
		} else if stripped.starts_with('type ') {
			name := first_word(stripped[5..])
			if name != '' {
				symbols << make_symbol(name, sym_kind_class, i, raw_line)
			}
		}
	}

	return symbols
}

// make_symbol builds a DocumentSymbol covering the single line `line_idx`.
fn make_symbol(name string, kind int, line_idx int, raw_line string) DocumentSymbol {
	col_start := raw_line.index(name) or { 0 }
	col_end := col_start + name.len
	line_range := LSPRange{
		start: Position{
			line: line_idx
			char: 0
		}
		end:   Position{
			line: line_idx
			char: raw_line.len
		}
	}
	sel_range := LSPRange{
		start: Position{
			line: line_idx
			char: col_start
		}
		end:   Position{
			line: line_idx
			char: col_end
		}
	}
	return DocumentSymbol{
		name:            name
		kind:            kind
		range:           line_range
		selection_range: sel_range
		children:        []DocumentSymbol{}
	}
}

// extract_fn_name returns the function/method name including a receiver if
// present, e.g. "(mut App) foo" → "(mut App) foo", "main" → "main".
// The input is everything after the leading `fn ` (and optional `pub `).
fn extract_fn_name(after_fn string) string {
	t := after_fn.trim_space()
	if t == '' {
		return ''
	}
	if t.starts_with('(') {
		// method: (recv) name(params...
		close := t.index(')') or { return '' }
		rest := t[close + 1..].trim_space()
		name := first_word_paren(rest)
		if name == '' {
			return ''
		}
		receiver := t[1..close]
		return '(${receiver}) ${name}'
	}
	return first_word_paren(t)
}

// first_word returns the first space/tab-delimited token (stops at whitespace).
fn first_word(s string) string {
	mut end := 0
	for end < s.len && s[end] != ` ` && s[end] != `\t` && s[end] != `{` {
		end++
	}
	return s[..end].trim_space()
}

// first_word_paren returns the identifier before the first `(`, e.g.
// "foo(a int) string" → "foo".
fn first_word_paren(s string) string {
	mut end := 0
	for end < s.len && s[end] != `(` && s[end] != ` ` && s[end] != `\t` {
		end++
	}
	return s[..end].trim_space()
}

// extract_const_name handles both `const name = ...` and `const (` blocks
// by returning the identifier on the same line if available.
fn extract_const_name(after_const string) string {
	t := after_const.trim_space()
	if t == '' || t == '(' {
		return ''
	}
	return first_word(t)
}

fn (app &App) workspace_search_dirs(primary_dir string) []string {
	mut dirs := []string{}
	if primary_dir != '' && primary_dir != '/' {
		dirs << primary_dir
	}
	for root in app.workspace_roots {
		if root == '' || root == '/' {
			continue
		}
		if root !in dirs {
			dirs << root
		}
	}
	return dirs
}

fn (mut app App) search_symbol_in_project(working_dir string, symbol string, request_id int) []Location {
	return app.search_symbol_in_dirs([working_dir], symbol, request_id)
}

fn (mut app App) search_symbol_in_dirs(search_dirs []string, symbol string, request_id int) []Location {
	mut locations := []Location{}
	mut seen_files := map[string]bool{}
	for dir in search_dirs {
		if dir == '' || dir == '/' || !os.is_dir(dir) {
			continue
		}
		v_files := os.walk_ext(dir, '.v')

		for v_file in v_files {
			if request_id in app.cancelled_requests {
				return locations
			}
			if seen_files[v_file] {
				continue
			}
			seen_files[v_file] = true
			content := app.open_files[path_to_uri(v_file)] or {
				os.read_file(v_file) or { continue }
			}
			lines := content.split_into_lines()

			for line_idx, line_text in lines {
				n := line_text.len
				mut col := 0
				for col < n {
					c := line_text[col]
					// Skip line comments.
					if col + 1 < n && c == `/` && line_text[col + 1] == `/` {
						break
					}
					// Skip string literals.
					if c == `"` || c == `'` {
						quote := c
						col++
						for col < n {
							if line_text[col] == `\\` {
								col += 2
								continue
							}
							if line_text[col] == quote {
								col++
								break
							}
							col++
						}
						continue
					}
					// Extract full identifier token at this position.
					if is_ident_char(c) {
						start := col
						col++
						for col < n && is_ident_char(line_text[col]) {
							col++
						}
						if line_text[start..col] == symbol {
							start_char := utf8_byte_to_char_index(line_text, start)
							end_char := utf8_byte_to_char_index(line_text, col)
							locations << Location{
								uri:   path_to_uri(v_file)
								range: LSPRange{
									start: Position{
										line: line_idx
										char: start_char
									}
									end:   Position{
										line: line_idx
										char: end_char
									}
								}
							}
						}
						continue
					}
					col++
				}
			}
		}
	}
	return locations
}

// resolve_symbol_anchor resolves the canonical definition location for a symbol
// usage via compiler gd^ lookup. Returns none when the definition cannot be
// resolved, allowing callers to fall back to lexical matching.
fn (mut app App) resolve_symbol_anchor(uri string, line int, ch int) ?Location {
	line_info := '${line + 1}:gd^${ch}'
	result := app.run_v_line_info(.definition, uri, line_info)
	if result is Location {
		loc := result as Location
		if loc.uri != '' {
			return loc
		}
	}
	return none
}

fn anchor_cache_key(uri string, line int, ch int) string {
	return '${uri}:${line}:${ch}'
}

fn (mut app App) resolve_symbol_anchor_cached(uri string, line int, ch int, mut cache map[string]?Location) ?Location {
	key := anchor_cache_key(uri, line, ch)
	if key in cache {
		if cached := cache[key] {
			return cached
		}
		return none
	}
	resolved := app.resolve_symbol_anchor(uri, line, ch)
	cache[key] = resolved
	if loc := resolved {
		return loc
	}
	return none
}

fn same_anchor_location(a Location, b Location) bool {
	if a.uri != b.uri {
		return false
	}
	if a.range.start.line != b.range.start.line {
		return false
	}
	// Some compiler outputs differ by one code unit depending on context.
	delta := a.range.start.char - b.range.start.char
	return delta == 0 || delta == 1 || delta == -1
}

// search_symbol_in_dirs_semantic performs a lexical candidate scan and validates
// each candidate with a compiler definition lookup, keeping only occurrences that
// resolve to the same declaration anchor. Polls for cancellation after each file
// so that expensive compiler lookups are skipped when the request is cancelled.
fn (mut app App) search_symbol_in_dirs_semantic(search_dirs []string, symbol string, anchor Location, request_id int) []Location {
	started_ms := time.now().unix_milli()
	mut locations := []Location{}
	mut seen_files := map[string]bool{}
	mut anchor_cache := map[string]?Location{}
	mut files_scanned := 0
	mut anchor_lookups := 0
	mut candidate_tokens := 0
	for dir in search_dirs {
		if dir == '' || dir == '/' || !os.is_dir(dir) {
			continue
		}
		v_files := os.walk_ext(dir, '.v')
		for v_file in v_files {
			if request_id in app.cancelled_requests {
				return locations
			}
			if seen_files[v_file] {
				continue
			}
			seen_files[v_file] = true
			uri := path_to_uri(v_file)
			content := app.open_files[uri] or { os.read_file(v_file) or { continue } }
			if !content.contains(symbol) {
				continue
			}
			files_scanned++
			lines := content.split_into_lines()
			for line_idx, line_text in lines {
				if !line_text.contains(symbol) {
					continue
				}
				n := line_text.len
				mut col := 0
				for col < n {
					c := line_text[col]
					if col + 1 < n && c == `/` && line_text[col + 1] == `/` {
						break
					}
					if c == `"` || c == `'` {
						quote := c
						col++
						for col < n {
							if line_text[col] == `\\` {
								col += 2
								continue
							}
							if line_text[col] == quote {
								col++
								break
							}
							col++
						}
						continue
					}
					if is_ident_char(c) {
						start := col
						col++
						for col < n && is_ident_char(line_text[col]) {
							col++
						}
						if line_text[start..col] != symbol {
							continue
						}
						candidate_tokens++
						start_char := utf8_byte_to_char_index(line_text, start)
						anchor_lookups++
						if resolved := app.resolve_symbol_anchor_cached(uri, line_idx, start_char, mut
							anchor_cache)
						{
							if !same_anchor_location(resolved, anchor) {
								continue
							}
							end_char := utf8_byte_to_char_index(line_text, col)
							locations << Location{
								uri:   uri
								range: LSPRange{
									start: Position{
										line: line_idx
										char: start_char
									}
									end:   Position{
										line: line_idx
										char: end_char
									}
								}
							}
						}
						continue
					}
					col++
				}
			}
		}
	}
	elapsed_ms := time.now().unix_milli() - started_ms
	app.send_log_message('semantic-scan symbol=${symbol} files=${files_scanned} candidates=${candidate_tokens} lookups=${anchor_lookups} matches=${locations.len} elapsed_ms=${elapsed_ms}',
		4)
	return locations
}

// handle_code_action handles the LSP codeAction request, returning quick fixes and organize imports.
fn (mut app App) handle_code_action(request Request) Response {
	params := json.decode(CodeActionParams, request.params) or {
		$if debug { log('Failed to decode CodeActionParams: ${err}') }
		return Response{
			id:     request.id
			result: []CodeAction{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { '' }
	lines := content.split_into_lines()
	diagnostics := params.context.diagnostics

	$if debug {
		log('handle_code_action called for uri: ${uri}')
		log('diagnostics count: ${diagnostics.len}')
		for i, diag in diagnostics {
			log('diagnostics[${i}]: message=${diag.message}, range=${diag.range}')
		}
	}

	mut actions := []CodeAction{}

	$if debug { log('Top-level types in handlers.v: App, ...') }
	// 1. Quick fixes for diagnostics
	for diag in diagnostics {
		$if debug {
			log('Checking diagnostic: message=' + diag.message + ', range.start.line=' +
				diag.range.start.line.str())
		}
		if diag.message.contains('unknown module') {
			line_nr := diag.range.start.line
			$if debug {
				log('unknown module diagnostic at line_nr=' + line_nr.str())
				if line_nr < lines.len {
					log('line content: ' + lines[line_nr])
				}
			}
			if line_nr < lines.len && lines[line_nr].trim_space().starts_with('import ') {
				$if debug { log('Matched import line for quickfix') }
				edit := WorkspaceEdit{
					changes: {
						uri: [
							TextEdit{
								range:    LSPRange{
									start: Position{
										line: line_nr
										char: 0
									}
									end:   Position{
										line: line_nr
										char: lines[line_nr].len
									}
								}
								new_text: ''
							},
						]
					}
				}
				actions << CodeAction{
					title:        'Remove unknown import'
					kind:         code_action_kind_quickfix
					is_preferred: true
					edit:         edit
					diagnostics:  [diag]
				}
				$if debug { log('Added quickfix action for line_nr=' + line_nr.str()) }
			}
		}
	}

	// 2. Organize Imports (sort and deduplicate)
	mut import_lines := []int{}
	for i, line in lines {
		if line.trim_space().starts_with('import ') {
			import_lines << i
		}
	}
	if import_lines.len > 0 {
		mut imports := []string{}
		for i in import_lines {
			imports << lines[i].trim_space()
		}
		// Deduplicate and sort
		mut seen := map[string]bool{}
		mut unique_imports := []string{}
		for imp in imports {
			if !seen[imp] {
				unique_imports << imp
				seen[imp] = true
			}
		}
		unique_imports.sort()
		if unique_imports.len > 0 {
			edit := WorkspaceEdit{
				changes: {
					uri: [
						TextEdit{
							range:    LSPRange{
								start: Position{
									line: import_lines.first()
									char: 0
								}
								end:   Position{
									line: import_lines.last()
									char: lines[import_lines.last()].len
								}
							}
							new_text: unique_imports.join('\n')
						},
					]
				}
			}
			actions << CodeAction{
				title: 'Organize Imports'
				kind:  code_action_kind_source_organize_imports
				edit:  edit
			}
		}
	}

	$if debug {
		log('actions count before return: ' + actions.len.str())
		for i, act in actions {
			log('actions[' + i.str() + ']: title=' + act.title + ', kind=' + act.kind)
		}
	}

	return Response{
		id:     request.id
		result: actions
	}
}

// collect_module_fn_completions collects free function completions from sibling files in the module.
fn (app &App) collect_module_fn_completions(current_file_uri string, working_dir string) []Detail {
	mut items := []Detail{}
	mut searched_uris := map[string]bool{}
	searched_uris[current_file_uri] = true

	// Determine the current file's module so we only include same-module siblings.
	current_content := app.open_files[current_file_uri] or {
		content := os.read_file(uri_to_path(current_file_uri)) or { '' }
		content
	}
	current_module := get_module_name(current_content)

	// 1. Scan in-memory open files
	for uri, content in app.open_files {
		if uri in searched_uris {
			continue
		}
		if uri.ends_with('_test.v') {
			continue
		}
		searched_uris[uri] = true
		if current_module != '' && get_module_name(content) != current_module {
			continue
		}
		items << parse_module_fn_completions(content)
	}

	// 2. Scan on-disk .v files in the working directory not yet processed
	for v_file in os.walk_ext(working_dir, '.v') {
		if v_file.ends_with('_test.v') {
			continue
		}
		uri := path_to_uri(v_file)
		if uri in searched_uris {
			continue
		}
		searched_uris[uri] = true
		content := os.read_file(v_file) or { continue }
		if current_module != '' && get_module_name(content) != current_module {
			continue
		}
		items << parse_module_fn_completions(content)
	}

	return items
}

// parse_module_fn_completions extracts free-function declarations (`pub fn` and `fn`)
// from V source content and returns them as completion Detail items.
// Method receivers (e.g. `fn (r Recv) method()`) are skipped.
// When a function has parameters a snippet insertText with tab-stops is produced.
fn parse_module_fn_completions(content string) []Detail {
	mut items := []Detail{}
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		mut after_fn := ''
		if trimmed.starts_with('pub fn ') {
			after_fn = trimmed[7..]
		} else if trimmed.starts_with('fn ') {
			after_fn = trimmed[3..]
		} else {
			continue
		}
		// Skip method receivers: `fn (recv Recv) method_name(`
		if after_fn.starts_with('(') {
			continue
		}
		paren_idx := after_fn.index('(') or { continue }
		fn_name := after_fn[..paren_idx].trim_space()
		if fn_name == '' || fn_name.contains(' ') || fn_name.contains('[') {
			continue
		}
		// Build the detail string: full signature up to (but not including) ` {`
		detail_str := trimmed.all_before('{').trim_space()
		// Build snippet insertText: fn_name($1, $2, ...) or fn_name($1)$0
		insert := build_fn_snippet(fn_name, after_fn[paren_idx..])
		items << Detail{
			kind:               3 // CompletionItemKind.Function
			label:              fn_name
			detail:             detail_str
			insert_text:        insert
			insert_text_format: if insert.contains('$') { 2 } else { 1 }
		}
	}
	return items
}

// build_fn_snippet builds a VSCode-style snippet string for a function call.
// `fn_name` is the bare function name; `params_str` is the portion of the
// signature starting from `(`, e.g. `(name string, age int) string`.
// Returns a snippet like `fn_name(${1:name}, ${2:age})$0`, or `fn_name()` when
// the parameter list is empty.
fn build_fn_snippet(fn_name string, params_str string) string {
	if !params_str.starts_with('(') {
		return fn_name + '()'
	}
	// Find closing paren of parameter list.
	close := params_str.index(')') or { return fn_name + '()' }
	inner := params_str[1..close].trim_space()
	if inner == '' {
		return fn_name + '()'
	}
	// Split parameters by comma and extract their names.
	raw_params := inner.split(',')
	mut placeholders := []string{}
	for idx, raw_param in raw_params {
		// Each token looks like `name Type` or `mut name Type` or `_ Type`.
		trimmed := raw_param.trim_space()
		parts := trimmed.split(' ')
		// Skip parameters without a name (e.g. `_ string`).
		mut param_name := ''
		for part in parts {
			p := part.trim_space()
			if p == '' || p == 'mut' || p == '_' {
				continue
			}
			param_name = p
			break
		}
		if param_name == '' {
			param_name = 'arg${idx + 1}'
		}
		placeholders << '\${${idx + 1}:${param_name}}'
	}
	return '${fn_name}(${placeholders.join(', ')})$0'
}

fn make_keyword_completions() []Detail {
	mut items := []Detail{}
	for kw in v_keywords {
		items << Detail{
			kind:   14 // Keyword
			label:  kw
			detail: kw
		}
	}
	for b in v_builtins {
		items << Detail{
			kind:   3 // Function
			label:  b
			detail: b
		}
	}
	return items
}

// handle_range_formatting handles textDocument/rangeFormatting.
// It formats the whole file via `v fmt` and returns edits only for the requested range.
fn (mut app App) handle_range_formatting(request Request) Response {
	params := json.decode(DocumentRangeFormattingParams, request.params) or {
		log('Failed to decode DocumentRangeFormattingParams: ${err}')
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	path := params.text_document.uri
	real_path := uri_to_path(path)
	content := app.open_files[path] or {
		os.read_file(real_path) or {
			log('Failed to read file for range formatting: ${err}')
			return Response{
				id:     request.id
				result: []TextEdit{}
			}
		}
	}
	temp_file := os.join_path(os.temp_dir(), 'vls_rfmt_${os.getpid()}_${os.file_name(real_path)}')
	os.write_file(temp_file, content) or {
		log('Failed to write temp file for range formatting: ${err}')
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	result := os.execute(ensure_stderr_captured(build_v_fmt_cmd(temp_file)))
	os.rm(temp_file) or {
		$if debug { log('Failed to remove temp file for range formatting: ${err}') }
	}
	if result.exit_code != 0 || result.output == content {
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	original_lines := content.split_into_lines()
	formatted_lines := result.output.split_into_lines()
	start_line := params.range.start.line
	mut end_line := params.range.end.line
	if end_line >= original_lines.len {
		end_line = original_lines.len - 1
	}
	if start_line >= original_lines.len || start_line >= formatted_lines.len {
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	safe_end := if end_line < formatted_lines.len { end_line } else { formatted_lines.len - 1 }
	formatted_slice := formatted_lines[start_line..safe_end + 1].join('\n')
	original_slice := original_lines[start_line..end_line + 1].join('\n')
	if formatted_slice == original_slice {
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	last_char := original_lines[end_line].len
	edit := TextEdit{
		range:    LSPRange{
			start: Position{
				line: start_line
				char: 0
			}
			end:   Position{
				line: end_line
				char: last_char
			}
		}
		new_text: formatted_slice
	}
	return Response{
		id:     request.id
		result: [edit]
	}
}

// handle_selection_range handles textDocument/selectionRange.
// For each requested cursor position it returns a two-level SelectionRange:
// the identifier under the cursor as the inner range, and the enclosing line
// as the outer (parent) range.  Clients expand the selection incrementally.
fn (mut app App) handle_selection_range(request Request) Response {
	params := json.decode(SelectionRangeParams, request.params) or {
		$if debug { log('Failed to decode SelectionRangeParams: ${err}') }
		return Response{
			id:     request.id
			result: []SelectionRange{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	lines := content.split_into_lines()
	mut results := []SelectionRange{}
	for pos in params.positions {
		if pos.line >= lines.len {
			results << SelectionRange{
				range: LSPRange{
					start: pos
					end:   pos
				}
			}
			continue
		}
		line_text := lines[pos.line]
		// Outermost: full line range.
		line_range := LSPRange{
			start: Position{
				line: pos.line
				char: 0
			}
			end:   Position{
				line: pos.line
				char: line_text.len
			}
		}
		start, end := find_word_bounds_at_col(line_text, pos.char)
		if start < 0 || end <= start {
			results << SelectionRange{
				range: line_range
			}
			continue
		}
		// Inner: identifier range; parent points to the line range.
		word_range := LSPRange{
			start: Position{
				line: pos.line
				char: start
			}
			end:   Position{
				line: pos.line
				char: end
			}
		}
		line_parent := &SelectionRange{
			range: line_range
		}
		results << SelectionRange{
			range:  word_range
			parent: line_parent
		}
	}
	return Response{
		id:     request.id
		result: results
	}
}

// on_did_change_configuration handles the workspace/didChangeConfiguration notification.
// It applies settings that affect server behaviour:
//   vls.inlayHints  – enable or disable inlay type hints
//   vls.diagnostics – enable or disable live compile-time diagnostics
fn (mut app App) on_did_change_configuration(request Request) {
	resolved := resolve_workspace_settings(request.params)
	if resolved.has_inlay_hints {
		if enabled := resolved.inlay_hints {
			app.inlay_hints_enabled = enabled
			log('VLS: inlay_hints_enabled=${enabled}')
		}
	}
	if resolved.has_diagnostics {
		if enabled := resolved.diagnostics {
			app.diagnostics_enabled = enabled
			log('VLS: diagnostics_enabled=${enabled}')
		}
	}
}

struct ResolvedWorkspaceSettings {
mut:
	inlay_hints     ?bool
	diagnostics     ?bool
	has_inlay_hints bool
	has_diagnostics bool
}

fn resolve_workspace_settings(params_json string) ResolvedWorkspaceSettings {
	mut resolved := ResolvedWorkspaceSettings{}

	// 1) Preferred shape: settings.vls.{inlayHints, diagnostics}
	sectioned := json.decode(DidChangeConfigurationParams, params_json) or {
		DidChangeConfigurationParams{}
	}
	if enabled := sectioned.settings.vls.inlay_hints {
		resolved.inlay_hints = enabled
		resolved.has_inlay_hints = true
	}
	if enabled := sectioned.settings.vls.diagnostics {
		resolved.diagnostics = enabled
		resolved.has_diagnostics = true
	}

	// 2) Direct shape: settings.{inlayHints, diagnostics}
	direct := json.decode(DidChangeConfigurationDirectParams, params_json) or {
		DidChangeConfigurationDirectParams{}
	}
	if !resolved.has_inlay_hints {
		if enabled := direct.settings.inlay_hints {
			resolved.inlay_hints = enabled
			resolved.has_inlay_hints = true
		}
	}
	if !resolved.has_diagnostics {
		if enabled := direct.settings.diagnostics {
			resolved.diagnostics = enabled
			resolved.has_diagnostics = true
		}
	}

	// 3) Nested compatibility shapes, used only when flat values are absent.
	sectioned_nested := json.decode(DidChangeConfigurationParamsCompat, params_json) or {
		DidChangeConfigurationParamsCompat{}
	}
	if !resolved.has_inlay_hints {
		if enabled := sectioned_nested.settings.vls.inlay_hints.enabled {
			resolved.inlay_hints = enabled
			resolved.has_inlay_hints = true
		}
	}

	direct_nested := json.decode(DidChangeConfigurationDirectParamsCompat, params_json) or {
		DidChangeConfigurationDirectParamsCompat{}
	}
	if !resolved.has_inlay_hints {
		if enabled := direct_nested.settings.inlay_hints.enabled {
			resolved.inlay_hints = enabled
			resolved.has_inlay_hints = true
		}
	}

	return resolved
}

fn (mut app App) on_initialize(request Request) ?string {
	params := json.decode(InitializeParams, request.params) or {
		msg := 'Invalid initialize params: ${err.msg()}'
		$if debug { log(msg) }
		return msg
	}
	roots := resolve_initialize_workspace_roots(params)
	if roots.len > 0 {
		app.workspace_roots = roots
		log('VLS: workspace roots set to ${roots}')
	}
	app.supports_dynamic_watched_files_registration =
		client_supports_dynamic_watched_files_registration(params)
	if app.supports_dynamic_watched_files_registration {
		log('VLS: client supports dynamic watched-files registration')
	}
	app.supports_work_done_progress = client_supports_work_done_progress(params)
	if app.supports_work_done_progress {
		log('VLS: client supports workDoneProgress')
	}
	// Log client-advertised position encodings for diagnostics.
	if caps := params.capabilities {
		if general := caps.general {
			if encodings := general.position_encodings {
				log('VLS: client positionEncodings=${encodings}')
			}
		}
	}
	return none
}

fn client_supports_dynamic_watched_files_registration(params InitializeParams) bool {
	if caps := params.capabilities {
		if workspace := caps.workspace {
			if watched := workspace.did_change_watched_files {
				return watched.dynamic_registration
			}
		}
	}
	return false
}

fn client_supports_work_done_progress(params InitializeParams) bool {
	if caps := params.capabilities {
		if window := caps.window {
			return window.work_done_progress
		}
	}
	return false
}

fn resolve_initialize_workspace_roots(params InitializeParams) []string {
	mut roots := []string{}
	if folders := params.workspace_folders {
		for folder in folders {
			if path := normalize_workspace_root(uri_to_path(folder.uri)) {
				if path !in roots {
					roots << path
				}
			}
		}
	}
	if roots.len > 0 {
		return roots
	}
	if root_uri := params.root_uri {
		if path := normalize_workspace_root(uri_to_path(root_uri)) {
			return [path]
		}
	}
	if root_path := params.root_path {
		if path := normalize_workspace_root(root_path) {
			return [path]
		}
	}
	return []
}

fn normalize_workspace_root(path string) ?string {
	normalized := path.trim_space()
	if normalized == '' || normalized == '/' {
		return none
	}
	return normalized
}

fn (mut app App) on_cancel_request(request Request) {
	params := json.decode(CancelRequestParams, request.params) or {
		$if debug { log('Failed to decode CancelRequestParams: ${err}') }
		return
	}
	app.cancelled_requests[params.id] = true
	log('VLS: request ${params.id} marked as cancelled')
}

// on_did_change_workspace_folders handles workspace/didChangeWorkspaceFolders by
// updating the server's list of workspace roots when the client adds or removes folders.
fn (mut app App) on_did_change_workspace_folders(request Request) {
	params := json.decode(DidChangeWorkspaceFoldersParams, request.params) or {
		$if debug { log('Failed to decode DidChangeWorkspaceFoldersParams: ${err}') }
		return
	}
	// Remove folders that were closed.
	for folder in params.event.removed {
		path := uri_to_path(folder.uri).trim_space()
		if path == '' || path == '/' {
			continue
		}
		mut new_roots := []string{}
		for r in app.workspace_roots {
			if r != path {
				new_roots << r
			}
		}
		app.workspace_roots = new_roots
	}
	// Add newly opened folders.
	for folder in params.event.added {
		path := uri_to_path(folder.uri).trim_space()
		if path == '' || path == '/' {
			continue
		}
		if path !in app.workspace_roots {
			app.workspace_roots << path
		}
	}
	log('VLS: workspace roots updated to ${app.workspace_roots}')
}

// handle_code_lens handles textDocument/codeLens requests.
// Returns run/test lens items for fn main() and fn test_* declarations.
fn (mut app App) handle_code_lens(request Request) Response {
	params := json.decode(CodeLensParams, request.params) or {
		$if debug { log('Failed to decode CodeLensParams: ${err}') }
		return Response{
			id:     request.id
			result: []CodeLens{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	lines := content.split_into_lines()
	mut lenses := []CodeLens{}
	for i, raw_line in lines {
		trimmed := raw_line.trim_space()
		// fn main() → offer a "Run" lens.
		if trimmed == 'fn main() {' || trimmed.starts_with('fn main()') {
			lenses << CodeLens{
				range:   LSPRange{
					start: Position{
						line: i
						char: 0
					}
					end:   Position{
						line: i
						char: raw_line.len
					}
				}
				command: Command{
					title:     '▶ Run'
					command:   'vls.runFile'
					arguments: [uri]
				}
			}
		}
		// fn test_* → offer a "Run Test" lens.
		if (trimmed.starts_with('fn test_') || trimmed.starts_with('pub fn test_'))
			&& trimmed.contains('(') {
			fn_name := if trimmed.starts_with('pub ') {
				first_word_paren(trimmed[7..])
			} else {
				first_word_paren(trimmed[3..])
			}
			if fn_name != '' {
				lenses << CodeLens{
					range:   LSPRange{
						start: Position{
							line: i
							char: 0
						}
						end:   Position{
							line: i
							char: raw_line.len
						}
					}
					command: Command{
						title:     '▶ Run Test'
						command:   'vls.runTests'
						arguments: [uri, fn_name]
					}
				}
			}
		}
	}
	return Response{
		id:     request.id
		result: lenses
	}
}

// handle_code_lens_resolve handles codeLens/resolve.
// The lens is already fully resolved at creation time so this is a pass-through.
fn (mut app App) handle_code_lens_resolve(request Request) Response {
	lens := json.decode(CodeLens, request.params) or {
		$if debug { log('Failed to decode CodeLens for resolve: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	return Response{
		id:     request.id
		result: lens
	}
}

// handle_execute_command handles workspace/executeCommand.
// Currently supports vls.runFile and vls.runTests by echoing a log message.
fn (mut app App) handle_execute_command(request Request) Response {
	params := json.decode(ExecuteCommandParams, request.params) or {
		$if debug { log('Failed to decode ExecuteCommandParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	match params.command {
		'vls.runFile' {
			args := params.arguments or { [] }
			uri := if args.len > 0 { args[0] } else { '' }
			app.send_show_message('vls: run file not yet implemented (${uri})', 3)
		}
		'vls.runTests' {
			args := params.arguments or { [] }
			uri := if args.len > 0 { args[0] } else { '' }
			app.send_show_message('vls: run tests not yet implemented (${uri})', 3)
		}
		else {
			app.send_show_message('vls: unknown command ${params.command}', 2)
		}
	}

	return Response{
		id:     request.id
		result: 'null'
	}
}

// handle_inline_value handles textDocument/inlineValue.
// Returns inline text values for simple variable := literal assignments in the range.
fn (mut app App) handle_inline_value(request Request) Response {
	params := json.decode(InlineValueParams, request.params) or {
		$if debug { log('Failed to decode InlineValueParams: ${err}') }
		return Response{
			id:     request.id
			result: []InlineValueText{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { '' }
	lines := content.split_into_lines()
	mut values := []InlineValueText{}
	start_line := params.range.start.line
	end_line := params.range.end.line
	for i in start_line .. (end_line + 1) {
		if i >= lines.len {
			break
		}
		raw := lines[i]
		trimmed := raw.trim_space()
		assign_idx := trimmed.index(' := ') or { continue }
		lhs := trimmed[..assign_idx].trim_space()
		rhs := trimmed[assign_idx + 4..].trim_space()
		var_name := if lhs.starts_with('mut ') { lhs[4..].trim_space() } else { lhs }
		if var_name == '' || var_name.contains(' ') || var_name.contains(',') {
			continue
		}
		inferred := infer_type_from_literal(rhs)
		if inferred == '' {
			continue
		}
		col_start := raw.index(var_name) or { 0 }
		values << InlineValueText{
			range: LSPRange{
				start: Position{
					line: i
					char: col_start
				}
				end:   Position{
					line: i
					char: col_start + var_name.len
				}
			}
			text:  ': ${inferred}'
		}
	}
	return Response{
		id:     request.id
		result: values
	}
}

// handle_linked_editing_range handles textDocument/linkedEditingRange.
// Returns ranges for all occurrences of the identifier under the cursor in the
// same line (identifier and its declaration) for linked editing.
fn (mut app App) handle_linked_editing_range(request Request) Response {
	params := json.decode(TextDocumentPositionParams, request.params) or {
		$if debug {
			log('Failed to decode TextDocumentPositionParams for linkedEditingRange: ${err}')
		}
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	lines := content.split_into_lines()
	if params.position.line >= lines.len {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	line_text := lines[params.position.line]
	start, end := find_word_bounds_at_col(line_text, params.position.char)
	if start < 0 || end <= start {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	symbol := line_text[start..end]
	// Collect all occurrences of the symbol on this line.
	mut ranges := []LSPRange{}
	mut col := 0
	for col < line_text.len {
		idx := line_text[col..].index(symbol) or { break }
		abs := col + idx
		before_ok := abs == 0 || !is_ident_char(line_text[abs - 1])
		after_ok := abs + symbol.len >= line_text.len || !is_ident_char(line_text[abs + symbol.len])
		if before_ok && after_ok {
			sc := utf8_byte_to_char_index(line_text, abs)
			ec := utf8_byte_to_char_index(line_text, abs + symbol.len)
			ranges << LSPRange{
				start: Position{
					line: params.position.line
					char: sc
				}
				end:   Position{
					line: params.position.line
					char: ec
				}
			}
		}
		col = abs + 1
	}
	if ranges.len == 0 {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	return Response{
		id:     request.id
		result: LinkedEditingRanges{
			ranges: ranges
		}
	}
}

// handle_on_type_formatting handles textDocument/onTypeFormatting.
// For now it returns empty edits — triggering v fmt on every keystroke would be too expensive.
fn (mut app App) handle_on_type_formatting(request Request) Response {
	return Response{
		id:     request.id
		result: []TextEdit{}
	}
}
