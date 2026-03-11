// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os

fn (mut app App) operation_at_pos(method Method, request Request) Response {
	line_nr := request.params.position.line + 1
	col := request.params.position.char
	path := request.params.text_document.uri
	line_info := match method {
		.completion, .hover {
			'${line_nr}:${col}'
		}
		.signature_help {
			'${line_nr}:fn^${col}'
		}
		.definition {
			'${line_nr}:gd^${col}'
		}
		else {
			''
		}
	}
	result := app.run_v_line_info(method, path, line_info)
	log(result.str())
	return Response{
		id:     request.id
		result: result
	}
}

fn (mut app App) on_did_open(request Request) {
	uri := request.params.text_document.uri
	log('on_did_open: ${uri}')
	real_path := uri_to_path(uri)
	content := os.read_file(real_path) or {
		log('Failed to read file ${real_path}: ${err}')
		return
	}
	app.open_files[uri] = content
	app.text = content
	log('STORED CONTENT for uri=${uri}, FILE COUNT: ${app.open_files.len}')
}

// Returns instant red wavy errors
fn (mut app App) on_did_change(request Request) ?Notification {
	log('on did change(len=${request.params.content_changes.len})')
	if request.params.content_changes.len == 0 || request.params.content_changes[0].text == '' {
		log('on_did_change() no params')
		return none
	}
	uri := request.params.text_document.uri
	content := request.params.content_changes[0].text
	app.text = content
	app.open_files[uri] = content // Update tracked file
	path := uri
	v_errors := app.run_v_check(path, app.text)
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
	params := PublishDiagnosticsParams{
		uri:         request.params.text_document.uri
		diagnostics: diagnostics
	}
	notification := Notification{
		method: 'textDocument/publishDiagnostics'
		params: params
	}
	log('returning notification: ${notification}')
	return notification
}

fn (mut app App) find_references(request Request) Response {
	path := request.params.text_document.uri
	real_path := uri_to_path(path)
	line := request.params.position.line
	col := request.params.position.char

	// Get symbol name at cursor
	symbol := app.get_word_at_position(real_path, line, col)
	if symbol == '' {
		return Response{
			id:     request.id
			result: []Location{}
		}
	}

	// Search all .v files in working directory
	working_dir := os.dir(real_path)
	locations := app.search_symbol_in_project(working_dir, symbol)

	return Response{
		id:     request.id
		result: locations
	}
}

fn (mut app App) handle_rename(request Request) Response {
	path := request.params.text_document.uri
	real_path := uri_to_path(path)
	line := request.params.position.line
	col := request.params.position.char
	new_name := request.params.new_name

	// Get symbol name at cursor
	symbol := app.get_word_at_position(real_path, line, col)
	if symbol == '' {
		return Response{
			id:     request.id
			result: WorkspaceEdit{}
		}
	}

	// Find all references
	working_dir := os.dir(real_path)
	locations := app.search_symbol_in_project(working_dir, symbol)

	// Build WorkspaceEdit
	mut changes := map[string][]TextEdit{}
	for loc in locations {
		edit := TextEdit{
			range:    LSPRange{
				start: loc.range.start
				end:   Position{
					line: loc.range.start.line
					char: loc.range.start.char + symbol.len
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

	return Response{
		id:     request.id
		result: WorkspaceEdit{
			changes: changes
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
	if col >= text.len {
		return ''
	}

	// Find word boundaries (V identifiers: letters, digits, underscores)
	mut start := col
	mut end := col
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

// get_word_at_col extracts the identifier at column `col` within a single line.
// Returns '' if the character at `col` is not an identifier character.
fn get_word_at_col(line string, col int) string {
	if col >= line.len {
		return ''
	}
	if !is_ident_char(line[col]) {
		return ''
	}
	mut start := col
	mut end := col
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

// find_doc_comment_for_symbol searches for the vdoc comment for `symbol` across
// multiple sources in priority order:
//  1. current file lines (already split)
//  2. other open files in app.open_files
//  3. all .v files in the project working directory
//  4. vlib/builtin/ (always, for built-in functions like println)
//  5. vlib/<module>/ for each module imported in the current file
fn (app &App) find_doc_comment_for_symbol(symbol string, current_lines []string, current_file_uri string, vroot string) string {
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

	if vroot == '' {
		return ''
	}

	// 4. vlib/builtin/ — always search for built-in symbols
	builtin_dir := os.join_path(vroot, 'vlib', 'builtin')
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
		module_dir := os.join_path(vroot, 'vlib', module_rel)
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

fn (mut app App) handle_formatting(request Request) Response {
	path := request.params.text_document.uri
	real_path := uri_to_path(path)

	// Get the current content of the file
	content := app.open_files[path] or {
		os.read_file(real_path) or {
			log('Failed to read file for formatting: ${err}')
			return Response{
				id:     request.id
				result: []TextEdit{}
			}
		}
	}

	// Write content to a temp file
	temp_file := os.join_path(os.temp_dir(), 'vls_fmt_${os.getpid()}_${os.file_name(real_path)}')
	os.write_file(temp_file, content) or {
		log('Failed to write temp file for formatting: ${err}')
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}

	// Run fmt
	result := os.execute('v fmt -inprocess "${temp_file}"')

	// Clean up temp file
	os.rm(temp_file) or { log('Failed to remove temp file: ${err}') }

	// Check for errors
	if result.exit_code != 0 {
		log('v fmt failed with code ${result.exit_code}: ${result.output}')
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}

	// If content is unchanged, return empty edits
	if result.output == content {
		return Response{
			id:     request.id
			result: []TextEdit{}
		}
	}

	// Calculate the range of the entire document
	lines := content.split_into_lines()
	last_line := lines.len - 1
	last_char := if lines.len > 0 { lines[last_line].len } else { 0 }

	// Return a single TextEdit that replaces the entire document
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
		new_text: result.output
	}

	return Response{
		id:     request.id
		result: [edit]
	}
}

// handle_document_symbols parses the current file's text using a simple
// line-by-line token scan and returns top-level declaration symbols so the
// editor can populate its Outline / breadcrumbs view.
fn (mut app App) handle_document_symbols(request Request) Response {
	uri := request.params.text_document.uri
	content := app.open_files[uri] or { '' }
	symbols := parse_document_symbols(content)
	return Response{
		id:     request.id
		result: symbols
	}
}

// parse_document_symbols scans `content` line by line and extracts top-level
// V declarations: functions, methods, structs, enums, interfaces, constants,
// and type aliases. It is intentionally simple – the goal is to get the
// Outline view working quickly, not to replicate a full parser.
fn parse_document_symbols(content string) []DocumentSymbol {
	lines := content.split_into_lines()
	mut symbols := []DocumentSymbol{}

	for i, raw_line in lines {
		line := raw_line.trim_space()

		// Skip blank lines and pure comment lines
		if line == '' || line.starts_with('//') {
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
			}
		} else if stripped.starts_with('enum ') {
			name := first_word(stripped[5..])
			if name != '' {
				symbols << make_symbol(name, sym_kind_enum, i, raw_line)
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

fn (mut app App) search_symbol_in_project(working_dir string, symbol string) []Location {
	mut locations := []Location{}
	v_files := os.walk_ext(working_dir, '.v')

	for v_file in v_files {
		content := app.open_files[path_to_uri(v_file)] or { os.read_file(v_file) or { continue } }
		lines := content.split_into_lines()

		for line_idx, line_text in lines {
			mut col := 0
			for col < line_text.len {
				idx := line_text[col..].index(symbol) or { break }
				pos := col + idx

				// Check it's a whole word (not part of larger identifier)
				before_ok := pos == 0 || !is_ident_char(line_text[pos - 1])
				after_ok := pos + symbol.len >= line_text.len
					|| !is_ident_char(line_text[pos + symbol.len])

				if before_ok && after_ok {
					locations << Location{
						uri:   path_to_uri(v_file)
						range: LSPRange{
							start: Position{
								line: line_idx
								char: pos
							}
							end:   Position{
								line: line_idx
								char: pos + symbol.len
							}
						}
					}
				}
				col = pos + 1
			}
		}
	}
	return locations
}
