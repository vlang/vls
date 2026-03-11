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

// handle_inlay_hints returns type inlay hints for `:=` declarations within the
// requested range whose RHS is a recognizable literal (int, f64, string, bool).
fn (mut app App) handle_inlay_hints(request Request) Response {
	uri := request.params.text_document.uri
	content := app.open_files[uri] or { '' }
	lines := content.split_into_lines()

	start_line := request.params.range.start.line
	end_line := request.params.range.end.line

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
		vroot := find_vroot()
		if vroot != '' {
			imported_mods := parse_imports(content)
			for mod in imported_mods {
				mod_path := mod.replace('.', '/')
				vlib_mod_dir := os.join_path(vroot, 'vlib', mod_path)
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
	if r.starts_with('0x') || r.starts_with('0X') || r.starts_with('0o')
		|| r.starts_with('0b') {
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

// parse_imports extracts module names from `import` statements in V source content.
// Returns e.g. ['os', 'math', 'strings'] for a file with those imports.
fn parse_imports(content string) []string {
	mut modules := []string{}
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if !trimmed.starts_with('import ') {
			continue
		}
		mod := trimmed[7..].trim_space()
		// skip import blocks (`import (` style) - not supported in V, but be safe
		if mod == '(' || mod == '' {
			continue
		}
		// Handle aliased imports: `import os as operating_system` → take first word
		parts := mod.split(' ')
		modules << parts[0]
	}
	return modules
}

// find_vroot returns the V installation root directory (where vlib/ lives),
// or '' if the v binary cannot be found.
fn find_vroot() string {
	v_exe := os.find_abs_path_of_executable('v') or { return '' }
	root := os.dir(v_exe)
	vlib_candidate := os.join_path(root, 'vlib')
	if os.is_dir(vlib_candidate) {
		return root
	}
	// Some installations have v in a bin/ subdirectory
	parent := os.dir(root)
	vlib_parent := os.join_path(parent, 'vlib')
	if os.is_dir(vlib_parent) {
		return parent
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
