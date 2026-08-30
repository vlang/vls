// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json2
import time
import v.pref

const v_keywords = ['asm', 'as', 'assert', 'atomic', 'break', 'const', 'continue', 'defer', 'dump',
	'else', 'enum', 'false', 'fn', 'for', 'go', 'goto', 'if', 'ilike', 'implements', 'import',
	'in', 'interface', 'is', 'isreftype', 'like', 'lock', 'match', 'module', 'mut', 'nil', 'none',
	'or', 'pub', 'return', 'rlock', 'select', 'shared', 'sizeof', 'spawn', 'static', 'struct',
	'true', 'type', 'typeof', 'union', 'unsafe', 'volatile']!

const v_builtins = ['close', 'copy', 'eprintln', 'eprint', 'error', 'error_with_code', 'exit',
	'flush_stderr', 'flush_stdout', 'free', 'isnil', 'panic', 'print', 'println']!

// operation_at_pos handles LSP requests at a given position (completion, hover, signature, definition).
fn (mut app App) operation_at_pos(method Method, request Request) Response {
	params := json2.decode[TextDocumentPositionParams](request.params) or {
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
	// LSP positions are non-negative; reject malformed negative positions rather
	// than indexing arrays with negative values (P1-09).
	if params.position.line < 0 || params.position.char < 0 {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	line_nr := params.position.line + 1
	col := params.position.char
	path := params.text_document.uri
	// The V compiler consumes byte columns, so convert the client's character
	// offset (in the negotiated encoding) to a byte offset within the cursor line
	// before building the -line-info string (P0-01).
	byte_col := app.client_col_to_byte_col(path, params.position.line, col)

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

	// Resolve declarations from VLS's authoritative source index before using
	// the established compiler's V1-only `-line-info` compatibility mode. Free
	// functions and top-level declarations do not require receiver type
	// inference, so this path is both deterministic and aware of unsaved files.
	if method in [.definition, .declaration, .type_definition, .implementation] {
		if location := app.resolve_indexed_definition(path, params.position) {
			return Response{
				id:     request.id
				result: location
			}
		}
	}

	line_info := match method {
		.completion {
			'${line_nr}:${byte_col}'
		}
		.hover {
			'${line_nr}:hv^${byte_col}'
		}
		.signature_help {
			'${line_nr}:fn^${byte_col}'
		}
		.definition, .declaration, .type_definition, .implementation {
			'${line_nr}:gd^${byte_col}'
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
			trigger_byte_col := encoded_col_to_byte(line, col - 1, app.position_encoding)
			if trigger_byte_col < line.len {
				line[trigger_byte_col].ascii_str()
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
			module_alias := get_word_before_dot(line, col - 1, app.position_encoding)
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
// `dot_col` is the character index of the dot itself (in `enc` units).
fn get_word_before_dot(line string, dot_col int, enc PositionEncoding) string {
	if line == '' || dot_col < 0 {
		return ''
	}
	dot_byte := encoded_col_to_byte(line, dot_col, enc)
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

// parse_import_aliases returns alias -> module path for V import statements.
// Examples: `import os` => os -> os, `import net.http` => http -> net.http,
// `import net.http as nh` => nh -> net.http. Grouped imports are supported too.
fn parse_import_aliases(content string) map[string]string {
	mut aliases := map[string]string{}
	for binding in parse_import_bindings(content) {
		if binding.alias != '' && binding.module_path != '' {
			aliases[binding.alias] = binding.module_path
		}
	}
	return aliases
}

struct ImportScanState {
mut:
	in_block_comment bool
	quote            u8
}

fn source_line_import_code(line string, mut state ImportScanState) string {
	mut code := []u8{cap: line.len}
	mut col := 0
	for col < line.len {
		if state.in_block_comment {
			if col + 1 < line.len && line[col] == `*` && line[col + 1] == `/` {
				state.in_block_comment = false
				code << ` `
				col += 2
				continue
			}
			col++
			continue
		}
		if state.quote != 0 {
			if line[col] == `\\` && col + 1 < line.len {
				col += 2
				continue
			}
			if line[col] == state.quote {
				state.quote = 0
				code << ` `
			}
			col++
			continue
		}
		if col + 1 < line.len && line[col] == `/` && line[col + 1] == `/` {
			break
		}
		if col + 1 < line.len && line[col] == `/` && line[col + 1] == `*` {
			state.in_block_comment = true
			code << ` `
			col += 2
			continue
		}
		if line[col] == `"` || line[col] == `'` || line[col] == 96 {
			state.quote = line[col]
			code << ` `
			col++
			continue
		}
		code << line[col]
		col++
	}
	return code.bytestr()
}

fn parse_import_binding(text string) ?ImportedModuleBinding {
	parts := text.fields()
	if parts.len == 0 {
		return none
	}
	module_path := parts[0]
	if module_path == '' {
		return none
	}
	mut alias := ''
	if parts.len >= 3 && parts[1] == 'as' {
		alias = parts[2]
	} else {
		module_parts := module_path.split('.')
		if module_parts.len > 0 {
			alias = module_parts.last()
		}
	}
	if alias == '' {
		return none
	}
	return ImportedModuleBinding{
		alias:       alias
		module_path: module_path
	}
}

fn parse_import_bindings(content string) []ImportedModuleBinding {
	mut bindings := []ImportedModuleBinding{}
	mut scan_state := ImportScanState{}
	mut in_import_block := false
	for raw_line in content.split_into_lines() {
		line := source_line_import_code(raw_line, mut scan_state)
		trimmed := line.trim_space()
		if in_import_block {
			if trimmed.starts_with(')') {
				in_import_block = false
				continue
			}
			if binding := parse_import_binding(trimmed) {
				bindings << binding
			}
			continue
		}
		if !trimmed.starts_with('import ') {
			continue
		}
		rest := trimmed[7..].trim_space()
		if rest == '(' {
			in_import_block = true
			continue
		}
		if binding := parse_import_binding(rest) {
			bindings << binding
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

fn (app &App) workspace_root_containing(path string) string {
	normalized_path := path.replace('\\', '/')
	mut best_root := ''
	mut best_len := 0
	for root in app.workspace_roots {
		normalized_root := root.replace('\\', '/')
		if path_is_within(normalized_path, normalized_root) && normalized_root.len > best_len {
			best_root = root
			best_len = normalized_root.len
		}
	}
	return best_root
}

// resolve_indexed_import_module_dir prefers modules in the requesting file's
// active project or workspace root over the V installation used to launch VLS.
// Unrelated workspace folders are not compiler import roots and must not affect
// indexed resolution.
fn (app &App) resolve_indexed_import_module_dir(module_path string, work_dir string) string {
	rel := module_path.replace('.', os.path_separator)
	mut root := find_project_root(work_dir)
	if root == '' || root == '/' {
		root = app.workspace_root_containing(work_dir)
	}
	if root != '' && root != '/' {
		for candidate in [os.join_path(root, rel), os.join_path(root, 'vlib', rel)] {
			if os.is_dir(candidate) {
				return candidate
			}
		}
	}
	return resolve_import_module_dir(module_path, work_dir)
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
	params := json2.decode[DidOpenTextDocumentParams](request.params) or {
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
	app.bump_generation(uri)
	app.invalidate_index_uri(uri) // re-parse from the buffer on next query
	app.text = content
	$if debug { log('STORED CONTENT for uri=${uri}, FILE COUNT: ${app.open_files.len}') }
}

// on_did_close handles the LSP didClose notification by removing the file from
// tracked state. It also clears the diagnostic cache for the document so stale
// problems do not linger after close (P0-07). The dispatcher publishes an empty
// diagnostic set to clear editor markers.
fn (mut app App) on_did_close(request Request) {
	params := json2.decode[DidCloseTextDocumentParams](request.params) or {
		$if debug { log('Failed to decode DidCloseTextDocumentParams: ${err}') }
		return
	}
	uri := params.text_document.uri
	if uri in app.open_files {
		app.open_files.delete(uri)
		app.bump_generation(uri)
	}
	if uri in app.open_files_versions {
		app.open_files_versions.delete(uri)
	}
	if uri in app.diag_cache {
		app.diag_cache.delete(uri)
	}
	// The buffer is gone; re-index from disk so the file's symbols remain
	// discoverable with their on-disk content. Remove the client URI alias and
	// retain one stable key so a later canonical watcher event cannot create a
	// duplicate entry for the same physical file.
	disk_path := uri_to_path(uri)
	disk_uri := index_uri_for_path(disk_path, app.open_index_uris_by_path())
	app.drop_index_aliases_for_path(disk_path, disk_uri)
	app.reindex_uri(disk_uri)
}

fn (mut app App) build_diagnostics_notification(uri string, content string) Notification {
	if !app.diagnostics_enabled {
		return Notification{
			method: 'textDocument/publishDiagnostics'
			params: PublishDiagnosticsParams{
				uri:         uri
				version:     if uri in app.open_files_versions {
					?i64(app.open_files_versions[uri])
				} else {
					none
				}
				diagnostics: []
			}
		}
	}
	v_errors := app.run_v_check(uri, content)
	log('run_v_check errors:${v_errors}')
	lines := content.split_into_lines()
	mut diagnostics := []LSPDiagnostic{}
	mut seen_positions := map[string]bool{}
	for v_err in v_errors {
		// Include the message and length in the dedup key so two genuinely
		// different diagnostics at the same line/column are both retained
		// (P1-06). Only exact duplicates are dropped.
		pos_key := '${v_err.line_nr}:${v_err.col}:${v_err.len}:${v_err.level}:${v_err.message}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		// The compiler reports byte columns; re-encode the diagnostic range in
		// the client's negotiated encoding (P0-01).
		diagnostics << app.encode_diagnostic_range(v_error_to_lsp_diagnostic(v_err), lines)
	}
	pd_params := PublishDiagnosticsParams{
		uri:         uri
		version:     if uri in app.open_files_versions {
			?i64(app.open_files_versions[uri])
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
	params := json2.decode[DidChangeTextDocumentParams](request.params) or {
		$if debug { log('Failed to decode DidChangeTextDocumentParams: ${err}') }
		return none
	}
	log('on did change(len=${params.content_changes.len})')
	if params.content_changes.len == 0 {
		log('on_did_change() no params')
		return none
	}
	uri := params.text_document.uri
	// Enforce monotonic versions: reject stale or out-of-order changes so an
	// old buffer state can never overwrite newer text (P0-07).
	if new_version := params.text_document.version {
		if old_version := app.open_files_versions[uri] {
			if new_version <= old_version {
				log('on_did_change: ignoring stale version ${new_version} <= ${old_version} for ${uri}')
				return none
			}
		}
	}
	is_open := uri in app.open_files
	mut content := app.open_files[uri] or { '' }
	for change in params.content_changes {
		if change.range != none {
			// Incremental change. If the document was never opened we have no
			// base text to apply the edit against; applying it against '' would
			// silently corrupt state, so require a full-text sync instead.
			if !is_open {
				log('on_did_change: incremental change for unopened document ${uri}; ignoring (client should re-sync)')
				return none
			}
			rng := change.range or {
				$if debug { log('Skipping malformed incremental change with missing range') }
				continue
			}

			// An invalid range must not be silently dropped while the version is
			// advanced (that desynchronizes the buffer). Refuse the whole change
			// and keep the last-good content and version (P0-07).
			if !incremental_change_is_valid(content, rng, app.position_encoding) {
				log('on_did_change: invalid incremental range for ${uri}; refusing change without advancing version')
				return none
			}
			content = apply_incremental_change(content, rng, change.text, app.position_encoding)
		} else {
			// Full text replacement.
			content = change.text
		}
	}
	app.text = content
	app.open_files[uri] = content // Update tracked file
	if version := params.text_document.version {
		app.open_files_versions[uri] = version
	}
	app.bump_generation(uri)
	app.invalidate_index_uri(uri) // symbols re-parsed lazily on next query
	notification := app.build_diagnostics_notification(uri, content)
	$if debug { log('returning notification: ${notification}') }
	return notification
}

// encode_diagnostic_range re-encodes a diagnostic's byte-based character
// offsets (as produced from compiler output) into the client's negotiated
// position encoding, using the document `lines`.
fn (app &App) encode_diagnostic_range(diag LSPDiagnostic, lines []string) LSPDiagnostic {
	start_line := diag.range.start.line
	end_line := diag.range.end.line
	start_char := if start_line >= 0 && start_line < lines.len {
		byte_to_encoded_col(lines[start_line], diag.range.start.char, app.position_encoding)
	} else {
		diag.range.start.char
	}
	end_char := if end_line >= 0 && end_line < lines.len {
		byte_to_encoded_col(lines[end_line], diag.range.end.char, app.position_encoding)
	} else {
		diag.range.end.char
	}
	return LSPDiagnostic{
		...diag
		range: LSPRange{
			start: Position{
				line: start_line
				char: start_char
			}
			end:   Position{
				line: end_line
				char: end_char
			}
		}
	}
}

// on_did_save handles didSave by re-running diagnostics for the saved document.
fn (mut app App) on_did_save(request Request) ?Notification {
	params := json2.decode[DidSaveTextDocumentParams](request.params) or {
		$if debug { log('Failed to decode DidSaveTextDocumentParams: ${err}') }
		return none
	}
	uri := params.text_document.uri
	// A valid empty open buffer ('') must not be confused with an absent
	// document. Only fall back to didSave text / disk when the document is not
	// tracked as open (P0-07 item 6). When the client includes save text and
	// the document is open, prefer the client's text as the new source of truth.
	mut content := ''
	if existing := app.open_files[uri] {
		content = existing
		if text := params.text {
			content = text
			app.open_files[uri] = text
			app.text = text
			app.bump_generation(uri)
			app.invalidate_index_uri(uri)
		}
	} else {
		// didSave for a document that is NOT open. Do not insert it into
		// open_files — that would leave it logically open (and editor-owned)
		// forever. Just compute diagnostics from the saved text or, failing that,
		// the on-disk content.
		if text := params.text {
			content = text
		} else {
			real_path := uri_to_path(uri)
			content = os.read_file(real_path) or {
				$if debug { log('on_did_save: failed to read file ${real_path}: ${err}') }
				return none
			}
		}
	}
	notification := app.build_diagnostics_notification(uri, content)
	return notification
}

// on_will_save_wait_until handles willSaveWaitUntil by formatting the document
// before it is saved, returning the edits to apply atomically with the save.
fn (mut app App) on_will_save_wait_until(request Request) Response {
	params := json2.decode[WillSaveTextDocumentParams](request.params) or {
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
	// Return the edits only. We must NOT mutate the server's document state here:
	// the client may cancel, reject, or transform the edit, and it will send the
	// authoritative new content via a subsequent didChange/didSave. Mutating now
	// would desynchronize the server from the editor (P0-07 item 7).
	edits, _ := app.format_content(uri, content)
	return Response{
		id:     request.id
		result: edits
	}
}

// handle_prepare_rename handles textDocument/prepareRename by returning the range
// and placeholder text for the identifier under the cursor, or an empty result
// when the cursor is not on a renameable symbol.
fn (mut app App) handle_prepare_rename(request Request) Response {
	params := json2.decode[TextDocumentPositionParams](request.params) or {
		$if debug { log('Failed to decode TextDocumentPositionParams for prepareRename: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	real_path := uri_to_path(params.text_document.uri)
	content := app.open_files[params.text_document.uri] or { os.read_file(real_path) or { '' } }
	lines := content.split_into_lines()
	if params.position.line < 0 || params.position.line >= lines.len {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	line_text := lines[params.position.line]
	start, end := find_word_bounds_at_col(line_text, params.position.char, app.position_encoding)
	if start < 0 || end <= start {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	symbol := substr_by_char_bounds(line_text, start, end, app.position_encoding)
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

// substr_by_char_bounds returns the substring of `line` between the given
// character (code point) boundaries. It converts the character offsets to byte
// offsets first, so the slice can never land in the middle of a multi-byte
// UTF-8 sequence. Callers that receive character offsets (e.g. from
// find_word_bounds_at_col) must use this instead of raw byte slicing (P0-01).
fn substr_by_char_bounds(line string, char_start int, char_end int, enc PositionEncoding) string {
	bs := encoded_col_to_byte(line, char_start, enc)
	be := encoded_col_to_byte(line, char_end, enc)
	if bs > be || be > line.len {
		return ''
	}
	return line[bs..be]
}

// find_word_bounds_at_col returns [start, end) character bounds (in the client's
// `enc` units) for the identifier at `col`. If `col` is just after an
// identifier, it still resolves that identifier. Slice the line via
// substr_by_char_bounds, never raw byte indexing (P0-01).
fn find_word_bounds_at_col(line string, col int, enc PositionEncoding) (int, int) {
	if line == '' {
		return -1, -1
	}
	mut c := encoded_col_to_byte(line, col, enc)
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
	return byte_to_encoded_col(line, start, enc), byte_to_encoded_col(line, end, enc)
}

// handle_workspace_symbol searches all tracked and on-disk .v files in the
// open project for symbols whose names contain the query string (case-insensitive)
// and returns them as WorkspaceSymbol items.
fn (mut app App) handle_workspace_symbol(request Request) Response {
	params := json2.decode[WorkspaceSymbolParams](request.params) or {
		$if debug { log('Failed to decode WorkspaceSymbolParams: ${err}') }
		return Response{
			id:     request.id
			result: []WorkspaceSymbol{}
		}
	}
	query := params.query
	token := app.begin_progress('Searching workspace symbols…')
	// Populate/refresh the persistent index once, then answer from it. Tests are
	// included so test functions/types are discoverable (P2-11). Subsequent
	// queries reuse the index instead of re-reading and re-parsing the workspace.
	app.ensure_dirs_indexed(app.index_query_dirs())
	app.ensure_loose_file_dirs_shallow_indexed()
	results := app.query_workspace_symbols(query)
	app.end_progress(token, '')
	return Response{
		id:     request.id
		result: results
	}
}

// Helper to apply an incremental change to the document content
// line_start_offsets returns the byte offset at which each line begins,
// treating \n, \r\n, and \r as line terminators (LSP §3 treats all three as
// valid). The returned slice always has at least one entry (offset 0).
fn line_start_offsets(content string) []int {
	mut offsets := [0]
	mut i := 0
	for i < content.len {
		c := content[i]
		if c == `\n` {
			offsets << i + 1
			i++
		} else if c == `\r` {
			if i + 1 < content.len && content[i + 1] == `\n` {
				offsets << i + 2
				i += 2
			} else {
				offsets << i + 1
				i++
			}
		} else {
			i++
		}
	}
	return offsets
}

// line_text_without_terminator returns the text of `line` with any trailing
// \n, \r\n, or \r stripped, so character offsets map onto line content only.
fn line_text_without_terminator(content string, starts []int, line int) string {
	line_start := starts[line]
	seg_end := if line + 1 < starts.len { starts[line + 1] } else { content.len }
	mut e := seg_end
	if e > line_start && content[e - 1] == `\n` {
		e--
		if e > line_start && content[e - 1] == `\r` {
			e--
		}
	} else if e > line_start && content[e - 1] == `\r` {
		e--
	}
	return content[line_start..e]
}

// position_to_byte_offset maps an LSP (line, character) position to a byte
// offset within `content`. Positions past the end of a line clamp to the line's
// content end (before its terminator); positions past the last line clamp to
// the content length.
fn position_to_byte_offset(content string, starts []int, line int, character int, enc PositionEncoding) int {
	if line < 0 {
		return 0
	}
	if line >= starts.len {
		return content.len
	}
	lt := line_text_without_terminator(content, starts, line)
	byte_in_line := encoded_col_to_byte(lt, character, enc)
	return starts[line] + byte_in_line
}

// apply_incremental_change applies one incremental edit against `content`,
// splicing the raw string by byte offset so that existing line terminators
// (CRLF, CR, LF, and a final-newline distinction) are preserved exactly
// (P0-07). Returns the original content unchanged for an invalid/reversed
// range rather than corrupting the buffer.
fn apply_incremental_change(content string, range LSPRange, new_text string, enc PositionEncoding) string {
	if range.start.line < 0 || range.start.char < 0 || range.end.line < 0 || range.end.char < 0 {
		return content
	}
	if range.end.line < range.start.line
		|| (range.end.line == range.start.line && range.end.char < range.start.char) {
		return content
	}
	starts := line_start_offsets(content)
	start_byte := position_to_byte_offset(content, starts, range.start.line, range.start.char, enc)
	end_byte := position_to_byte_offset(content, starts, range.end.line, range.end.char, enc)
	if start_byte > end_byte || start_byte > content.len || end_byte > content.len {
		return content
	}
	return content[..start_byte] + new_text + content[end_byte..]
}

// incremental_change_is_valid reports whether `range` maps to an applicable byte
// span in `content` (non-negative, non-reversed, in bounds). on_did_change uses
// this to detect an edit it cannot apply, so it can refuse the change WITHOUT
// advancing the document version — dropping the edit while bumping the version
// would silently desynchronize the buffer (P0-07).
fn incremental_change_is_valid(content string, range LSPRange, enc PositionEncoding) bool {
	if range.start.line < 0 || range.start.char < 0 || range.end.line < 0 || range.end.char < 0 {
		return false
	}
	if range.end.line < range.start.line
		|| (range.end.line == range.start.line && range.end.char < range.start.char) {
		return false
	}
	starts := line_start_offsets(content)
	// Reject a range whose start or end line does not exist in the document. A
	// desynced client can send lines past EOF; position_to_byte_offset clamps
	// those to content.len, which would make an out-of-bounds edit look valid and
	// get appended at EOF while the version advances, desyncing the buffer (P0-07).
	if range.start.line >= starts.len || range.end.line >= starts.len {
		return false
	}
	// Reject a character offset past its line's encoded length. On an existing
	// line, position_to_byte_offset clamps a too-large character to the line end,
	// which would likewise make an invalid range look valid and get applied at EOL
	// while the version advances — the same desync in the character dimension.
	start_line_text := line_text_without_terminator(content, starts, range.start.line)
	if range.start.char > byte_to_encoded_col(start_line_text, start_line_text.len, enc) {
		return false
	}
	end_line_text := line_text_without_terminator(content, starts, range.end.line)
	if range.end.char > byte_to_encoded_col(end_line_text, end_line_text.len, enc) {
		return false
	}
	start_byte := position_to_byte_offset(content, starts, range.start.line, range.start.char, enc)
	end_byte := position_to_byte_offset(content, starts, range.end.line, range.end.char, enc)
	return start_byte <= end_byte && start_byte <= content.len && end_byte <= content.len
}

// find_references handles the LSP references request, returning all locations of a symbol.
fn (mut app App) find_references(request Request) Response {
	params := json2.decode[ReferenceParams](request.params) or {
		$if debug { log('Failed to decode ReferenceParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	path := params.text_document.uri
	line := params.position.line
	col := params.position.char

	// Get symbol name at cursor
	symbol := app.get_word_at_position(path, line, col)
	if symbol == '' {
		return Response{
			id:     request.id
			result: 'null'
		}
	}

	// Resolve references from the project's reference-occurrence index.
	scope := app.index_scope_for_uri(path)
	anchor := app.resolve_symbol_anchor(path, line, col)
	mut locations := if a := anchor {
		// References may fall back to lexical occurrences past the candidate cap.
		app.search_symbol_in_dirs_semantic(symbol, a, scope, request.id, true)
	} else {
		app.search_symbol_in_dirs(symbol, request.id)
	}
	if locations.len == 0 {
		locations = app.search_symbol_in_dirs(symbol, request.id)
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
	params := json2.decode[RenameParams](request.params) or {
		$if debug { log('Failed to decode RenameParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	path := params.text_document.uri
	line := params.position.line
	col := params.position.char
	new_name := params.new_name

	// Get symbol name at cursor
	symbol := app.get_word_at_position(path, line, col)
	if symbol == '' {
		return Response{
			id:     request.id
			result: 'null'
		}
	}

	// A destructive rename is safe only when the bounded index covers every
	// source in the project/module. Oversized, unreadable, or count-capped files
	// may contain additional references that must not be left unchanged.
	scope := app.index_scope_for_uri(path)
	app.ensure_index_scope(scope)
	if !app.index_is_complete_for_scope(scope) {
		log('rename: source index is incomplete; refusing a partial workspace edit')
		return Response{
			id:     request.id
			result: 'null'
		}
	}

	// Rename is destructive, so it must be driven by a stable semantic symbol
	// identity. If we cannot resolve the symbol under the cursor to a compiler
	// definition anchor, we refuse rather than fall back to lexical same-name
	// matching, which would rename unrelated symbols in other scopes/modules
	// (P1-04).
	anchor := app.resolve_symbol_anchor(path, line, col) or {
		log('rename: could not resolve a semantic anchor for "${symbol}"; refusing lexical rename (P1-04)')
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	// Rename is destructive: never accept the scope-unsafe lexical fallback. Past
	// the candidate cap search_symbol_in_dirs_semantic returns none, and an
	// unresolved rename is refused below rather than editing unrelated symbols.
	locations := app.search_symbol_in_dirs_semantic(symbol, anchor, scope, request.id, false)
	if locations.len == 0 {
		log('rename: no scope-safe occurrences for "${symbol}" (unresolved or above candidate cap); refusing')
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
			loc.range.start.char + byte_to_encoded_col(symbol, symbol.len, app.position_encoding)
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
		mut version := ?i64(none)
		if uri in app.open_files_versions {
			version = app.open_files_versions[uri]
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

// client_col_to_byte_col converts a client `character` offset (in the negotiated
// encoding) on `line` of the document at `uri` to a byte column, which is the
// unit the V compiler's -line-info expects. Falls back to the raw column when
// the document/line is unavailable.
fn (app &App) client_col_to_byte_col(uri string, line int, col int) int {
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { return col } }
	lines := content.split_into_lines()
	if line < 0 || line >= lines.len {
		return col
	}
	return encoded_col_to_byte(lines[line], col, app.position_encoding)
}

// byte_col_to_client_col converts a byte column reported by the compiler (for
// the document at `uri`, on 0-based `line`) back to the client's negotiated
// encoding. Falls back to the raw column when the document/line is unavailable.
fn (app &App) byte_col_to_client_col(uri string, line int, byte_col int) int {
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { return byte_col } }
	lines := content.split_into_lines()
	if line < 0 || line >= lines.len {
		return byte_col
	}
	return byte_to_encoded_col(lines[line], byte_col, app.position_encoding)
}

fn (app &App) get_word_at_position(uri string, line int, col int) string {
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { return '' } }
	lines := content.split_into_lines()
	if line < 0 || line >= lines.len {
		return ''
	}

	text := lines[line]
	byte_col := encoded_col_to_byte(text, col, app.position_encoding)
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

// PositionEncoding is the unit the client uses for LSP `character` offsets.
// LSP defaults to utf16; utf8 (byte offsets) and utf32 (code points) are only
// used when negotiated via the client's `general.positionEncodings`.
enum PositionEncoding {
	utf16
	utf8
	utf32
}

// parse_position_encoding maps an LSP encoding string to a PositionEncoding.
fn parse_position_encoding(s string) ?PositionEncoding {
	return match s {
		'utf-16' { PositionEncoding.utf16 }
		'utf-8' { PositionEncoding.utf8 }
		'utf-32' { PositionEncoding.utf32 }
		else { none }
	}
}

// position_encoding_string is the LSP wire string for a PositionEncoding.
fn position_encoding_string(e PositionEncoding) string {
	return match e {
		.utf16 { 'utf-16' }
		.utf8 { 'utf-8' }
		.utf32 { 'utf-32' }
	}
}

// utf8_seq_len returns the number of bytes in the UTF-8 sequence whose lead
// byte is `b` (1 for invalid lead bytes, so we always make progress).
@[inline]
fn utf8_seq_len(b u8) int {
	return if (b & 0x80) == 0 {
		1
	} else if (b & 0xe0) == 0xc0 {
		2
	} else if (b & 0xf0) == 0xe0 {
		3
	} else if (b & 0xf8) == 0xf0 {
		4
	} else {
		1
	}
}

// encoded_col_to_byte converts an LSP `character` offset expressed in `enc`
// units into a byte offset within `line`. This is the inbound half of the
// PositionCodec: every client-supplied character position must pass through it
// before indexing bytes (P0-01). Non-BMP characters count as two UTF-16 units.
fn encoded_col_to_byte(line string, col int, enc PositionEncoding) int {
	if col <= 0 {
		return 0
	}
	match enc {
		.utf8 {
			return if col >= line.len { line.len } else { col }
		}
		.utf32 {
			return utf8_char_to_byte_index(line, col)
		}
		.utf16 {
			mut units := 0
			mut i := 0
			for i < line.len {
				if units >= col {
					return i
				}
				size := utf8_seq_len(line[i])
				u := if size == 4 { 2 } else { 1 }
				if units + u > col {
					// col lands in the middle of a surrogate pair; clamp to the
					// start of this character.
					return i
				}
				units += u
				i += size
			}
			return line.len
		}
	}
}

// byte_to_encoded_col converts a byte offset within `line` into an LSP
// `character` offset in `enc` units. This is the outbound half of the codec:
// every character position returned to the client must pass through it.
fn byte_to_encoded_col(line string, byte_idx int, enc PositionEncoding) int {
	if byte_idx <= 0 {
		return 0
	}
	match enc {
		.utf8 {
			return if byte_idx >= line.len { line.len } else { byte_idx }
		}
		.utf32 {
			return utf8_byte_to_char_index(line, byte_idx)
		}
		.utf16 {
			mut units := 0
			mut i := 0
			for i < line.len && i < byte_idx {
				size := utf8_seq_len(line[i])
				units += if size == 4 { 2 } else { 1 }
				i += size
			}
			return units
		}
	}
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

// get_word_at_col extracts the identifier at column `col` (in `enc` units)
// within a single line. Returns '' if the character at `col` is not an
// identifier character.
fn get_word_at_col(line string, col int, enc PositionEncoding) string {
	byte_col := encoded_col_to_byte(line, col, enc)
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

fn source_definition_kind_is_supported(kind int) bool {
	return kind in [sym_kind_function, sym_kind_struct, sym_kind_enum, sym_kind_interface,
		sym_kind_constant, sym_kind_class]
}

fn source_declaration_occurrence_is_code(sym DocumentSymbol, occurrences []TokenOccurrence) bool {
	return occurrences.any(it.line == sym.selection_range.start.line
		&& it.start_char == sym.selection_range.start.char
		&& it.end_char == sym.selection_range.end.char)
}

fn source_declaration_is_public(uri string, sym DocumentSymbol, app &App) bool {
	content := app.index_source_for(uri) or { return false }
	lines := content.split_into_lines()
	if sym.range.start.line < 0 || sym.range.start.line >= lines.len {
		return false
	}
	return lines[sym.range.start.line].trim_space().starts_with('pub ')
}

// source_declaration_is_compile_time_conditional identifies declarations nested
// under `$if` or `$else`. The shallow index does not evaluate compile-time
// conditions, so every such declaration must defer to compiler-backed lookup.
fn source_declaration_is_compile_time_conditional(content string, declaration_line int) bool {
	if declaration_line < 0 {
		return false
	}
	lines := content.split_into_lines()
	mut brace_depth := 0
	mut conditional_depths := []int{}
	mut pending_conditional := false
	mut in_block_comment := false
	mut quote := u8(0)
	for line_idx, line in lines {
		if line_idx == declaration_line {
			return conditional_depths.len > 0
		}
		mut col := 0
		for col < line.len {
			if in_block_comment {
				comment_end := line[col..].index('*/') or { break }
				col += comment_end + 2
				in_block_comment = false
				continue
			}
			if quote != 0 {
				if line[col] == `\\` && col + 1 < line.len {
					col += 2
					continue
				}
				if line[col] == quote {
					quote = 0
				}
				col++
				continue
			}
			if col + 1 < line.len && line[col] == `/` && line[col + 1] == `/` {
				break
			}
			if col + 1 < line.len && line[col] == `/` && line[col + 1] == `*` {
				in_block_comment = true
				col += 2
				continue
			}
			if line[col] == `'` || line[col] == `"` || line[col] == 96 {
				quote = line[col]
				col++
				continue
			}
			if line[col] == `$` {
				directive_len := if line[col..].starts_with('$if') {
					3
				} else if line[col..].starts_with('$else') {
					5
				} else {
					0
				}
				if directive_len > 0 && (col + directive_len == line.len
					|| !is_ident_char(line[col + directive_len])) {
					pending_conditional = true
					col += directive_len
					continue
				}
			}
			if line[col] == `{` {
				brace_depth++
				if pending_conditional {
					conditional_depths << brace_depth
					pending_conditional = false
				}
			} else if line[col] == `}` {
				if conditional_depths.len > 0 && conditional_depths.last() == brace_depth {
					conditional_depths.delete_last()
				}
				if brace_depth > 0 {
					brace_depth--
				}
			}
			col++
		}
	}
	return false
}

// source_occurrence_precedes_local_declaration recognizes every target on the
// comma-separated left side of `:=`. Invalid or ambiguous matches only defer
// to compiler-backed lookup, so this deliberately favors avoiding false
// indexed definitions for shadowed locals.
fn source_occurrence_precedes_local_declaration(line string, end_byte int) bool {
	if end_byte < 0 || end_byte > line.len {
		return false
	}
	declaration_offset := line[end_byte..].index(':=') or { return false }
	for i := end_byte; i < end_byte + declaration_offset; i++ {
		c := line[i]
		if !is_ident_char(c) && c !in [`,`, ` `, `\t`] {
			return false
		}
	}
	return true
}

fn source_occurrence_has_colon_suffix(line string, end_byte int) bool {
	if end_byte < 0 || end_byte > line.len {
		return false
	}
	mut suffix_byte := end_byte
	for suffix_byte < line.len && (line[suffix_byte] == ` ` || line[suffix_byte] == `\t`) {
		suffix_byte++
	}
	return suffix_byte < line.len && line[suffix_byte] == `:`
}

fn source_occurrence_has_dot_suffix(line string, end_byte int) bool {
	if end_byte < 0 || end_byte > line.len {
		return false
	}
	mut suffix_byte := end_byte
	for suffix_byte < line.len && (line[suffix_byte] == ` ` || line[suffix_byte] == `\t`) {
		suffix_byte++
	}
	return suffix_byte < line.len && line[suffix_byte] == `.`
}

fn source_occurrence_is_goto_target(line string, start_byte int) bool {
	if start_byte < 0 || start_byte > line.len {
		return false
	}
	mut keyword_end := start_byte
	for keyword_end > 0 && (line[keyword_end - 1] == ` ` || line[keyword_end - 1] == `\t`) {
		keyword_end--
	}
	mut keyword_start := keyword_end
	for keyword_start > 0 && is_ident_char(line[keyword_start - 1]) {
		keyword_start--
	}
	return line[keyword_start..keyword_end] == 'goto'
}

fn source_occurrence_is_compile_time_condition(line string, line_idx int, start_byte int, if_occurrences []TokenOccurrence, enc PositionEncoding) bool {
	if start_byte < 0 || start_byte > line.len {
		return false
	}
	for occurrence in if_occurrences {
		if occurrence.line != line_idx {
			continue
		}
		directive_start := encoded_col_to_byte(line, occurrence.start_char, enc)
		directive_end := encoded_col_to_byte(line, occurrence.end_char, enc)
		if directive_start <= 0 || directive_end > start_byte || line[directive_start - 1] != `$` {
			continue
		}
		mut col := directive_end
		mut reaches_target := true
		mut in_block_comment := false
		for col < start_byte {
			if in_block_comment {
				if col + 1 < start_byte && line[col] == `*` && line[col + 1] == `/` {
					in_block_comment = false
					col += 2
					continue
				}
				col++
				continue
			}
			if col + 1 < start_byte && line[col] == `/` && line[col + 1] == `*` {
				in_block_comment = true
				col += 2
				continue
			}
			if line[col] == `"` || line[col] == `'` {
				quote := line[col]
				col++
				for col < start_byte {
					if line[col] == `\\` {
						col += 2
						continue
					}
					if line[col] == quote {
						col++
						break
					}
					col++
				}
				continue
			}
			if line[col] == `{` {
				reaches_target = false
				break
			}
			col++
		}
		if reaches_target {
			return true
		}
	}
	return false
}

fn source_line_is_module_or_import_declaration(lines []string, target_line int) bool {
	mut in_import_block := false
	mut scan_state := ImportScanState{}
	for line_idx, raw_line in lines {
		if line_idx > target_line {
			break
		}
		line := source_line_import_code(raw_line, mut scan_state).trim_space()
		if in_import_block {
			if line_idx == target_line {
				return true
			}
			if line.starts_with(')') {
				in_import_block = false
			}
			continue
		}
		if line.starts_with('import ') {
			if line_idx == target_line {
				return true
			}
			if line[7..].all_before('//').trim_space() == '(' {
				in_import_block = true
			}
			continue
		}
		if line_idx == target_line {
			return line.starts_with('module ')
		}
	}
	return false
}

fn source_occurrence_is_method_declaration(line string, start_byte int) bool {
	if start_byte < 0 || start_byte > line.len {
		return false
	}
	mut prefix := line[..start_byte].trim_space()
	if prefix.starts_with('pub ') {
		prefix = prefix[4..].trim_space()
	}
	if !prefix.starts_with('fn ') {
		return false
	}
	receiver := prefix[3..].trim_space()
	return receiver.starts_with('(') && receiver.ends_with(')')
}

fn source_occurrence_is_interface_method_signature(lines []string, target_line int, start_byte int, end_byte int) bool {
	if target_line < 0 || target_line >= lines.len || start_byte < 0 || end_byte <= start_byte
		|| end_byte > lines[target_line].len {
		return false
	}
	line := lines[target_line]
	mut suffix_byte := end_byte
	for suffix_byte < line.len && (line[suffix_byte] == ` ` || line[suffix_byte] == `\t`) {
		suffix_byte++
	}
	if suffix_byte >= line.len || line[suffix_byte] != `(` {
		return false
	}
	mut brace_depth := 0
	mut interface_depth := 0
	mut pending_interface := false
	mut scan_state := ImportScanState{}
	for line_idx, raw_line in lines {
		if line_idx > target_line {
			break
		}
		if line_idx == target_line {
			if interface_depth > 0 {
				return true
			}
			mut prefix := raw_line[..start_byte].trim_space()
			if prefix.starts_with('pub ') {
				prefix = prefix[4..].trim_space()
			}
			return (pending_interface || prefix.starts_with('interface ')) && prefix.contains('{')
		}
		code := source_line_import_code(raw_line, mut scan_state)
		if interface_depth == 0 && !pending_interface {
			mut declaration := code.trim_space()
			if declaration.starts_with('pub ') {
				declaration = declaration[4..].trim_space()
			}
			pending_interface = declaration.starts_with('interface ')
		}
		for c in code {
			if c == `{` {
				brace_depth++
				if pending_interface {
					interface_depth = brace_depth
					pending_interface = false
				}
			} else if c == `}` {
				if interface_depth == brace_depth {
					interface_depth = 0
				}
				if brace_depth > 0 {
					brace_depth--
				}
			}
		}
	}
	return false
}

fn source_occurrence_is_attribute(lines []string, target_line int, start_byte int) bool {
	if target_line < 0 || target_line >= lines.len || start_byte < 0
		|| start_byte > lines[target_line].len {
		return false
	}
	mut in_block_comment := false
	mut quote := u8(0)
	mut attribute_depth := 0
	for line_idx, line in lines {
		if line_idx > target_line {
			break
		}
		limit := if line_idx == target_line { start_byte } else { line.len }
		mut col := 0
		for col < limit {
			if in_block_comment {
				if col + 1 < limit && line[col] == `*` && line[col + 1] == `/` {
					in_block_comment = false
					col += 2
					continue
				}
				col++
				continue
			}
			if quote != 0 {
				if line[col] == `\\` && col + 1 < limit {
					col += 2
					continue
				}
				if line[col] == quote {
					quote = 0
				}
				col++
				continue
			}
			if col + 1 < limit && line[col] == `/` && line[col + 1] == `/` {
				break
			}
			if col + 1 < limit && line[col] == `/` && line[col + 1] == `*` {
				in_block_comment = true
				col += 2
				continue
			}
			if line[col] == `"` || line[col] == `'` || line[col] == 96 {
				quote = line[col]
				col++
				continue
			}
			if attribute_depth == 0 && col + 1 < limit && line[col] == `@` && line[col + 1] == `[` {
				attribute_depth = 1
				col += 2
				continue
			}
			if attribute_depth > 0 {
				if line[col] == `[` {
					attribute_depth++
				} else if line[col] == `]` {
					attribute_depth--
				}
			}
			col++
		}
	}
	return attribute_depth > 0
}

fn source_occurrence_is_enum_member_declaration(content string, symbol string, target_line int) bool {
	for declaration in parse_document_symbols(content) {
		if declaration.kind != sym_kind_enum {
			continue
		}
		if declaration.children.any(it.kind == sym_kind_enum_member && it.name == symbol
			&& it.selection_range.start.line == target_line)
		{
			return true
		}
	}
	return false
}

fn source_occurrence_is_generic_parameter(lines []string, line_idx int, start_byte int, end_byte int) bool {
	if line_idx < 0 || line_idx >= lines.len || start_byte < 0 || end_byte <= start_byte
		|| end_byte > lines[line_idx].len {
		return false
	}
	mut open_line := line_idx
	mut open_byte := start_byte
	mut found_open := false
	for {
		line := lines[open_line]
		mut col := if open_line == line_idx { start_byte } else { line.len }
		for col > 0 {
			col--
			if line[col] == `]` {
				return false
			}
			if line[col] == `[` {
				open_byte = col
				found_open = true
				break
			}
		}
		if found_open || open_line == 0 {
			break
		}
		open_line--
	}
	if !found_open {
		return false
	}
	mut close_line := line_idx
	mut close_byte := end_byte
	mut found_close := false
	for close_line < lines.len {
		line := lines[close_line]
		mut col := if close_line == line_idx { end_byte } else { 0 }
		for col < line.len {
			if line[col] == `[` {
				return false
			}
			if line[col] == `]` {
				close_byte = col
				found_close = true
				break
			}
			col++
		}
		if found_close {
			break
		}
		close_line++
	}
	if !found_close {
		return false
	}
	mut parameter_lines := []string{}
	if open_line == close_line {
		parameter_lines << lines[open_line][open_byte + 1..close_byte]
	} else {
		parameter_lines << lines[open_line][open_byte + 1..]
		for parameter_line in open_line + 1 .. close_line {
			parameter_lines << lines[parameter_line]
		}
		parameter_lines << lines[close_line][..close_byte]
	}
	for parameter in parameter_lines.join('\n').split(',') {
		name := parameter.trim_space()
		if name == '' || name[0] >= `0` && name[0] <= `9` {
			return false
		}
		for c in name {
			if !is_ident_char(c) {
				return false
			}
		}
	}
	mut declaration_prefix := lines[open_line][..open_byte].trim_space()
	if declaration_prefix.starts_with('pub ') {
		declaration_prefix = declaration_prefix[4..].trim_space()
	}
	return declaration_prefix.starts_with('fn ') || declaration_prefix.starts_with('struct ')
		|| declaration_prefix.starts_with('interface ') || declaration_prefix.starts_with('type ')
}

// source_occurrences_have_potential_local_binding conservatively recognizes
// local declarations that can shadow a top-level or imported symbol. False
// positives only defer to compiler-backed lookup; false negatives could return
// the wrong indexed declaration, so type-suffixed names are treated as possible
// parameters even when a function signature spans multiple lines.
fn source_occurrences_have_potential_local_binding(lines []string, occurrences []TokenOccurrence, enc PositionEncoding) bool {
	for occurrence in occurrences {
		if occurrence.line < 0 || occurrence.line >= lines.len {
			continue
		}
		line := lines[occurrence.line]
		start_byte := encoded_col_to_byte(line, occurrence.start_char, enc)
		end_byte := encoded_col_to_byte(line, occurrence.end_char, enc)
		if start_byte < 0 || end_byte <= start_byte || end_byte > line.len {
			continue
		}
		if is_for_binding_highlight(line, start_byte, end_byte) {
			return true
		}
		if source_occurrence_precedes_local_declaration(line, end_byte) {
			return true
		}
		if source_occurrence_is_generic_parameter(lines, occurrence.line, start_byte, end_byte) {
			return true
		}
		mut suffix_byte := end_byte
		for suffix_byte < line.len && (line[suffix_byte] == ` ` || line[suffix_byte] == `\t`) {
			suffix_byte++
		}
		if suffix_byte > end_byte && suffix_byte < line.len
			&& (is_ident_char(line[suffix_byte]) || line[suffix_byte] in [`[`, `?`, `&`, `.`]) {
			return true
		}
	}
	return false
}

// active_indexed_source_file_names applies the compiler's native build-file
// filtering without removing inactive sources from the broader symbol index.
// Test files are direct compiler inputs, so normalize their `_test` suffix
// before checking platform and backend eligibility.
fn (app &App) active_indexed_source_file_names(dir string, include_tests bool) map[string]bool {
	mut file_names := os.ls(dir) or { return map[string]bool{} }
	file_names = file_names.filter(it.ends_with('.v'))
	normalized_dir := normalized_index_path(dir)
	for uri, _ in app.open_files {
		path := uri_to_path(uri)
		if normalized_index_path(os.dir(path)) != normalized_dir {
			continue
		}
		name := os.file_name(path)
		if name.ends_with('.v') && name !in file_names {
			file_names << name
		}
	}
	mut source_names := []string{}
	mut test_names := []string{}
	for name in file_names {
		if name.ends_with('_test.v') {
			test_names << name
		} else {
			source_names << name
		}
	}
	build_prefs := pref.Preferences{
		os:      pref.get_host_os()
		backend: .c
		arch:    pref.get_host_arch()
	}
	mut active := map[string]bool{}
	for path in build_prefs.should_compile_filtered_files(dir, source_names) {
		active[os.file_name(path)] = true
	}
	if include_tests {
		for name in test_names {
			build_name := name[..name.len - '_test.v'.len] + '.v'
			if build_prefs.should_compile_filtered_files(dir, [build_name]).len == 1 {
				active[name] = true
			}
		}
	}
	return active
}

// find_indexed_source_definition finds one unambiguous top-level declaration
// in `dir`. Methods and fields are intentionally excluded because resolving
// them safely requires receiver type information.
fn (mut app App) find_indexed_source_definition(dir string, symbol string, include_tests bool, require_public bool, expected_module string) ?Location {
	if dir == '' || dir == '/' || !os.is_dir(dir) {
		return none
	}
	app.ensure_dir_shallow_indexed(dir)
	normalized_dir := normalized_index_path(dir)
	// The shallow disk walk deliberately skips open buffers. Refresh those
	// entries explicitly so direct callers and unsaved files remain authoritative.
	for open_uri, _ in app.open_files {
		if normalized_index_path(os.dir(uri_to_path(open_uri))) == normalized_dir {
			app.reindex_uri(open_uri)
		}
	}
	active_file_names := app.active_indexed_source_file_names(dir, include_tests)
	mut matches := []Location{}
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		if !include_tests && uri.ends_with('_test.v') {
			continue
		}
		path := uri_to_path(uri)
		if normalized_index_path(os.dir(path)) != normalized_dir {
			continue
		}
		if os.file_name(path) !in active_file_names {
			continue
		}
		entry := app.symbol_index[uri] or { continue }
		if expected_module != '' && entry.module_name != expected_module {
			continue
		}
		source := app.index_source_for(uri) or { continue }
		declaration_occurrences := app.occurrences_for(uri)[symbol] or { continue }
		for sym in entry.doc_symbols {
			if !source_definition_kind_is_supported(sym.kind)
				|| extract_simple_fn_name(sym.name) != symbol {
				continue
			}
			if !source_declaration_occurrence_is_code(sym, declaration_occurrences) {
				continue
			}
			if source_declaration_is_compile_time_conditional(source, sym.range.start.line) {
				continue
			}
			if require_public && !source_declaration_is_public(uri, sym, app) {
				continue
			}
			matches << Location{
				uri:   uri
				range: sym.selection_range
			}
		}
	}
	if matches.len != 1 {
		return none
	}
	return matches[0]
}

// resolve_indexed_definition handles declaration lookup that does not need
// receiver type inference. Qualified names are constrained to their imported
// module, while bare names are constrained to the current V module directory.
fn (mut app App) resolve_indexed_definition(uri string, position Position) ?Location {
	content := app.index_source_for(uri) or { return none }
	lines := content.split_into_lines()
	if position.line < 0 || position.line >= lines.len || position.char < 0 {
		return none
	}
	line := lines[position.line]
	start, end := find_word_bounds_at_col(line, position.char, app.position_encoding)
	if start < 0 || end <= start {
		return none
	}
	symbol := substr_by_char_bounds(line, start, end, app.position_encoding)
	if symbol == '' {
		return none
	}
	// `it` can be introduced implicitly by array operations such as filter/map,
	// and `err` is implicit inside `or {}` blocks. Text-only indexing cannot
	// distinguish either binding from a top-level symbol.
	if symbol == 'it' || symbol == 'err' {
		return none
	}
	// Reuse the reference tokenizer to reject identifier-shaped text in comments
	// and string literals while still accepting executable string interpolations.
	file_occurrences := app.occurrences_for(uri)
	occurrences := file_occurrences[symbol] or { return none }
	if !occurrences.any(it.line == position.line && it.start_char == start && it.end_char == end) {
		return none
	}
	start_byte := encoded_col_to_byte(line, start, app.position_encoding)
	end_byte := encoded_col_to_byte(line, end, app.position_encoding)
	if source_line_is_module_or_import_declaration(lines, position.line) {
		return none
	}
	if source_occurrence_is_attribute(lines, position.line, start_byte) {
		return none
	}
	if source_occurrence_is_enum_member_declaration(content, symbol, position.line) {
		return none
	}
	if source_occurrence_is_method_declaration(line, start_byte) {
		return none
	}
	if source_occurrence_is_interface_method_signature(lines, position.line, start_byte, end_byte) {
		return none
	}
	if source_occurrence_has_dot_suffix(line, end_byte) && symbol in parse_import_aliases(content) {
		return none
	}
	if_occurrences := file_occurrences['if'] or { []TokenOccurrence{} }
	if source_occurrence_has_colon_suffix(line, end_byte)
		|| source_occurrence_is_goto_target(line, start_byte)
		|| source_occurrence_is_compile_time_condition(line, position.line, start_byte, if_occurrences, app.position_encoding) {
		return none
	}
	if start_byte > 0 && line[start_byte - 1] == `.` {
		dot_col := byte_to_encoded_col(line, start_byte - 1, app.position_encoding)
		alias := get_word_before_dot(line, dot_col, app.position_encoding)
		alias_occurrences := file_occurrences[alias] or { return none }
		if source_occurrences_have_potential_local_binding(lines, alias_occurrences,
			app.position_encoding)
		{
			return none
		}
		module_path := parse_import_aliases(content)[alias] or { return none }
		module_dir := app.resolve_indexed_import_module_dir(module_path, os.dir(uri_to_path(uri)))
		return app.find_indexed_source_definition(module_dir, symbol, false, true,
			module_path.all_after_last('.'))
	}
	if source_occurrences_have_potential_local_binding(lines, occurrences, app.position_encoding) {
		return none
	}
	return app.find_indexed_source_definition(os.dir(uri_to_path(uri)), symbol,
		uri.ends_with('_test.v'), false, get_module_name(content))
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
	mut in_import_block := false
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if in_import_block {
			if trimmed.starts_with(')') {
				in_import_block = false
				continue
			}
			parts := trimmed.all_before('//').fields()
			if parts.len > 0 {
				imports << parts[0]
			}
			continue
		}
		if !trimmed.starts_with('import ') {
			continue
		}
		rest := trimmed[7..].all_before('//').trim_space()
		if rest == '(' {
			in_import_block = true
			continue
		}
		// Strip optional `as alias` suffix
		parts := rest.fields()
		if parts.len > 0 {
			imports << parts[0]
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
fn (mut app App) find_doc_comment_for_symbol(symbol string, current_lines []string, current_file_uri string, imported_module string) string {
	// 1. Current file, but only for an unqualified symbol. A qualified
	// `module.symbol` must never inherit a same-named local declaration's docs.
	if imported_module == '' {
		decl_line := find_declaration_line(current_lines, symbol)
		if decl_line >= 0 {
			doc := extract_doc_comment(current_lines, decl_line)
			if doc != '' {
				return doc
			}
		}
	}

	// 2 & 3. Other open files and project .v files, via the persistent index
	// (avoids re-reading and re-parsing the whole project on every hover, P1-08).
	// Scope the lookup to the current module directory, then the current project,
	// so a same-named symbol from an unrelated project/module is never used.
	app.ensure_dirs_indexed(app.index_query_dirs())
	cur_dir := os.dir(uri_to_path(current_file_uri))
	scope_root := find_project_root(cur_dir)
	if imported_module != '' {
		rel := imported_module.replace('.', os.path_separator)
		base_dir := if scope_root != '' { scope_root } else { cur_dir }
		preferred_dir := os.join_path(base_dir, rel)
		if os.is_dir(preferred_dir) {
			indexed_doc := app.find_indexed_doc_in_scope(symbol, cur_dir, scope_root, preferred_dir)
			if indexed_doc != '' {
				return indexed_doc
			}
		}
		// A qualified stdlib symbol is likewise constrained to its imported
		// module. Do not fall through to builtin or another imported module.
		module_dir := os.join_path(v_dir, 'vlib', rel)
		if os.is_dir(module_dir) {
			return search_doc_in_vlib_dir(module_dir, symbol)
		}
		return ''
	} else {
		indexed_doc := app.find_indexed_doc_in_scope(symbol, cur_dir, scope_root, '')
		if indexed_doc != '' {
			return indexed_doc
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

// imported_module_at_symbol returns the imported module path qualifying the
// symbol at byte column `col`, or '' for an unqualified symbol.
fn imported_module_at_symbol(line string, col int, content string) string {
	start, _ := find_word_bounds_at_col(line, col, .utf8)
	if start <= 0 || line[start - 1] != `.` {
		return ''
	}
	alias := get_word_before_dot(line, start - 1, .utf8)
	if alias == '' {
		return ''
	}
	return parse_import_aliases(content)[alias] or { '' }
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

	temp_file := make_unique_temp_path('vls_fmt', real_path)
	os.write_file(temp_file, content) or {
		log('Failed to write temp file for formatting: ${err}')
		return []TextEdit{}, ''
	}

	// With -w flag, v fmt writes the formatted content back to the temp file.
	// Read from there instead of relying on stdout capture, which is
	// unreliable on Windows MSYS2.
	result := run_v_argv(build_v_fmt_args(temp_file), '')

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

	// Compute the document's true end position from line-start byte offsets, not
	// split_into_lines(): the latter drops the empty line after a trailing
	// newline, which would leave the final terminator outside the replacement and
	// let `v fmt` append an extra one (P0-08). `starts.len - 1` is the number of
	// line terminators; the final segment is the text after the last terminator
	// (empty when the file ends in a newline).
	starts := line_start_offsets(content)
	end_line := starts.len - 1
	final_segment := content[starts[end_line]..]
	end_char := byte_to_encoded_col(final_segment, final_segment.len, app.position_encoding)

	edit := TextEdit{
		range:    LSPRange{
			start: Position{
				line: 0
				char: 0
			}
			end:   Position{
				line: end_line
				char: end_char
			}
		}
		new_text: formatted
	}
	return [edit], formatted
}

// handle_formatting handles the LSP formatting request, returning edits to format the document.
fn (mut app App) handle_formatting(request Request) Response {
	params := json2.decode[DocumentFormattingParams](request.params) or {
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
	params := json2.decode[DocumentSymbolParams](request.params) or {
		log('Failed to decode DocumentSymbolParams: ${err}')
		return Response{
			id:     request.id
			result: []DocumentSymbol{}
		}
	}
	uri := params.text_document.uri
	// Serve from the persistent index, refreshing this one document first so it
	// reflects the latest buffer content.
	app.reindex_uri(uri)
	if entry := app.symbol_index[uri] {
		return Response{
			id:     request.id
			result: entry.doc_symbols
		}
	}
	content := app.open_files[uri] or { '' }
	return Response{
		id:     request.id
		result: encode_document_symbols(parse_document_symbols(content),
			content.split_into_lines(), app.position_encoding)
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
	params := json2.decode[InlayHintParams](request.params) or {
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
	mut imported_mods := []string{}
	if working_dir != '' && working_dir != '/' && os.is_dir(working_dir) {
		project_files := os.walk_ext(working_dir, '.v')
		for pf in project_files {
			if !pf.ends_with('_test.v') && pf != file_path {
				index_files << pf
			}
		}
		imported_mods = parse_imports(content)
	}

	// Project/open files are re-read live (they may change mid-session). vlib
	// module indexes are merged from a session cache below — walking and parsing
	// vlib on every inlayHint request was the dominant, needlessly repeated cost.
	mut fn_index := build_fn_index(index_files)
	for mod in imported_mods {
		app.merge_vlib_module_fns(mod, mut fn_index)
	}
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

		// Position the hint right after the variable name in the raw line. The
		// byte offset is re-encoded into the client's encoding (P0-01/P2-07).
		name_col := raw.index(var_name) or { continue }
		hints << InlayHint{
			position:     Position{
				line: line_idx
				char: byte_to_encoded_col(raw, name_col + var_name.len, app.position_encoding)
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

// merge_vlib_module_fns merges the fn→return-type index for a vlib module into
// `index`, building and caching it on first use. vlib source does not change
// during a session, so the walk+read+parse is done once per module rather than
// on every inlayHint request.
fn (mut app App) merge_vlib_module_fns(mod string, mut index map[string]string) {
	if mod !in app.vlib_fn_cache {
		mut built := map[string]string{}
		mod_path := mod.replace('.', '/')
		vlib_mod_dir := os.join_path(v_dir, 'vlib', mod_path)
		if os.is_dir(vlib_mod_dir) {
			mut vfiles := []string{}
			for vf in os.walk_ext(vlib_mod_dir, '.v') {
				if !vf.ends_with('_test.v') {
					vfiles << vf
				}
			}
			built = build_fn_index(vfiles)
		}
		app.vlib_fn_cache[mod] = built.move()
	}
	for name, ret in app.vlib_fn_cache[mod] {
		index[name] = ret
	}
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

// search_symbol_in_dirs returns every lexical occurrence of `symbol` across the
// indexed project, read from the reference-occurrence index rather than by
// re-walking and re-tokenizing the workspace on each request (P1-05).
fn (mut app App) search_symbol_in_dirs(symbol string, request_id int) []Location {
	app.ensure_dirs_indexed(app.index_query_dirs())
	app.ensure_loose_file_dirs_shallow_indexed()
	mut locations := []Location{}
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		if request_id in app.cancelled_requests {
			return locations
		}
		occ := app.occurrences_for(uri)
		positions := occ[symbol] or { continue }
		for p in positions {
			locations << Location{
				uri:   uri
				range: LSPRange{
					start: Position{
						line: p.line
						char: p.start_char
					}
					end:   Position{
						line: p.line
						char: p.end_char
					}
				}
			}
		}
	}
	return locations
}

// resolve_symbol_anchor resolves the canonical definition location for a symbol
// usage via compiler gd^ lookup. `ch` is a column in the client's negotiated
// encoding; it is converted to the byte column the compiler expects (P0-01).
// Returns none when the definition cannot be resolved.
fn (mut app App) resolve_symbol_anchor(uri string, line int, ch int) ?Location {
	mut probe_cols := []int{}
	// The compiler's gd^ lookup can misclassify a probe exactly on the first byte
	// of an identifier as the enclosing call. Indexed candidates always use that
	// first position, so probe two units into the identifier (or one for a two-unit
	// name). A one-unit or midpoint probe can be misclassified as the enclosing
	// call in nested expressions such as `println(shared_value())`.
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	lines := content.split_into_lines()
	if line >= 0 && line < lines.len {
		start, end := find_word_bounds_at_col(lines[line], ch, app.position_encoding)
		inner_offset := if end - start > 2 { 2 } else { 1 }
		inner := start + inner_offset
		if ch == start && inner > start && inner < end {
			probe_cols << inner
		}
	}
	if probe_cols.len == 0 {
		probe_cols << ch
	}
	for probe_col in probe_cols {
		byte_col := app.client_col_to_byte_col(uri, line, probe_col)
		line_info := '${line + 1}:gd^${byte_col}'
		result := app.run_v_line_info(.definition, uri, line_info)
		if result is Location {
			loc := result as Location
			if loc.uri != '' {
				return loc
			}
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

// reference_semantic_max_candidates bounds how many occurrences a references or
// rename request will verify with the compiler. Each verification launches a
// serial `run_v_line_info` (gd^) process, and the request loop cannot process a
// cancellation mid-scan, so an unbounded scan of a very common symbol could fire
// hundreds of serial compiles each up to compiler_timeout_ms (P1-04/P0-04). Past
// this cap the scan falls back to the unverified lexical occurrences: bounded and
// responsive, at the cost of scope precision for that one very common symbol.
const reference_semantic_max_candidates = 48

// collect_semantic_candidates returns lexical occurrences inside `scope`.
fn (mut app App) collect_semantic_candidates(symbol string, scope IndexScope) []Location {
	mut candidates := []Location{}
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		if !uri_is_in_index_scope(uri, scope) {
			continue
		}
		occ := app.occurrences_for(uri)
		positions := occ[symbol] or { continue }
		for p in positions {
			candidates << Location{
				uri:   uri
				range: LSPRange{
					start: Position{
						line: p.line
						char: p.start_char
					}
					end:   Position{
						line: p.line
						char: p.end_char
					}
				}
			}
		}
	}
	return candidates
}

// search_symbol_in_dirs_semantic reads scoped candidate occurrences of `symbol`
// from the reference index and keeps only those whose compiler definition lookup
// resolves to the same declaration anchor. Compiler work is capped after scope
// filtering. References may use lexical fallback over the cap; rename may not.
fn (mut app App) search_symbol_in_dirs_semantic(symbol string, anchor Location, scope IndexScope, request_id int, allow_lexical_fallback bool) []Location {
	started_ms := time.now().unix_milli()
	app.ensure_index_scope(scope)

	// Filter lexical candidates to the source project/module before applying the
	// cap, so same-named occurrences in unrelated workspace roots cannot make a
	// safe rename appear too expensive.
	candidates := app.collect_semantic_candidates(symbol, scope)

	// Too many candidates to verify one-compile-per-token without freezing the
	// loop. References fall back to the unverified lexical occurrences (bounded,
	// scope-unsafe but harmless); rename refuses (returns none) so it never edits
	// unrelated same-named symbols in other scopes.
	if candidates.len > reference_semantic_max_candidates {
		if !allow_lexical_fallback {
			app.send_log_message('semantic-scan symbol=${symbol} candidates=${candidates.len} exceeds cap ${reference_semantic_max_candidates}; refusing scope-unsafe resolution',
				2)
			return []Location{}
		}
		app.send_log_message('semantic-scan symbol=${symbol} candidates=${candidates.len} exceeds cap ${reference_semantic_max_candidates}; returning lexical occurrences',
			3)
		return candidates
	}

	mut locations := []Location{}
	mut anchor_cache := map[string]?Location{}
	for cand in candidates {
		if request_id in app.cancelled_requests {
			return locations
		}
		// A definition lookup performed on the declaration itself may return no
		// location. The candidate is nevertheless safe when its indexed position
		// is the canonical anchor returned for the user's selected occurrence.
		if same_anchor_location(cand, anchor) {
			locations << cand
			continue
		}
		resolved := app.resolve_symbol_anchor_cached(cand.uri, cand.range.start.line,
			cand.range.start.char, mut anchor_cache) or { continue }
		if same_anchor_location(resolved, anchor) {
			locations << cand
		}
	}
	elapsed_ms := time.now().unix_milli() - started_ms
	app.send_log_message('semantic-scan symbol=${symbol} candidates=${candidates.len} matches=${locations.len} elapsed_ms=${elapsed_ms}',
		4)
	return locations
}

// handle_code_action handles the LSP codeAction request, returning quick fixes and organize imports.
fn (mut app App) handle_code_action(request Request) Response {
	params := json2.decode[CodeActionParams](request.params) or {
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
	only := params.context.only or { []string{} }

	mut actions := []CodeAction{}

	// 1. Quick fixes for diagnostics.
	if code_action_kind_wanted(only, code_action_kind_quickfix) {
		for diag in diagnostics {
			if diag.message.contains('unknown module') {
				line_nr := diag.range.start.line
				if line_nr >= 0 && line_nr < lines.len
					&& lines[line_nr].trim_space().starts_with('import ') {
					// Remove the whole import line. When the line has a trailing
					// terminator (a following line-start exists) delete it too by
					// ending at [line_nr+1,0), so no blank line is left behind. When
					// the import is the final line with no newline, [line_nr+1,0) is
					// out of bounds and clients may reject the whole edit, so end at
					// the final line's encoded length instead (P0-09).
					starts := line_start_offsets(content)
					end_pos := if line_nr + 1 < starts.len {
						Position{
							line: line_nr + 1
							char: 0
						}
					} else {
						Position{
							line: line_nr
							char: byte_to_encoded_col(lines[line_nr], lines[line_nr].len,
								app.position_encoding)
						}
					}
					edit := WorkspaceEdit{
						changes: {
							uri: [
								TextEdit{
									range:    LSPRange{
										start: Position{
											line: line_nr
											char: 0
										}
										end:   end_pos
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
				}
			}
		}
	}

	// 2. Organize Imports — only safe when every import line forms a single
	// contiguous block. If imports are separated by any other code or comments
	// we refuse the action rather than delete the intervening text (P0-09).
	if code_action_kind_wanted(only, code_action_kind_source_organize_imports) {
		if action := build_safe_organize_imports_action(uri, content, lines, app.position_encoding) {
			actions << action
		}
	}

	return Response{
		id:     request.id
		result: actions
	}
}

// code_action_kind_wanted reports whether an action of `kind` should be offered
// given the client's requested `only` filter. An empty filter means "any".
// A requested kind matches if it equals or is a prefix of the action kind
// (LSP treats kinds hierarchically, e.g. 'source' covers 'source.organizeImports').
fn code_action_kind_wanted(only []string, kind string) bool {
	if only.len == 0 {
		return true
	}
	for want in only {
		if want == kind || kind.starts_with(want + '.') || kind == want {
			return true
		}
		if kind.starts_with(want) && (want.ends_with('.') || kind.len == want.len) {
			return true
		}
	}
	return false
}

// build_safe_organize_imports_action returns an Organize Imports action that is
// guaranteed to leave all non-import text byte-for-byte unchanged, or none when
// the imports are not a single contiguous block.
fn build_safe_organize_imports_action(uri string, content string, lines []string, enc PositionEncoding) ?CodeAction {
	mut import_lines := []int{}
	for i, line in lines {
		if line.trim_space().starts_with('import ') {
			import_lines << i
		}
	}
	if import_lines.len == 0 {
		return none
	}
	first := import_lines.first()
	last := import_lines.last()
	// Contiguity check: the imports must occupy every line in [first, last].
	if last - first + 1 != import_lines.len {
		log('organize imports: imports are non-contiguous; refusing to edit to avoid deleting intervening code (P0-09)')
		return none
	}
	// Sort + dedup the (trimmed) import lines.
	mut seen := map[string]bool{}
	mut unique_imports := []string{}
	for i in import_lines {
		imp := lines[i].trim_space()
		if !seen[imp] {
			unique_imports << imp
			seen[imp] = true
		}
	}
	unique_imports.sort()
	line_ending := line_ending_after_line(content, first)
	new_text := unique_imports.join(line_ending)
	// If nothing would change, don't offer a no-op edit.
	mut original := []string{}
	for i in first .. last + 1 {
		original << lines[i]
	}
	if original.join(line_ending) == new_text {
		return none
	}
	// Postcondition guard: the replaced block contains only import lines, so no
	// other text can be affected. Replace [first,0)..[last,eol_of_last).
	edit := WorkspaceEdit{
		changes: {
			uri: [
				TextEdit{
					range:    LSPRange{
						start: Position{
							line: first
							char: 0
						}
						end:   Position{
							line: last
							char: byte_to_encoded_col(lines[last], lines[last].len, enc)
						}
					}
					new_text: new_text
				},
			]
		}
	}
	return CodeAction{
		title: 'Organize Imports'
		kind:  code_action_kind_source_organize_imports
		edit:  edit
	}
}

// line_ending_after_line returns the terminator following `line`. Falling back
// to LF covers a final unterminated line and empty content.
fn line_ending_after_line(content string, line int) string {
	starts := line_start_offsets(content)
	if line < 0 || line + 1 >= starts.len {
		return '\n'
	}
	next_start := starts[line + 1]
	if next_start >= 2 && content[next_start - 2] == `\r` && content[next_start - 1] == `\n` {
		return '\r\n'
	}
	if next_start >= 1 && content[next_start - 1] == `\r` {
		return '\r'
	}
	return '\n'
}

// collect_module_fn_completions collects free-function completions from sibling
// files in the current module, via the persistent index. A V module lives in a
// single directory, so we make sure the open buffers and the current file's
// directory are indexed (cheap, shallow) and then read pre-parsed completion
// items from the index instead of re-walking and re-parsing on every keystroke.
fn (mut app App) collect_module_fn_completions(current_file_uri string, working_dir string) []Detail {
	current_content := app.open_files[current_file_uri] or {
		os.read_file(uri_to_path(current_file_uri)) or { '' }
	}
	current_module := get_module_name(current_content)
	// Keep open buffers fresh, then ensure the current module's directory is
	// indexed (covers loose files with no v.mod project root too).
	for uri, _ in app.open_files {
		app.reindex_uri(uri)
	}
	app.ensure_dir_shallow_indexed(working_dir)
	return app.query_module_fn_completions(current_module, current_file_uri, working_dir)
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
	params := json2.decode[DocumentRangeFormattingParams](request.params) or {
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
	// v fmt formats whole files, so we format the full document, then compute the
	// minimal changed line hunk (common prefix/suffix). We only emit an edit when
	// that hunk is fully contained inside the requested range; otherwise we return
	// no edits rather than risk touching text outside the requested range.
	temp_file := make_unique_temp_path('vls_rfmt', real_path)
	os.write_file(temp_file, content) or {
		log('Failed to write temp file for range formatting: ${err}')
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	// With -w, v fmt rewrites the temp file in place; read the file, not stdout.
	result := run_v_argv(build_v_fmt_args(temp_file), '')
	formatted := os.read_file(temp_file) or {
		os.rm(temp_file) or {}
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	os.rm(temp_file) or {
		$if debug { log('Failed to remove temp file for range formatting: ${err}') }
	}
	if result.exit_code != 0 || formatted == '' || formatted == content {
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	original_lines := content.split_into_lines()
	formatted_lines := formatted.split_into_lines()
	req_start := if params.range.start.line < 0 { 0 } else { params.range.start.line }
	mut req_end := params.range.end.line
	if req_end >= original_lines.len {
		req_end = original_lines.len - 1
	}
	if req_start >= original_lines.len || req_start > req_end {
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	// Common prefix length (number of identical leading lines).
	mut pre := 0
	for pre < original_lines.len && pre < formatted_lines.len
		&& original_lines[pre] == formatted_lines[pre] {
		pre++
	}
	// Common suffix length, not overlapping the prefix.
	mut suf := 0
	for suf < original_lines.len - pre && suf < formatted_lines.len - pre
		&& original_lines[original_lines.len - 1 - suf] == formatted_lines[formatted_lines.len - 1 - suf] {
		suf++
	}
	orig_hunk_start := pre
	orig_hunk_end := original_lines.len - suf // exclusive
	// The changed hunk must lie fully within the requested line range.
	if orig_hunk_start < req_start || orig_hunk_end - 1 > req_end {
		log('range formatting: changed hunk [${orig_hunk_start}..${orig_hunk_end}) outside requested range [${req_start}..${req_end}]; returning no edits')
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}
	fmt_hunk_end := formatted_lines.len - suf // exclusive
	new_text := formatted_lines[orig_hunk_start..fmt_hunk_end].join('\n') + '\n'
	edit := TextEdit{
		range:    LSPRange{
			start: Position{
				line: orig_hunk_start
				char: 0
			}
			end:   Position{
				line: orig_hunk_end
				char: 0
			}
		}
		new_text: new_text
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
	params := json2.decode[SelectionRangeParams](request.params) or {
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
		if pos.line < 0 || pos.char < 0 || pos.line >= lines.len {
			results << SelectionRange{
				range: LSPRange{
					start: pos
					end:   pos
				}
			}
			continue
		}
		line_text := lines[pos.line]
		// Outermost: full line range. The end char is the line length in the
		// client's encoding, not raw bytes (P0-01/P2-09).
		line_range := LSPRange{
			start: Position{
				line: pos.line
				char: 0
			}
			end:   Position{
				line: pos.line
				char: byte_to_encoded_col(line_text, line_text.len, app.position_encoding)
			}
		}
		start, end := find_word_bounds_at_col(line_text, pos.char, app.position_encoding)
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
	sectioned := json2.decode[DidChangeConfigurationParams](params_json) or {
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
	direct := json2.decode[DidChangeConfigurationDirectParams](params_json) or {
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
	sectioned_nested := json2.decode[DidChangeConfigurationParamsCompat](params_json) or {
		DidChangeConfigurationParamsCompat{}
	}
	if !resolved.has_inlay_hints {
		if enabled := sectioned_nested.settings.vls.inlay_hints.enabled {
			resolved.inlay_hints = enabled
			resolved.has_inlay_hints = true
		}
	}

	direct_nested := json2.decode[DidChangeConfigurationDirectParamsCompat](params_json) or {
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
	params := json2.decode[InitializeParams](request.params) or {
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
	// Negotiate the position encoding (P0-01). LSP defaults to UTF-16, which we
	// always support. If the client advertises UTF-8 we prefer it, because the V
	// compiler works in byte offsets, so UTF-8 needs no per-line conversion.
	// UTF-32 (code points) is chosen only if it is the client's sole option.
	app.position_encoding = negotiate_position_encoding(params)
	log('VLS: negotiated positionEncoding=${position_encoding_string(app.position_encoding)}')
	return none
}

// negotiate_position_encoding selects the server's position encoding from the
// client's advertised `general.positionEncodings`, preferring UTF-8, then the
// mandatory UTF-16, then UTF-32.
fn negotiate_position_encoding(params InitializeParams) PositionEncoding {
	if caps := params.capabilities {
		if general := caps.general {
			if encodings := general.position_encodings {
				mut has_utf16 := false
				mut has_utf32 := false
				for e in encodings {
					match e {
						'utf-8' { return PositionEncoding.utf8 }
						'utf-16' { has_utf16 = true }
						'utf-32' { has_utf32 = true }
						else {}
					}
				}
				if has_utf16 {
					return PositionEncoding.utf16
				}
				if has_utf32 {
					return PositionEncoding.utf32
				}
			}
		}
	}
	return PositionEncoding.utf16
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

// max_cancelled_ids bounds the cancellation maps so a client that sends
// $/cancelRequest for ids that never correspond to an in-flight request cannot
// grow them without limit (P0-04). Cancellation is best-effort, so dropping the
// oldest tracked ids when the bound is exceeded is safe.
const max_cancelled_ids = 4096

fn (mut app App) on_cancel_request(request Request) {
	if app.cancelled_raw_ids.len >= max_cancelled_ids {
		app.cancelled_raw_ids.clear()
	}
	if app.cancelled_requests.len >= max_cancelled_ids {
		app.cancelled_requests.clear()
	}
	// Capture the exact raw id first: json2 aborts decoding CancelRequestParams
	// when the id is a string, but string ids must still be cancellable
	// (P0-02/P0-03).
	if raw := extract_raw_id(request.params) {
		app.cancelled_raw_ids[raw] = true
		// Match every valid id by its exact raw token. Narrowing a fractional or
		// out-of-range numeric id to int can collide with a different request.
		log('VLS: request ${raw} marked as cancelled')
		return
	}
	if params := json2.decode[CancelRequestParams](request.params) {
		app.cancelled_requests[params.id] = true
		log('VLS: request ${params.id} marked as cancelled')
	} else {
		$if debug { log('Failed to decode CancelRequestParams') }
	}
}

// on_did_change_workspace_folders handles workspace/didChangeWorkspaceFolders by
// updating the server's list of workspace roots when the client adds or removes folders.
fn (mut app App) on_did_change_workspace_folders(request Request) {
	params := json2.decode[DidChangeWorkspaceFoldersParams](request.params) or {
		$if debug { log('Failed to decode DidChangeWorkspaceFoldersParams: ${err}') }
		return
	}
	// Remove folders that were closed.
	for folder in params.event.removed {
		path := uri_to_path(folder.uri).trim_space()
		if path == '' || path == '/' {
			continue
		}
		path_key := normalized_index_path(path)
		mut new_roots := []string{}
		for r in app.workspace_roots {
			if normalized_index_path(r) != path_key {
				new_roots << r
			}
		}
		app.workspace_roots = new_roots
		mut already_removed := false
		for removed in app.removed_workspace_roots {
			if normalized_index_path(removed) == path_key {
				already_removed = true
				break
			}
		}
		if !already_removed {
			app.removed_workspace_roots << path
		}
		// Drop now-stale index entries that belonged to the removed folder.
		app.drop_index_under(path)
	}
	// Add newly opened folders.
	for folder in params.event.added {
		path := uri_to_path(folder.uri).trim_space()
		if path == '' || path == '/' {
			continue
		}
		path_key := normalized_index_path(path)
		mut remaining_removed := []string{}
		for removed in app.removed_workspace_roots {
			if normalized_index_path(removed) != path_key {
				remaining_removed << removed
			}
		}
		app.removed_workspace_roots = remaining_removed
		mut already_active := false
		for root in app.workspace_roots {
			if normalized_index_path(root) == path_key {
				already_active = true
				break
			}
		}
		if !already_active {
			app.workspace_roots << path
		}
	}
	log('VLS: workspace roots updated to ${app.workspace_roots}')
}

// handle_code_lens handles textDocument/codeLens requests.
// Returns run/test lens items for fn main() and fn test_* declarations.
fn (mut app App) handle_code_lens(request Request) Response {
	params := json2.decode[CodeLensParams](request.params) or {
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
	lens := json2.decode[CodeLens](request.params) or {
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
	params := json2.decode[ExecuteCommandParams](request.params) or {
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
	params := json2.decode[InlineValueParams](request.params) or {
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
	params := json2.decode[TextDocumentPositionParams](request.params) or {
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
	if params.position.line < 0 || params.position.line >= lines.len {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	line_text := lines[params.position.line]
	start, end := find_word_bounds_at_col(line_text, params.position.char, app.position_encoding)
	if start < 0 || end <= start {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	symbol := substr_by_char_bounds(line_text, start, end, app.position_encoding)
	// Collect all occurrences of the symbol on this line.
	mut ranges := []LSPRange{}
	mut col := 0
	for col < line_text.len {
		idx := line_text[col..].index(symbol) or { break }
		abs := col + idx
		before_ok := abs == 0 || !is_ident_char(line_text[abs - 1])
		after_ok := abs + symbol.len >= line_text.len || !is_ident_char(line_text[abs + symbol.len])
		if before_ok && after_ok {
			sc := byte_to_encoded_col(line_text, abs, app.position_encoding)
			ec := byte_to_encoded_col(line_text, abs + symbol.len, app.position_encoding)
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
