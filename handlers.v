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

struct IndexedCompletionResult {
	items          []Detail
	use_compiler   bool
	embedded_types []string
	resolved_type  bool
}

struct IndexedMethodSymbolResult {
	locations    []Location
	use_compiler bool
}

struct IndexedModuleCompletionResult {
	items        []Detail
	use_compiler bool
}

struct ParsedModuleCompletionIndex {
	items           []Detail
	has_conditional bool
}

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

	// Completion is served from the incremental source index. Starting a fresh V
	// compiler process here used to cost hundreds of milliseconds on every request,
	// even when the compiler returned no completion payload for an incomplete file.
	if method == .completion {
		indexed := app.indexed_completions(path, params.position)
		if indexed.use_compiler {
			compiler_result := app.run_v_line_info(.completion, path, '${line_nr}:${byte_col}')
			compiler_items := if compiler_result is []Detail {
				compiler_result as []Detail
			} else {
				[]Detail{}
			}
			items := merge_completion_items(indexed.items, compiler_items)
			return Response{
				id:     request.id
				result: CompletionList{
					is_incomplete: false
					items:         items
				}
			}
		}
		return Response{
			id:     request.id
			result: CompletionList{
				is_incomplete: false
				items:         indexed.items
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

	result := app.run_v_line_info(method, path, line_info)
	$if debug {
		log(result.str())
	}
	return Response{
		id:     request.id
		result: result
	}
}

fn merge_completion_items(indexed_items []Detail, compiler_items []Detail) []Detail {
	mut items := indexed_items.clone()
	mut seen_labels := map[string]bool{}
	for item in indexed_items {
		seen_labels[item.label] = true
	}
	for item in compiler_items {
		if item.label in seen_labels {
			continue
		}
		seen_labels[item.label] = true
		items << item
	}
	return items
}

// indexed_completions returns useful completions without compiling the project.
// The compiler-backed path rebuilt an unsaved project overlay and launched V for
// every request; on vlang/v that was roughly 400 ms even for a warm request.
fn (mut app App) indexed_completions(uri string, position Position) IndexedCompletionResult {
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	lines := content.split_into_lines()
	if position.line < 0 || position.line >= lines.len {
		return IndexedCompletionResult{}
	}
	line := lines[position.line]
	if is_import_completion_line(line) {
		return IndexedCompletionResult{
			items: get_import_completions(line, os.dir(uri_to_path(uri)))
		}
	}
	if position.char > 0 {
		qualifier, has_member_access, standalone_qualifier := member_qualifier_at_cursor(line,
			position.char, app.position_encoding)
		if has_member_access {
			if standalone_qualifier {
				if module_path := parse_import_aliases(content)[qualifier] {
					has_local_binding := app.local_scope_bindings(content, position).any(it.name == qualifier)
					if !has_local_binding {
						module_result := app.get_imported_module_member_completions(module_path,
							os.dir(uri_to_path(uri)))
						return IndexedCompletionResult{
							items:        module_result.items
							use_compiler: module_result.use_compiler
						}
					}
				}
			}
			receiver_result := app.indexed_receiver_completions(uri, content, qualifier,
				position.line)
			return receiver_result
		}
	}
	struct_type := struct_literal_type_at_cursor(content, position, app.position_encoding)
	if struct_type != '' {
		field_result := app.indexed_struct_field_completions(uri, content, struct_type)
		return IndexedCompletionResult{
			items:        field_result.items
			use_compiler: field_result.use_compiler || field_result.items.len == 0
		}
	}

	mut details := make_keyword_completions()
	mut seen_labels := map[string]bool{}
	for detail in details {
		seen_labels[detail.label] = true
	}
	for detail in app.local_scope_completions(content, position) {
		if detail.label !in seen_labels {
			details << detail
			seen_labels[detail.label] = true
		}
	}
	for binding in parse_import_bindings(content) {
		if binding.alias != '' && binding.alias !in seen_labels {
			details << Detail{
				kind:   9 // CompletionItemKind.Module
				label:  binding.alias
				detail: binding.module_path
			}
			seen_labels[binding.alias] = true
		}
	}
	working_dir := os.dir(uri_to_path(uri))
	mut use_compiler := false
	if working_dir != '' {
		module_result := app.collect_module_completions(uri, working_dir)
		use_compiler = module_result.use_compiler
		for detail in module_result.items {
			if detail.label !in seen_labels {
				details << detail
				seen_labels[detail.label] = true
			}
		}
	}
	return IndexedCompletionResult{
		items:        details
		use_compiler: use_compiler
	}
}

fn is_import_completion_line(line string) bool {
	trimmed := line.trim_space()
	return trimmed.starts_with('import')
		&& (trimmed.len == 6 || !is_ident_char(trimmed[6]))
}

fn starts_binding_scope_header(source string) bool {
	trimmed := source.trim_space()
	return trimmed.starts_with('for ') || trimmed.starts_with('if ')
		|| trimmed.starts_with('else if ')
}

struct AnonymousFunctionHeader {
	found           bool
	complete        bool
	parameter_names []string
}

fn last_fn_keyword_index(source string) int {
	if source.len < 2 {
		return -1
	}
	mut index := source.len - 2
	for index >= 0 {
		if source[index] == `f` && source[index + 1] == `n`
			&& (index == 0 || !is_ident_char(source[index - 1]))
			&& (index + 2 == source.len || !is_ident_char(source[index + 2])) {
			return index
		}
		index--
	}
	return -1
}

fn anonymous_function_header(source string) AnonymousFunctionHeader {
	fn_index := last_fn_keyword_index(source)
	if fn_index < 0 {
		return AnonymousFunctionHeader{}
	}
	mut rest := source[fn_index + 2..].trim_space()
	if rest == '' {
		return AnonymousFunctionHeader{
			found: true
		}
	}
	if rest.starts_with('[') {
		capture_end := matching_delimiter(rest, 0, `[`, `]`)
		if capture_end < 0 {
			return AnonymousFunctionHeader{
				found: true
			}
		}
		rest = rest[capture_end + 1..].trim_space()
	}
	if !rest.starts_with('(') {
		return AnonymousFunctionHeader{}
	}
	params_end := matching_delimiter(rest, 0, `(`, `)`)
	if params_end < 0 {
		return AnonymousFunctionHeader{
			found: true
		}
	}
	mut names := []string{}
	for parameter in split_top_level_commas(rest[1..params_end]) {
		for field in parameter.fields() {
			if field !in ['mut', 'shared', 'atomic', '_'] {
				if field !in names {
					names << field
				}
				break
			}
		}
	}
	return AnonymousFunctionHeader{
		found:           true
		complete:        true
		parameter_names: names
	}
}

fn struct_literal_cursor_is_at_field(prefix string, open_brace int) bool {
	mut round_depth := 0
	mut square_depth := 0
	mut curly_depth := 0
	mut in_value := false
	for c in prefix[open_brace + 1..] {
		match c {
			`(` { round_depth++ }
			`)` { round_depth-- }
			`[` { square_depth++ }
			`]` { square_depth-- }
			`{` { curly_depth++ }
			`}` { curly_depth-- }
			`:` {
				if round_depth == 0 && square_depth == 0 && curly_depth == 0 {
					in_value = true
				}
			}
			`,` {
				if round_depth == 0 && square_depth == 0 && curly_depth == 0 {
					in_value = false
				}
			}
			`\n` {
				if round_depth == 0 && square_depth == 0 && curly_depth == 0 {
					in_value = false
				}
			}
			else {}
		}
	}
	return !in_value
}

fn struct_literal_type_at_cursor(content string, position Position, enc PositionEncoding) string {
	lines := content.split_into_lines()
	if position.line < 0 || position.line >= lines.len || position.char < 0 {
		return ''
	}
	mut code_lines := []string{cap: position.line + 1}
	mut scan_state := ImportScanState{}
	for line_idx in 0 .. position.line + 1 {
		raw_line := lines[line_idx]
		fragment := if line_idx == position.line {
			byte_col := encoded_col_to_byte(raw_line, position.char, enc)
			raw_line[..byte_col]
		} else {
			raw_line
		}
		code_lines << source_line_import_code(fragment, mut scan_state)
	}
	prefix := code_lines.join('\n')
	mut brace_depth := 0
	mut open_brace := -1
	mut col := prefix.len - 1
	for col >= 0 {
		if prefix[col] == `}` {
			brace_depth++
		} else if prefix[col] == `{` {
			if brace_depth == 0 {
				open_brace = col
				break
			}
			brace_depth--
		}
		col--
	}
	if open_brace < 0 {
		return ''
	}
	if !struct_literal_cursor_is_at_field(prefix, open_brace) {
		return ''
	}
	fn_index := last_fn_keyword_index(prefix[..open_brace])
	if fn_index >= 0 {
		function_header := prefix[fn_index..open_brace]
		if !function_header.contains('{') && !function_header.contains('}') {
			return ''
		}
	}
	mut type_end := open_brace
	for type_end > 0 && prefix[type_end - 1] in [` `, `\t`, `\r`, `\n`] {
		type_end--
	}
	mut type_start := type_end
	mut square_depth := 0
	for type_start > 0 {
		c := prefix[type_start - 1]
		if c == `]` {
			square_depth++
			type_start--
			continue
		}
		if square_depth > 0 {
			if c == `[` {
				square_depth--
			}
			type_start--
			continue
		}
		if is_ident_char(c) || c == `.` {
			type_start--
			continue
		}
		break
	}
	if type_start == type_end || square_depth != 0 {
		return ''
	}
	type_name := prefix[type_start..type_end].trim_space()
	simple_name := normalize_receiver_type(type_name).all_after_last('.')
	if simple_name == '' || !(simple_name[0] >= `A` && simple_name[0] <= `Z`) {
		return ''
	}
	mut keyword_end := type_start
	for keyword_end > 0 && prefix[keyword_end - 1] in [` `, `\t`, `\r`, `\n`] {
		keyword_end--
	}
	mut keyword_start := keyword_end
	for keyword_start > 0 && is_ident_char(prefix[keyword_start - 1]) {
		keyword_start--
	}
	if prefix[keyword_start..keyword_end] in ['enum', 'for', 'if', 'interface', 'match',
		'struct', 'union'] {
		return ''
	}
	return type_name
}

fn member_qualifier_at_cursor(line string, cursor_col int, enc PositionEncoding) (string, bool, bool) {
	if line == '' || cursor_col <= 0 {
		return '', false, false
	}
	cursor_byte := encoded_col_to_byte(line, cursor_col, enc)
	mut member_start := cursor_byte
	for member_start > 0 && is_ident_char(line[member_start - 1]) {
		member_start--
	}
	if member_start == 0 || line[member_start - 1] != `.` {
		return '', false, false
	}
	dot_byte := member_start - 1
	dot_col := byte_to_encoded_col(line, dot_byte, enc)
	qualifier := get_word_before_dot(line, dot_col, enc)
	mut qualifier_start := dot_byte - qualifier.len
	if qualifier_start < 0 {
		qualifier_start = 0
	}
	return qualifier, true, qualifier_start == 0 || line[qualifier_start - 1] != `.`
}

fn binding_identifiers(text string) []string {
	mut names := []string{}
	mut col := 0
	ignored := ['_', 'atomic', 'else', 'for', 'if', 'lock', 'match', 'mut', 'rlock',
		'select', 'shared']
	for col < text.len {
		if !is_ident_char(text[col]) || (text[col] >= `0` && text[col] <= `9`) {
			col++
			continue
		}
		start := col
		col++
		for col < text.len && is_ident_char(text[col]) {
			col++
		}
		name := text[start..col]
		if name !in ignored && name !in names {
			names << name
		}
	}
	return names
}

fn matching_delimiter(text string, open_idx int, open u8, close u8) int {
	if open_idx < 0 || open_idx >= text.len || text[open_idx] != open {
		return -1
	}
	mut depth := 0
	for idx in open_idx .. text.len {
		if text[idx] == open {
			depth++
		} else if text[idx] == close {
			depth--
			if depth == 0 {
				return idx
			}
		}
	}
	return -1
}

fn split_top_level_commas(text string) []string {
	mut parts := []string{}
	mut start := 0
	mut round_depth := 0
	mut square_depth := 0
	mut curly_depth := 0
	for idx, c in text {
		match c {
			`(` { round_depth++ }
			`)` { round_depth-- }
			`[` { square_depth++ }
			`]` { square_depth-- }
			`{` { curly_depth++ }
			`}` { curly_depth-- }
			`,` {
				if round_depth == 0 && square_depth == 0 && curly_depth == 0 {
					parts << text[start..idx]
					start = idx + 1
				}
			}
			else {}
		}
	}
	parts << text[start..]
	return parts
}

fn function_parameter_names(header string) []string {
	fn_idx := header.index('fn ') or { return []string{} }
	mut rest := header[fn_idx + 3..].trim_space()
	mut names := []string{}
	if rest.starts_with('(') {
		receiver_end := matching_delimiter(rest, 0, `(`, `)`)
		if receiver_end < 0 {
			return names
		}
		receiver_fields := rest[1..receiver_end].fields()
		for field in receiver_fields {
			if field !in ['mut', 'shared', 'atomic', '_'] {
				names << field
				break
			}
		}
		rest = rest[receiver_end + 1..].trim_space()
	}
	params_start := rest.index('(') or { return names }
	params_end := matching_delimiter(rest, params_start, `(`, `)`)
	if params_end < 0 {
		return names
	}
	for parameter in split_top_level_commas(rest[params_start + 1..params_end]) {
		fields := parameter.fields()
		for field in fields {
			if field !in ['mut', 'shared', 'atomic', '_'] {
				if field !in names {
					names << field
				}
				break
			}
		}
	}
	return names
}

fn containing_function_start(lines []string, position Position, enc PositionEncoding) int {
	mut scan_state := ImportScanState{}
	mut brace_depth := 0
	mut pending_start := -1
	mut function_start := -1
	for line_idx, raw_line in lines {
		if line_idx > position.line {
			break
		}
		line := if line_idx == position.line {
			byte_col := encoded_col_to_byte(raw_line, position.char, enc)
			raw_line[..byte_col]
		} else {
			raw_line
		}
		code := source_line_import_code(line, mut scan_state)
		trimmed := code.trim_space()
		declaration := if trimmed.starts_with('pub fn ') {
			trimmed[4..]
		} else {
			trimmed
		}
		if brace_depth == 0 && declaration.starts_with('fn ') {
			pending_start = line_idx
		}
		for c in code {
			if c == `{` {
				if brace_depth == 0 && pending_start >= 0 {
					function_start = pending_start
				}
				brace_depth++
			} else if c == `}` && brace_depth > 0 {
				brace_depth--
				if brace_depth == 0 {
					function_start = -1
					pending_start = -1
				}
			}
		}
	}
	if function_start >= 0 {
		return function_start
	}
	return pending_start
}

fn local_declaration_names(code string) []string {
	mut names := []string{}
	for raw_statement in code.split(';') {
		statement := raw_statement.trim_space()
		if assign_idx := statement.index(':=') {
			assignment_prefix := statement[..assign_idx]
			lhs := if brace_idx := assignment_prefix.last_index('{') {
				assignment_prefix[brace_idx + 1..]
			} else {
				assignment_prefix
			}
			for name in binding_identifiers(lhs) {
				if name !in names {
					names << name
				}
			}
		} else if statement.starts_with('for ') {
			mut in_idx := statement.index(' in ') or { -1 }
			if in_idx < 0 && statement.ends_with(' in') {
				in_idx = statement.len - 3
			}
			if in_idx >= 0 {
				for name in binding_identifiers(statement[4..in_idx]) {
					if name !in names {
						names << name
					}
				}
			}
		}
	}
	return names
}

fn starts_or_block_header(source string) bool {
	trimmed := source.trim_space()
	return trimmed == 'or' || trimmed.ends_with(' or')
}

fn opens_implicit_it_scope(source string, open_paren int) bool {
	mut name_end := open_paren
	for name_end > 0 && source[name_end - 1] in [` `, `\t`, `\r`, `\n`] {
		name_end--
	}
	mut name_start := name_end
	for name_start > 0 && is_ident_char(source[name_start - 1]) {
		name_start--
	}
	if name_start == name_end || name_start == 0 || source[name_start - 1] != `.` {
		return false
	}
	return source[name_start..name_end] in ['all', 'any', 'filter', 'map']
}

fn has_implicit_it_scope_at_cursor(source string) bool {
	mut scopes := []bool{}
	for index, c in source {
		if c == `(` {
			scopes << opens_implicit_it_scope(source, index)
		} else if c == `)` && scopes.len > 0 {
			scopes.delete_last()
		}
	}
	return scopes.any(it)
}

struct LocalBinding {
	name string
	line int
}

fn (app &App) local_scope_bindings(content string, position Position) []LocalBinding {
	lines := content.split_into_lines()
	if position.line < 0 || position.line >= lines.len {
		return []LocalBinding{}
	}
	function_start := containing_function_start(lines, position, app.position_encoding)
	if function_start < 0 {
		return []LocalBinding{}
	}
	mut header_lines := []string{}
	for line_idx in function_start .. position.line + 1 {
		line := if line_idx == position.line {
			byte_col := encoded_col_to_byte(lines[line_idx], position.char, app.position_encoding)
			lines[line_idx][..byte_col]
		} else {
			lines[line_idx]
		}
		header_lines << line
		if line.contains('{') {
			break
		}
	}
	parameter_names := function_parameter_names(header_lines.join('\n').all_before('{'))
	mut parameter_bindings := []LocalBinding{}
	for name in parameter_names {
		parameter_bindings << LocalBinding{
			name: name
			line: function_start
		}
	}
	mut scopes := [][]LocalBinding{}
	scopes << parameter_bindings
	mut scan_state := ImportScanState{}
	mut body_started := false
	mut pending_block_names := []string{}
	mut pending_block_line := -1
	mut pending_closure_header := ''
	mut pending_closure_line := -1
	mut active_code_lines := []string{}
	for line_idx in 0 .. position.line + 1 {
		raw_line := if line_idx == position.line {
			byte_col := encoded_col_to_byte(lines[line_idx], position.char, app.position_encoding)
			lines[line_idx][..byte_col]
		} else {
			lines[line_idx]
		}
		code := source_line_import_code(raw_line, mut scan_state)
		if line_idx < function_start {
			continue
		}
		active_code_lines << code
		mut segment_start := 0
		for col, c in code {
			if c != `{` && c != `}` {
				continue
			}
			segment := code[segment_start..col]
			segment_names := local_declaration_names(segment)
			binding_scope_header := c == `{` && starts_binding_scope_header(segment)
			error_scope_header := c == `{` && starts_or_block_header(segment)
			closure_source := if pending_closure_header != '' {
				pending_closure_header + '\n' + segment
			} else {
				segment
			}
			closure_header := anonymous_function_header(closure_source)
			block_names := if closure_header.complete {
				closure_header.parameter_names
			} else if binding_scope_header {
				segment_names
			} else if error_scope_header {
				['err']
			} else {
				pending_block_names
			}
			block_line := if closure_header.complete {
				if pending_closure_line >= 0 { pending_closure_line } else { line_idx }
			} else if binding_scope_header {
				line_idx
			} else if error_scope_header {
				line_idx
			} else {
				pending_block_line
			}
			if body_started && scopes.len > 0 {
				outer_segment_names := if binding_scope_header { []string{} } else { segment_names }
				for name in outer_segment_names {
					if !scopes.last().any(it.name == name) {
						scopes[scopes.len - 1] << LocalBinding{
							name: name
							line: line_idx
						}
					}
				}
			}
			if c == `{` {
				if body_started {
					scopes << []LocalBinding{}
					if block_names.len > 0 {
						for name in block_names {
							if !scopes.last().any(it.name == name) {
								scopes[scopes.len - 1] << LocalBinding{
									name: name
									line: block_line
								}
							}
						}
					}
				} else {
					body_started = true
				}
				pending_block_names = []string{}
				pending_block_line = -1
				pending_closure_header = ''
				pending_closure_line = -1
			} else if body_started && scopes.len > 1 {
				scopes.delete_last()
			}
			segment_start = col + 1
		}
		if body_started && scopes.len > 0 {
			tail := code[segment_start..]
			tail_names := local_declaration_names(tail)
			if starts_binding_scope_header(tail) && tail_names.len > 0 {
				pending_block_names = tail_names.clone()
				pending_block_line = line_idx
			} else {
				closure_source := if pending_closure_header != '' {
					pending_closure_header + '\n' + tail
				} else {
					tail
				}
				closure_header := anonymous_function_header(closure_source)
				for name in tail_names {
					if !scopes.last().any(it.name == name) {
						scopes[scopes.len - 1] << LocalBinding{
							name: name
							line: line_idx
						}
					}
				}
				if starts_or_block_header(tail) {
					pending_block_names = ['err']
					pending_block_line = line_idx
				} else if closure_header.found {
					if pending_closure_line < 0 {
						pending_closure_line = line_idx
					}
					if closure_header.complete {
						pending_block_names = closure_header.parameter_names.clone()
						pending_block_line = pending_closure_line
						pending_closure_header = ''
					} else {
						pending_closure_header = closure_source
					}
				}
			}
		}
	}
	mut has_explicit_it := false
	for scope in scopes {
		if scope.any(it.name == 'it') {
			has_explicit_it = true
			break
		}
	}
	if has_implicit_it_scope_at_cursor(active_code_lines.join('\n')) && scopes.len > 0
		&& !has_explicit_it {
		scopes[scopes.len - 1] << LocalBinding{
			name: 'it'
			line: position.line
		}
	}
	mut bindings := []LocalBinding{}
	for scope in scopes {
		for binding in scope {
			bindings << binding
		}
	}
	return bindings
}

fn (app &App) local_scope_completions(content string, position Position) []Detail {
	mut names := []string{}
	for binding in app.local_scope_bindings(content, position) {
		if binding.name != '' && binding.name !in names {
			names << binding.name
		}
	}
	return names.filter(it != '').map(Detail{
		kind:   6 // CompletionItemKind.Variable
		label:  it
		detail: 'local binding'
	})
}

fn identifier_index(text string, name string) int {
	if name == '' || text.len < name.len {
		return -1
	}
	mut start := 0
	for start + name.len <= text.len {
		rel := text[start..].index(name) or { return -1 }
		idx := start + rel
		before_ok := idx == 0 || !is_ident_char(text[idx - 1])
		after := idx + name.len
		after_ok := after == text.len || !is_ident_char(text[after])
		if before_ok && after_ok {
			return idx
		}
		start = idx + name.len
	}
	return -1
}

fn type_after_identifier(text string, name string) string {
	mut search_start := 0
	for search_start < text.len {
		rel := identifier_index(text[search_start..], name)
		if rel < 0 {
			return ''
		}
		mut col := search_start + rel + name.len
		for col < text.len && text[col] in [` `, `\t`, `\r`, `\n`] {
			col++
		}
		if col + 1 < text.len && text[col] == `:` && text[col + 1] == `=` {
			search_start = col + 2
			continue
		}
		start := col
		for col < text.len && (is_ident_char(text[col])
			|| text[col] in [`&`, `?`, `!`, `.`, `[`, `]`]) {
			col++
		}
		if col > start {
			return text[start..col]
		}
		search_start = col + 1
	}
	return ''
}

fn callable_or_constructor(rhs string) (string, bool) {
	mut col := 0
	for col < rhs.len {
		if !is_ident_char(rhs[col]) {
			col++
			continue
		}
		start := col
		col++
		for col < rhs.len && (is_ident_char(rhs[col]) || rhs[col] == `.`) {
			col++
		}
		name := rhs[start..col]
		for col < rhs.len && rhs[col] in [` `, `\t`, `\r`, `\n`] {
			col++
		}
		if col >= rhs.len || rhs[col] !in [`(`, `{`] {
			continue
		}
		if name in ['unsafe', 'lock', 'rlock', 'shared', 'if', 'match'] {
			col++
			continue
		}
		is_constructor := rhs[col] == `{`
		if is_constructor {
			prefix := rhs[..start].trim_space()
			if prefix !in ['', '&'] {
				return '', false
			}
			type_name := name.all_after_last('.')
			if type_name == '' || !(type_name[0] >= `A` && type_name[0] <= `Z`) {
				col++
				continue
			}
		}
		return name, is_constructor
	}
	return '', false
}

fn source_fragment_starts_with_literal(source string) bool {
	trimmed := source.trim_space()
	if trimmed == '' {
		return false
	}
	if trimmed[0] in [`'`, `"`, 96] {
		return true
	}
	return trimmed.len > 1 && trimmed[0] == `r` && trimmed[1] in [`'`, `"`]
}

fn receiver_rhs_has_open_delimiter(rhs string) bool {
	mut round_depth := 0
	mut square_depth := 0
	mut curly_depth := 0
	for c in rhs {
		match c {
			`(` { round_depth++ }
			`)` { round_depth-- }
			`[` { square_depth++ }
			`]` { square_depth-- }
			`{` { curly_depth++ }
			`}` { curly_depth-- }
			else {}
		}
	}
	return round_depth > 0 || square_depth > 0 || curly_depth > 0
}

fn receiver_rhs_needs_continuation(rhs string, has_expression bool, scan_state &ImportScanState) bool {
	if scan_state.quote != 0 || receiver_rhs_has_open_delimiter(rhs) {
		return true
	}
	if !has_expression {
		return true
	}
	trimmed := rhs.trim_space()
	if trimmed == '' {
		return false
	}
	return trimmed[trimmed.len - 1] in [`.`, `,`, `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`,
		`=`, `!`, `<`, `>`, `?`, `:`]
}

struct ReceiverDeclaration {
	rhs            string
	binding_index  int
	binding_count  int
	assignment_end int
}

fn receiver_declaration_on_line(code string, receiver string) ?ReceiverDeclaration {
	mut statement_start := 0
	for raw_statement in code.split(';') {
		assign_idx := raw_statement.index(':=') or {
			statement_start += raw_statement.len + 1
			continue
		}
		assignment_prefix := raw_statement[..assign_idx]
		lhs := if brace_idx := assignment_prefix.last_index('{') {
			assignment_prefix[brace_idx + 1..]
		} else {
			assignment_prefix
		}
		bindings := binding_identifiers(lhs)
		binding_index := bindings.index(receiver)
		if binding_index < 0 {
			statement_start += raw_statement.len + 1
			continue
		}
		return ReceiverDeclaration{
			rhs:            raw_statement[assign_idx + 2..].trim_space()
			binding_index:  binding_index
			binding_count:  bindings.len
			assignment_end: statement_start + assign_idx + 2
		}
	}
	return none
}

fn normalize_receiver_type(source_type string) string {
	mut result := source_type.trim_space()
	for result.len > 0 && result[0] in [`&`, `?`, `!`] {
		result = result[1..].trim_space()
	}
	if generic_start := result.index('[') {
		result = result[..generic_start]
	}
	return result
}

fn (mut app App) function_return_type(uri string, content string, candidate string) string {
	mut fn_index := map[string]string{}
	parse_fn_signatures_into(content, '', mut fn_index)
	if return_type := fn_index[candidate] {
		return normalize_receiver_type(return_type)
	}
	if !candidate.contains('.') {
		return ''
	}
	qualifier := candidate.all_before_last('.')
	fn_name := candidate.all_after_last('.')
	module_path := parse_import_aliases(content)[qualifier] or { return '' }
	dir := app.resolve_indexed_import_module_dir(module_path, os.dir(uri_to_path(uri)))
	if dir == '' || !os.is_dir(dir) {
		return ''
	}
	app.ensure_dir_shallow_indexed(dir)
	normalized_dir := normalized_index_path(dir)
	for open_uri, _ in app.open_files {
		if normalized_index_path(os.dir(uri_to_path(open_uri))) == normalized_dir {
			app.reindex_uri(open_uri)
		}
	}
	expected_module := module_path.all_after_last('.')
	mut return_types := map[string]bool{}
	for indexed_uri, entry in app.symbol_index {
		if normalized_index_path(os.dir(uri_to_path(indexed_uri))) != normalized_dir
			|| entry.module_name != expected_module {
			continue
		}
		for symbol in entry.doc_symbols {
			if symbol.kind != sym_kind_function || extract_simple_fn_name(symbol.name) != fn_name
				|| !source_declaration_is_public(indexed_uri, symbol, app) {
				continue
			}
			source := app.index_source_for(indexed_uri) or { continue }
			mut source_index := map[string]string{}
			parse_fn_signatures_into(source, '', mut source_index)
			if return_type := source_index[fn_name] {
				return_types[normalize_receiver_type(return_type)] = true
			}
		}
	}
	if return_types.len != 1 {
		return ''
	}
	return_type := return_types.keys()[0]
	if return_type.contains('.') || return_type == ''
		|| !(return_type[0] >= `A` && return_type[0] <= `Z`) {
		return return_type
	}
	return '${qualifier}.${return_type}'
}

fn (mut app App) infer_receiver_type(uri string, content string, receiver string, use_line int) string {
	if receiver == '' {
		return ''
	}
	lines := content.split_into_lines()
	if use_line < 0 || use_line >= lines.len {
		return ''
	}
	use_position := Position{
		line: use_line
		char: byte_to_encoded_col(lines[use_line], lines[use_line].len, app.position_encoding)
	}
	mut active_declaration_lines := map[int]bool{}
	for binding in app.local_scope_bindings(content, use_position) {
		if binding.name == receiver {
			active_declaration_lines[binding.line] = true
		}
	}
	if active_declaration_lines.len == 0 {
		return ''
	}
	mut header_start := -1
	mut scan_state := ImportScanState{}
	mut latest_rhs := ''
	mut latest_raw_rhs := ''
	mut latest_declaration_line := -1
	mut latest_binding_index := 0
	mut latest_binding_count := 1
	for i, raw_line in lines {
		if i > use_line {
			break
		}
		code := source_line_import_code(raw_line, mut scan_state)
		trimmed := code.trim_space()
		declaration := if trimmed.starts_with('pub fn ') {
			trimmed[4..]
		} else {
			trimmed
		}
		if declaration.starts_with('fn ') {
			header_start = i
			latest_rhs = ''
			latest_raw_rhs = ''
			latest_declaration_line = -1
			latest_binding_index = 0
			latest_binding_count = 1
		}
		if receiver_declaration := receiver_declaration_on_line(code, receiver) {
			if !active_declaration_lines[i] {
				continue
			}
			latest_rhs = receiver_declaration.rhs
			latest_raw_rhs = if receiver_declaration.assignment_end <= raw_line.len {
				raw_line[receiver_declaration.assignment_end..]
			} else {
				''
			}
			latest_declaration_line = i
			latest_binding_index = receiver_declaration.binding_index
			latest_binding_count = receiver_declaration.binding_count
		}
	}

	if latest_declaration_line >= 0 {
		mut rhs_scan_state := ImportScanState{}
		source_line_import_code(latest_raw_rhs, mut rhs_scan_state)
		mut rhs_has_expression := latest_rhs.trim_space() != ''
			|| source_fragment_starts_with_literal(latest_raw_rhs)
		mut next_line := latest_declaration_line + 1
		for next_line <= use_line && next_line < lines.len
			&& receiver_rhs_needs_continuation(latest_rhs, rhs_has_expression, &rhs_scan_state) {
			next_code := source_line_import_code(lines[next_line], mut rhs_scan_state)
			if !receiver_rhs_has_open_delimiter(latest_rhs)
				&& local_declaration_names(next_code).len > 0 {
				break
			}
			latest_rhs += '\n' + next_code
			rhs_has_expression = rhs_has_expression || next_code.trim_space() != ''
				|| source_fragment_starts_with_literal(lines[next_line])
			next_line++
		}
		mut receiver_rhs := latest_rhs
		if latest_binding_count > 1 {
			rhs_values := split_top_level_commas(latest_rhs)
			if rhs_values.len != latest_binding_count || latest_binding_index >= rhs_values.len {
				return ''
			}
			receiver_rhs = rhs_values[latest_binding_index]
		}
		candidate, is_constructor := callable_or_constructor(receiver_rhs)
		if candidate != '' {
			if is_constructor {
				return normalize_receiver_type(candidate)
			}
			return_type := app.function_return_type(uri, content, candidate)
			if return_type != '' {
				return return_type
			}
		}
	}

	if header_start >= 0 {
		mut end_line := header_start + 12
		if end_line > use_line + 1 {
			end_line = use_line + 1
		}
		if end_line > lines.len {
			end_line = lines.len
		}
		header := lines[header_start..end_line].join('\n').all_before('{')
		return normalize_receiver_type(type_after_identifier(header, receiver))
	}
	return ''
}

fn method_receiver_type(method_name string) string {
	if !method_name.starts_with('(') {
		return ''
	}
	close_idx := method_name.index(')') or { return '' }
	fields := method_name[1..close_idx].fields()
	if fields.len < 2 {
		return ''
	}
	return normalize_receiver_type(fields.last())
}

fn complete_function_signature(lines []string, start_line int, initial string) string {
	if start_line < 0 || start_line >= lines.len {
		return initial
	}
	mut signature := ''
	mut parenthesis_depth := 0
	mut found_parameters := false
	for line_idx in start_line .. lines.len {
		segment := if line_idx == start_line { initial.trim_space() } else { lines[line_idx].trim_space() }
		if signature != '' && segment != '' {
			signature += ' '
		}
		signature += segment
		code_segment := segment.all_before('//')
		for c in code_segment {
			if c == `(` {
				parenthesis_depth++
				found_parameters = true
			} else if c == `)` && parenthesis_depth > 0 {
				parenthesis_depth--
			}
		}
		if found_parameters && parenthesis_depth == 0 {
			break
		}
	}
	return signature
}

fn method_completion_from_symbol(source string, symbol DocumentSymbol) ?Detail {
	lines := source.split_into_lines()
	line_idx := symbol.range.start.line
	if line_idx < 0 || line_idx >= lines.len {
		return none
	}
	trimmed := lines[line_idx].trim_space()
	initial_after_fn := if trimmed.starts_with('pub fn ') {
		trimmed[7..]
	} else if trimmed.starts_with('fn ') {
		trimmed[3..]
	} else {
		return none
	}
	after_fn := complete_function_signature(lines, line_idx, initial_after_fn)
	close_receiver := after_fn.index(')') or { return none }
	after_receiver := after_fn[close_receiver + 1..].trim_space()
	paren_idx := after_receiver.index('(') or { return none }
	name := after_receiver[..paren_idx].trim_space()
	if name == '' {
		return none
	}
	insert := build_fn_snippet(name, after_receiver[paren_idx..])
	return Detail{
		kind:               2
		label:              name
		detail:             '${if trimmed.starts_with('pub ') { 'pub ' } else { '' }}fn ${after_fn}'.all_before('{').trim_space()
		insert_text:        insert
		insert_text_format: if insert.contains('$') { 2 } else { 1 }
	}
}

fn (mut app App) receiver_type_scope(uri string, content string, receiver_type string) (string, string, bool, string) {
	normalized_type := normalize_receiver_type(receiver_type)
	if normalized_type == '' {
		return '', '', false, ''
	}
	if normalized_type.contains('.') {
		qualifier := normalized_type.all_before_last('.')
		type_name := normalized_type.all_after_last('.')
		module_path := parse_import_aliases(content)[qualifier] or { return '', '', false, '' }
		dir := app.resolve_indexed_import_module_dir(module_path, os.dir(uri_to_path(uri)))
		return dir, type_name, true, module_path.all_after_last('.')
	}
	return os.dir(uri_to_path(uri)), normalized_type, false, get_module_name(content)
}

fn (mut app App) indexed_method_symbols(uri string, content string, receiver_type string, method_name string) IndexedMethodSymbolResult {
	dir, type_name, require_public, expected_module := app.receiver_type_scope(uri, content,
		receiver_type)
	if dir == '' || type_name == '' || expected_module == '' || !os.is_dir(dir) {
		return IndexedMethodSymbolResult{}
	}
	app.ensure_dir_shallow_indexed(dir)
	normalized_dir := normalized_index_path(dir)
	for open_uri, _ in app.open_files {
		if normalized_index_path(os.dir(uri_to_path(open_uri))) == normalized_dir {
			app.reindex_uri(open_uri)
		}
	}
	requesting_path := uri_to_path(uri)
	active_test_name := if !require_public && requesting_path.ends_with('_test.v') {
		os.file_name(requesting_path)
	} else {
		''
	}
	active_names := app.active_indexed_source_file_names(dir, active_test_name)
	mut matches := []Location{}
	mut has_conditional := false
	mut indexed_uris := app.symbol_index.keys()
	indexed_uris.sort()
	for indexed_uri in indexed_uris {
		entry := app.symbol_index[indexed_uri] or { continue }
		if normalized_index_path(os.dir(uri_to_path(indexed_uri))) != normalized_dir
			|| os.file_name(uri_to_path(indexed_uri)) !in active_names
			|| entry.module_name != expected_module {
			continue
		}
		source := app.index_source_for(indexed_uri) or { continue }
		for symbol in entry.doc_symbols {
			if symbol.kind != sym_kind_method || method_receiver_type(symbol.name) != type_name {
				continue
			}
			simple_name := extract_simple_fn_name(symbol.name)
			if method_name != '' && simple_name != method_name {
				continue
			}
			declaration_occurrences := app.occurrences_for(indexed_uri)[simple_name] or {
				continue
			}
			if !source_declaration_occurrence_is_code(symbol, declaration_occurrences) {
				continue
			}
			if require_public && !source_declaration_is_public(indexed_uri, symbol, app) {
				continue
			}
			if source_declaration_is_compile_time_conditional(source, symbol.range.start.line) {
				has_conditional = true
				continue
			}
			matches << Location{
				uri:   indexed_uri
				range: LSPRange{
					start: Position{
						line: symbol.range.start.line
						char: symbol.selection_range.start.char
					}
					end:   Position{
						line: symbol.range.start.line
						char: symbol.selection_range.end.char
					}
				}
			}
		}
	}
	return IndexedMethodSymbolResult{
		locations:    matches
		use_compiler: has_conditional
	}
}

fn struct_field_is_public(lines []string, struct_symbol DocumentSymbol, field_symbol DocumentSymbol) bool {
	start_line := struct_symbol.range.start.line + 1
	end_line := field_symbol.range.start.line
	if start_line < 0 || end_line < start_line || end_line >= lines.len {
		return false
	}
	mut is_public := false
	for line_idx in start_line .. end_line + 1 {
		access_label := lines[line_idx].trim_space()
		if access_label == 'pub:' || access_label == 'pub mut:' {
			is_public = true
		} else if access_label in ['mut:', 'private:', '__global:'] {
			is_public = false
		}
	}
	return is_public
}

fn field_completion_from_symbol(lines []string, code_lines []string, symbol DocumentSymbol) ?Detail {
	line_idx := symbol.range.start.line
	if line_idx < 0 || line_idx >= lines.len || line_idx >= code_lines.len {
		return none
	}
	if !is_valid_v_identifier_name(symbol.name) {
		return none
	}
	code := code_lines[line_idx].trim_space()
	if code.starts_with('@[') || first_word(code) != symbol.name {
		return none
	}
	return Detail{
		kind:   5 // CompletionItemKind.Field
		label:  symbol.name
		detail: lines[line_idx].trim_space()
	}
}

fn embedded_struct_type(code_line string) string {
	fields := code_line.trim_space().fields()
	if fields.len == 0 || (fields.len > 1 && !fields[1].starts_with('@[')) {
		return ''
	}
	type_name := normalize_receiver_type(fields[0]).all_after_last('.')
	if type_name == '' || !(type_name[0] >= `A` && type_name[0] <= `Z`) {
		return ''
	}
	return fields[0]
}

fn qualify_embedded_receiver_type(receiver_type string, embedded_type string) string {
	embedded := normalize_receiver_type(embedded_type)
	if embedded.contains('.') {
		return embedded
	}
	parent := normalize_receiver_type(receiver_type)
	if parent.contains('.') {
		return '${parent.all_before_last('.')}.${embedded}'
	}
	return embedded
}

fn (mut app App) indexed_struct_field_completions(uri string, content string, receiver_type string) IndexedCompletionResult {
	mut visited := map[string]bool{}
	return app.indexed_struct_field_completions_visited(uri, content, receiver_type, mut visited)
}

fn (mut app App) indexed_struct_field_completions_visited(uri string, content string, receiver_type string, mut visited map[string]bool) IndexedCompletionResult {
	dir, type_name, require_public, expected_module := app.receiver_type_scope(uri, content,
		receiver_type)
	if dir == '' || type_name == '' || expected_module == '' || !os.is_dir(dir) {
		return IndexedCompletionResult{}
	}
	app.ensure_dir_shallow_indexed(dir)
	normalized_dir := normalized_index_path(dir)
	visited_key := '${normalized_dir}|${expected_module}|${type_name}'
	if visited_key in visited {
		return IndexedCompletionResult{
			resolved_type: true
		}
	}
	visited[visited_key] = true
	for open_uri, _ in app.open_files {
		if normalized_index_path(os.dir(uri_to_path(open_uri))) == normalized_dir {
			app.reindex_uri(open_uri)
		}
	}
	requesting_path := uri_to_path(uri)
	active_test_name := if !require_public && requesting_path.ends_with('_test.v') {
		os.file_name(requesting_path)
	} else {
		''
	}
	active_names := app.active_indexed_source_file_names(dir, active_test_name)
	mut items := []Detail{}
	mut seen_items := map[string]bool{}
	mut embedded_types := []string{}
	mut has_conditional := false
	mut has_unresolved_embedded := false
	mut resolved_type := false
	mut indexed_uris := app.symbol_index.keys()
	indexed_uris.sort()
	for indexed_uri in indexed_uris {
		entry := app.symbol_index[indexed_uri] or { continue }
		if normalized_index_path(os.dir(uri_to_path(indexed_uri))) != normalized_dir
			|| os.file_name(uri_to_path(indexed_uri)) !in active_names
			|| entry.module_name != expected_module {
			continue
		}
		source := app.index_source_for(indexed_uri) or { continue }
		source_lines := source.split_into_lines()
		code_lines := source_code_lines(source)
		for symbol in entry.doc_symbols {
			if symbol.kind != sym_kind_struct || normalize_receiver_type(symbol.name) != type_name {
				continue
			}
			if source_declaration_is_compile_time_conditional(source, symbol.range.start.line) {
				has_conditional = true
				continue
			}
			if require_public && !source_declaration_is_public(indexed_uri, symbol, app) {
				continue
			}
			resolved_type = true
			for field in symbol.children {
				if field.kind != sym_kind_field
					|| (require_public && !struct_field_is_public(code_lines, symbol, field)) {
					continue
				}
				if field.range.start.line >= 0 && field.range.start.line < code_lines.len {
					embedded_source_type := embedded_struct_type(code_lines[field.range.start.line])
					if embedded_source_type != '' {
						embedded_type := qualify_embedded_receiver_type(receiver_type,
							embedded_source_type)
						if embedded_type !in embedded_types {
							embedded_types << embedded_type
						}
						promoted := app.indexed_struct_field_completions_visited(uri, content,
							embedded_type, mut visited)
						has_conditional = has_conditional || promoted.use_compiler
						has_unresolved_embedded = has_unresolved_embedded || !promoted.resolved_type
						for promoted_type in promoted.embedded_types {
							if promoted_type !in embedded_types {
								embedded_types << promoted_type
							}
						}
						for detail in promoted.items {
							if detail.label !in seen_items {
								items << detail
								seen_items[detail.label] = true
							}
						}
						continue
					}
				}
				if detail := field_completion_from_symbol(source_lines, code_lines, field) {
					if detail.label !in seen_items {
						items << detail
						seen_items[detail.label] = true
					}
				}
			}
		}
	}
	return IndexedCompletionResult{
		items:          items
		use_compiler:   has_conditional || has_unresolved_embedded
		embedded_types: embedded_types
		resolved_type:  resolved_type
	}
}

fn (mut app App) indexed_receiver_completions(uri string, content string, receiver string, use_line int) IndexedCompletionResult {
	receiver_type := app.infer_receiver_type(uri, content, receiver, use_line)
	if receiver_type == '' {
		return IndexedCompletionResult{
			use_compiler: true
		}
	}
	field_result := app.indexed_struct_field_completions(uri, content, receiver_type)
	mut items := field_result.items.clone()
	mut seen := map[string]bool{}
	for item in items {
		seen[item.label] = true
	}
	mut receiver_types := [receiver_type]
	for embedded_type in field_result.embedded_types {
		if embedded_type !in receiver_types {
			receiver_types << embedded_type
		}
	}
	mut methods_use_compiler := false
	for member_type in receiver_types {
		method_result := app.indexed_method_symbols(uri, content, member_type, '')
		methods_use_compiler = methods_use_compiler || method_result.use_compiler
		for location in method_result.locations {
			entry := app.symbol_index[location.uri] or { continue }
			source := app.index_source_for(location.uri) or { continue }
			for symbol in entry.doc_symbols {
				if symbol.kind != sym_kind_method
					|| symbol.range.start.line != location.range.start.line {
					continue
				}
				if detail := method_completion_from_symbol(source, symbol) {
					if detail.label !in seen {
						items << detail
						seen[detail.label] = true
					}
				}
			}
		}
	}
	return IndexedCompletionResult{
		items:        items
		use_compiler: field_result.use_compiler || methods_use_compiler || items.len == 0
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

struct ImportInterpolationState {
	quote u8
mut:
	brace_depth int
}

struct ImportScanState {
mut:
	block_comment_depth int
	quote               u8
	raw_string          bool
	interpolations      []ImportInterpolationState
}

fn source_line_import_code(line string, mut state ImportScanState) string {
	mut code := []u8{cap: line.len}
	mut col := 0
	for col < line.len {
		if state.block_comment_depth > 0 {
			if col + 1 < line.len && line[col] == `/` && line[col + 1] == `*` {
				state.block_comment_depth++
				col += 2
				continue
			}
			if col + 1 < line.len && line[col] == `*` && line[col + 1] == `/` {
				state.block_comment_depth--
				code << ` `
				col += 2
				continue
			}
			col++
			continue
		}
		if state.quote != 0 {
			if !state.raw_string && line[col] == `\\` && col + 1 < line.len {
				col += 2
				continue
			}
			if !state.raw_string && line[col] == `$` && col + 1 < line.len
				&& line[col + 1] == `{` {
				state.interpolations << ImportInterpolationState{
					quote: state.quote
				}
				state.quote = 0
				code << ` `
				col += 2
				continue
			}
			if line[col] == state.quote {
				state.quote = 0
				state.raw_string = false
				code << ` `
			}
			col++
			continue
		}
		if col + 1 < line.len && line[col] == `/` && line[col + 1] == `/` {
			break
		}
		if col + 1 < line.len && line[col] == `/` && line[col + 1] == `*` {
			state.block_comment_depth = 1
			code << ` `
			col += 2
			continue
		}
		if line[col] == `{` && state.interpolations.len > 0 {
			last := state.interpolations.len - 1
			state.interpolations[last].brace_depth++
			code << line[col]
			col++
			continue
		}
		if line[col] == `}` && state.interpolations.len > 0 {
			last := state.interpolations.len - 1
			if state.interpolations[last].brace_depth == 0 {
				interpolation := state.interpolations.pop()
				state.quote = interpolation.quote
				state.raw_string = false
				code << ` `
			} else {
				state.interpolations[last].brace_depth--
				code << line[col]
			}
			col++
			continue
		}
		if line[col] == `r` && col + 1 < line.len
			&& (line[col + 1] == `"` || line[col + 1] == `'`) {
			state.quote = line[col + 1]
			state.raw_string = true
			code << ` `
			col += 2
			continue
		}
		if line[col] == `"` || line[col] == `'` || line[col] == 96 {
			state.quote = line[col]
			state.raw_string = false
			code << ` `
			col++
			continue
		}
		code << line[col]
		col++
	}
	return code.bytestr()
}

fn source_code_lines(content string) []string {
	mut lines := []string{}
	mut scan_state := ImportScanState{}
	for raw_line in content.split_into_lines() {
		lines << source_line_import_code(raw_line, mut scan_state)
	}
	return lines
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

fn (mut app App) get_imported_module_member_completions(module_path string, work_dir string) IndexedModuleCompletionResult {
	mut items := []Detail{}
	module_dir := app.resolve_indexed_import_module_dir(module_path, work_dir)
	if module_dir == '' {
		return IndexedModuleCompletionResult{
			use_compiler: true
		}
	}
	app.ensure_dir_shallow_indexed(module_dir)
	normalized_dir := normalized_index_path(module_dir)
	for open_uri, _ in app.open_files {
		if normalized_index_path(os.dir(uri_to_path(open_uri))) == normalized_dir {
			app.reindex_uri(open_uri)
		}
	}
	active_names := app.active_indexed_source_file_names(module_dir, '')
	expected_module := module_path.all_after_last('.')
	mut seen_labels := map[string]bool{}
	mut has_conditional := false
	mut indexed_uris := app.symbol_index.keys()
	indexed_uris.sort()
	for indexed_uri in indexed_uris {
		entry := app.symbol_index[indexed_uri] or { continue }
		if normalized_index_path(os.dir(uri_to_path(indexed_uri))) != normalized_dir
			|| os.file_name(uri_to_path(indexed_uri)) !in active_names
			|| entry.module_name != expected_module {
			continue
		}
		if entry.has_conditional_public_completions {
			has_conditional = true
		}
		for item in entry.public_module_completions {
			if item.label in seen_labels {
				continue
			}
			seen_labels[item.label] = true
			items << item
		}
	}
	return IndexedModuleCompletionResult{
		items:        items
		use_compiler: has_conditional || items.len == 0
	}
}

fn resolve_import_module_dir(module_path string, work_dir string) string {
	rel := module_path.replace('.', os.path_separator)
	vlib_dir := os.join_path(find_v_dir(), 'vlib', rel)
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
	if work_dir != '' {
		source_relative_dir := os.join_path(work_dir, rel)
		if os.is_dir(source_relative_dir) {
			return source_relative_dir
		}
	}
	return resolve_import_module_dir(module_path, work_dir)
}

fn module_type_completion_name(declaration string) string {
	name := first_word(declaration)
	return name.all_before('[')
}

fn module_completion_declaration(line string, public_only bool) bool {
	is_public := line.starts_with('pub ')
	if public_only && !is_public {
		return false
	}
	declaration := if is_public { line[4..] } else { line }
	if declaration.starts_with('fn ') {
		return !declaration[3..].trim_space().starts_with('(')
	}
	return declaration.starts_with('const ') || declaration.starts_with('struct ')
		|| declaration.starts_with('union ') || declaration.starts_with('enum ')
		|| declaration.starts_with('interface ') || declaration.starts_with('type ')
}

fn const_block_assignment_name(line string) string {
	mut delimiter_depth := 0
	for index, c in line {
		match c {
			`(`, `[`, `{` { delimiter_depth++ }
			`)`, `]`, `}` {
				if delimiter_depth > 0 {
					delimiter_depth--
				}
			}
			`=` {
				if delimiter_depth == 0 {
					name := line[..index].trim_space()
					return if is_valid_v_identifier_name(name) { name } else { '' }
				}
			}
			else {}
		}
	}
	return ''
}

fn update_expression_delimiter_depth(line string, initial_depth int) int {
	mut depth := initial_depth
	for c in line {
		if c in [`(`, `[`, `{`] {
			depth++
		} else if c in [`)`, `]`, `}`] && depth > 0 {
			depth--
		}
	}
	return depth
}

fn compile_time_conditional_lines(content string) []bool {
	lines := content.split_into_lines()
	mut result := []bool{len: lines.len}
	mut brace_depth := 0
	mut conditional_depths := []int{}
	mut pending_conditional_block := false
	mut pending_conditional_attribute := false
	mut attribute_depth := 0
	mut attribute_content := []u8{}
	mut scan_state := ImportScanState{}
	for line_idx, raw_line in lines {
		line := source_line_import_code(raw_line, mut scan_state)
		result[line_idx] = conditional_depths.len > 0 || pending_conditional_attribute
		mut col := 0
		for col < line.len {
			if attribute_depth == 0 && col + 1 < line.len && line[col] == `@`
				&& line[col + 1] == `[` {
				attribute_depth = 1
				attribute_content = []u8{}
				col += 2
				continue
			}
			if attribute_depth > 0 {
				if line[col] == `[` {
					attribute_depth++
					attribute_content << line[col]
				} else if line[col] == `]` {
					attribute_depth--
					if attribute_depth == 0 {
						if source_attribute_content_is_conditional(attribute_content.bytestr()) {
							pending_conditional_attribute = true
						}
					} else {
						attribute_content << line[col]
					}
				} else {
					attribute_content << line[col]
				}
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
					pending_conditional_block = true
					col += directive_len
					continue
				}
			}
			if line[col] == `{` {
				brace_depth++
				if pending_conditional_block {
					conditional_depths << brace_depth
					pending_conditional_block = false
					result[line_idx] = true
				}
			} else if line[col] == `}` {
				if conditional_depths.len > 0 && conditional_depths.last() == brace_depth {
					conditional_depths.delete_last()
				}
				if brace_depth > 0 {
					brace_depth--
				}
			} else if line[col] !in [` `, `\t`, `\r`] && pending_conditional_attribute {
				result[line_idx] = true
				pending_conditional_attribute = false
			}
			col++
		}
		if attribute_depth > 0 {
			attribute_content << `\n`
		}
	}
	return result
}

fn parse_module_member_completions(content string, public_only bool) ParsedModuleCompletionIndex {
	mut items := []Detail{}
	mut has_conditional := false
	lines := source_code_lines(content)
	conditional_lines := compile_time_conditional_lines(content)
	mut in_const_block := false
	mut const_block_public := false
	mut const_expression_depth := 0
	for line_idx, line in lines {
		trimmed := line.trim_space()
		if trimmed == '' || trimmed.starts_with('//') {
			continue
		}
		if conditional_lines[line_idx] {
			if module_completion_declaration(trimmed, public_only) {
				has_conditional = true
			}
			continue
		}
		if trimmed == 'const (' || trimmed == 'pub const (' {
			in_const_block = true
			const_block_public = trimmed.starts_with('pub ')
			const_expression_depth = 0
			continue
		}
		if in_const_block {
			if const_expression_depth == 0 && trimmed == ')' {
				in_const_block = false
				const_block_public = false
				continue
			}
			if const_expression_depth == 0 {
				name := const_block_assignment_name(trimmed)
				if name != '' && (!public_only || const_block_public) {
					items << Detail{
						kind:   21 // CompletionItemKind.Constant
						label:  name
						detail: if const_block_public { 'pub const' } else { 'const' }
					}
				}
			}
			const_expression_depth = update_expression_delimiter_depth(trimmed,
				const_expression_depth)
			continue
		}
		is_public := trimmed.starts_with('pub ')
		if public_only && !is_public {
			continue
		}
		declaration := if is_public { trimmed[4..] } else { trimmed }
		if declaration.starts_with('fn ') {
			complete_declaration := complete_function_signature(lines, line_idx, declaration)
			after_fn := complete_declaration[3..]
			if after_fn.starts_with('(') {
				continue
			}
			paren_idx := after_fn.index('(') or { continue }
			raw_fn_name := after_fn[..paren_idx].trim_space()
			fn_name := raw_fn_name.all_before('[')
			if fn_name == '' || fn_name.contains(' ') {
				continue
			}
			detail_str := '${if is_public { 'pub ' } else { '' }}${complete_declaration}'.all_before('{').trim_space()
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
		if declaration.starts_with('const ') {
			name := extract_const_name(declaration[6..])
			if name != '' {
				items << Detail{
					kind:   21
					label:  name
					detail: trimmed.all_before('=').trim_space()
				}
			}
			continue
		}
		if declaration.starts_with('struct ') {
			name := module_type_completion_name(declaration[7..])
			if name != '' {
				items << Detail{
					kind:   22 // CompletionItemKind.Struct
					label:  name
					detail: trimmed.all_before('{').trim_space()
				}
			}
			continue
		}
		if declaration.starts_with('union ') {
			name := module_type_completion_name(declaration[6..])
			if name != '' {
				items << Detail{
					kind:   22 // CompletionItemKind.Struct
					label:  name
					detail: trimmed.all_before('{').trim_space()
				}
			}
			continue
		}
		if declaration.starts_with('enum ') {
			name := module_type_completion_name(declaration[5..])
			if name != '' {
				items << Detail{
					kind:   13 // CompletionItemKind.Enum
					label:  name
					detail: trimmed.all_before('{').trim_space()
				}
			}
			continue
		}
		if declaration.starts_with('interface ') {
			name := module_type_completion_name(declaration[10..])
			if name != '' {
				items << Detail{
					kind:   8 // CompletionItemKind.Interface
					label:  name
					detail: trimmed.all_before('{').trim_space()
				}
			}
			continue
		}
		if declaration.starts_with('type ') {
			name := module_type_completion_name(declaration[5..])
			if name != '' {
				items << Detail{
					kind:   7 // CompletionItemKind.Class
					label:  name
					detail: trimmed.all_before('=').trim_space()
				}
			}
		}
	}
	return ParsedModuleCompletionIndex{
		items:           items
		has_conditional: has_conditional
	}
}

// on_did_open handles the LSP didOpen notification, loading file content into
// the server state. It returns true when diagnostics were scheduled.
fn (mut app App) on_did_open(request Request) bool {
	params := json2.decode[DidOpenTextDocumentParams](request.params) or {
		$if debug { log('Failed to decode DidOpenTextDocumentParams: ${err}') }
		return false
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
			return false
		}
	}
	diagnostics_mutation := app.begin_diagnostics_project_schedule(uri)
	app.open_files[uri] = content
	if version := params.text_document.version {
		app.open_files_versions[uri] = version
	}
	app.bump_generation(uri)
	app.invalidate_index_uri(uri) // re-parse from the buffer on next query
	app.text = content
	$if debug { log('STORED CONTENT for uri=${uri}, FILE COUNT: ${app.open_files.len}') }
	return app.finish_diagnostics_project_schedule(diagnostics_mutation, uri, content)
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
	is_open := uri in app.open_files
	mut diagnostics_mutation := DiagnosticsProjectMutation{}
	if is_open {
		diagnostics_mutation = app.begin_diagnostics_project_mutation(uri)
	} else {
		app.cancel_scheduled_diagnostics(uri)
	}
	if is_open {
		app.open_files.delete(uri)
		app.bump_generation(uri)
	}
	if uri in app.open_files_versions {
		app.open_files_versions.delete(uri)
	}
	if uri in app.diag_cache {
		app.diag_cache.delete(uri)
	}
	if is_open {
		app.finish_diagnostics_project_mutation(diagnostics_mutation, uri)
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
	// Invalidate every diagnostic snapshot for this project before publishing
	// the new buffer state. Replacements are built after the mutation below.
	diagnostics_mutation := app.begin_diagnostics_project_schedule(uri)
	app.text = content
	app.open_files[uri] = content // Update tracked file
	if version := params.text_document.version {
		app.open_files_versions[uri] = version
	}
	app.bump_generation(uri)
	app.invalidate_index_uri(uri) // symbols re-parsed lazily on next query
	if app.finish_diagnostics_project_schedule(diagnostics_mutation, uri, content) {
		return none
	}
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
	mut diagnostics_mutation := DiagnosticsProjectMutation{}
	if existing := app.open_files[uri] {
		content = existing
		if text := params.text {
			content = text
			diagnostics_mutation = app.begin_diagnostics_project_schedule(uri)
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
	if diagnostics_mutation.tickets.len > 0 {
		if app.finish_diagnostics_project_schedule(diagnostics_mutation, uri, content) {
			return none
		}
	} else if app.schedule_diagnostics(uri, content) {
		return none
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
	if !is_ident_start(first) {
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

// is_ident_start reports whether `c` can begin an identifier (letter or underscore).
fn is_ident_start(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

// PositionEncoding is the unit the client uses for LSP `character` offsets.
// LSP defaults to utf16; utf8 (byte offsets) and utf32 (code points) are only
// used when negotiated via the client's `general.positionEncodings`.
enum PositionEncoding {
	utf16
	utf8
	utf32
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

fn source_attribute_content_is_conditional(content string) bool {
	for attribute in content.split(';') {
		fields := attribute.fields()
		if fields.len > 0 && fields[0] == 'if' {
			return true
		}
	}
	return false
}

fn source_declaration_has_conditional_attribute(content string, declaration_line int) bool {
	lines := content.split_into_lines()
	if declaration_line < 0 || declaration_line >= lines.len {
		return false
	}
	mut pending_conditional := false
	mut attribute_depth := 0
	mut attribute_content := []u8{}
	mut scan_state := ImportScanState{}
	for line_idx in 0 .. declaration_line {
		line := source_line_import_code(lines[line_idx], mut scan_state)
		mut col := 0
		for col < line.len {
			if attribute_depth == 0 && col + 1 < line.len && line[col] == `@`
				&& line[col + 1] == `[` {
				attribute_depth = 1
				attribute_content = []u8{}
				col += 2
				continue
			}
			if attribute_depth > 0 {
				if line[col] == `[` {
					attribute_depth++
					attribute_content << line[col]
				} else if line[col] == `]` {
					attribute_depth--
					if attribute_depth == 0 {
						if source_attribute_content_is_conditional(attribute_content.bytestr()) {
							pending_conditional = true
						}
					} else {
						attribute_content << line[col]
					}
				} else {
					attribute_content << line[col]
				}
				col++
				continue
			}
			if line[col] !in [` `, `\t`, `\r`] {
				pending_conditional = false
			}
			col++
		}
		if attribute_depth > 0 {
			attribute_content << `\n`
		}
	}
	return pending_conditional
}

// source_declaration_is_compile_time_conditional identifies declarations nested
// under `$if`/`$else` or guarded by `@[if ...]`. The shallow index does not
// evaluate compile-time conditions, so every such declaration must defer to
// compiler-backed lookup.
fn source_declaration_is_compile_time_conditional(content string, declaration_line int) bool {
	if declaration_line < 0 {
		return false
	}
	if source_declaration_has_conditional_attribute(content, declaration_line) {
		return true
	}
	lines := content.split_into_lines()
	mut brace_depth := 0
	mut conditional_depths := []int{}
	mut pending_conditional := false
	mut scan_state := ImportScanState{}
	for line_idx, raw_line in lines {
		if line_idx == declaration_line {
			return conditional_depths.len > 0
		}
		line := source_line_import_code(raw_line, mut scan_state)
		mut col := 0
		for col < line.len {
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
fn source_occurrence_precedes_local_declaration(lines []string, line_idx int, end_byte int) bool {
	if line_idx < 0 || line_idx >= lines.len || end_byte < 0
		|| end_byte > lines[line_idx].len {
		return false
	}
	mut scan_state := ImportScanState{}
	for current_line in 0 .. line_idx + 1 {
		raw_line := lines[current_line]
		fragment := if current_line == line_idx { raw_line[..end_byte] } else { raw_line }
		source_line_import_code(fragment, mut scan_state)
	}
	mut expects_target := false
	for current_line in line_idx .. lines.len {
		raw_line := lines[current_line]
		fragment := if current_line == line_idx { raw_line[end_byte..] } else { raw_line }
		code := source_line_import_code(fragment, mut scan_state)
		mut col := 0
		for col < code.len {
			if code[col] in [` `, `\t`, `\r`] {
				col++
				continue
			}
			if expects_target {
				if !is_ident_char(code[col]) || (code[col] >= `0` && code[col] <= `9`) {
					return false
				}
				col++
				for col < code.len && is_ident_char(code[col]) {
					col++
				}
				expects_target = false
				continue
			}
			if code[col] == `,` {
				expects_target = true
				col++
				continue
			}
			if col + 1 < code.len && code[col] == `:` && code[col + 1] == `=` {
				return true
			}
			return false
		}
	}
	return false
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

fn source_occurrence_is_compile_time_condition(lines []string, line_idx int, start_byte int, if_occurrences []TokenOccurrence, enc PositionEncoding) bool {
	if line_idx < 0 || line_idx >= lines.len || start_byte < 0 || start_byte > lines[line_idx].len {
		return false
	}
	for occurrence in if_occurrences {
		if occurrence.line < 0 || occurrence.line > line_idx || occurrence.line >= lines.len {
			continue
		}
		directive_line := lines[occurrence.line]
		directive_start := encoded_col_to_byte(directive_line, occurrence.start_char, enc)
		directive_end := encoded_col_to_byte(directive_line, occurrence.end_char, enc)
		if directive_start <= 0 || directive_end > directive_line.len
			|| directive_line[directive_start - 1] != `$`
			|| (occurrence.line == line_idx && directive_end > start_byte) {
			continue
		}
		mut reaches_target := true
		mut scan_state := ImportScanState{}
		for scan_line_idx in occurrence.line .. line_idx + 1 {
			raw_line := lines[scan_line_idx]
			fragment_start := if scan_line_idx == occurrence.line { directive_end } else { 0 }
			fragment_end := if scan_line_idx == line_idx { start_byte } else { raw_line.len }
			if fragment_start > fragment_end {
				continue
			}
			code := source_line_import_code(raw_line[fragment_start..fragment_end], mut scan_state)
			if code.contains('{') {
				reaches_target = false
				break
			}
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

fn source_occurrence_is_method_declaration(lines []string, target_line int, start_byte int) bool {
	if target_line < 0 || target_line >= lines.len || start_byte < 0
		|| start_byte > lines[target_line].len {
		return false
	}
	mut code_lines := []string{cap: target_line + 1}
	mut scan_state := ImportScanState{}
	for line_idx in 0 .. target_line + 1 {
		raw_line := lines[line_idx]
		fragment := if line_idx == target_line { raw_line[..start_byte] } else { raw_line }
		code_lines << source_line_import_code(fragment, mut scan_state)
	}
	prefix := code_lines.join(' ').trim_space()
	if prefix.len < 3 || prefix[prefix.len - 1] != `)` {
		return false
	}
	mut depth := 0
	mut receiver_start := -1
	mut col := prefix.len - 1
	for col >= 0 {
		if prefix[col] == `)` {
			depth++
		} else if prefix[col] == `(` {
			depth--
			if depth == 0 {
				receiver_start = col
				break
			}
		}
		col--
	}
	if receiver_start < 0 || prefix[receiver_start + 1..prefix.len - 1].trim_space() == '' {
		return false
	}
	declaration_prefix := prefix[..receiver_start].trim_space()
	if !declaration_prefix.ends_with('fn') {
		return false
	}
	fn_start := declaration_prefix.len - 2
	return fn_start == 0 || !is_ident_char(declaration_prefix[fn_start - 1])
}

fn source_occurrence_has_compile_time_prefix(line string, start_byte int) bool {
	return start_byte > 0 && start_byte <= line.len && line[start_byte - 1] in [`@`, `$`]
}

fn source_line_is_hash_directive(lines []string, target_line int) bool {
	if target_line < 0 || target_line >= lines.len {
		return false
	}
	mut scan_state := ImportScanState{}
	for line_idx in 0 .. target_line + 1 {
		line := source_line_import_code(lines[line_idx], mut scan_state)
		if line_idx == target_line {
			return line.trim_space().starts_with('#')
		}
	}
	return false
}

fn source_occurrence_is_asm_block(lines []string, target_line int, end_byte int) bool {
	if target_line < 0 || target_line >= lines.len || end_byte < 0
		|| end_byte > lines[target_line].len {
		return false
	}
	mut brace_depth := 0
	mut asm_depths := []int{}
	mut pending_asm := false
	mut scan_state := ImportScanState{}
	for line_idx, raw_line in lines {
		if line_idx > target_line {
			break
		}
		fragment := if line_idx == target_line { raw_line[..end_byte] } else { raw_line }
		line := source_line_import_code(fragment, mut scan_state)
		mut col := 0
		for col < line.len {
			if is_ident_char(line[col]) {
				identifier_start := col
				col++
				for col < line.len && is_ident_char(line[col]) {
					col++
				}
				if line[identifier_start..col] == 'asm' {
					pending_asm = true
				}
				continue
			}
			if line[col] == `{` {
				brace_depth++
				if pending_asm {
					asm_depths << brace_depth
					pending_asm = false
				}
			} else if line[col] == `}` {
				if asm_depths.len > 0 && asm_depths.last() == brace_depth {
					asm_depths.delete_last()
				}
				if brace_depth > 0 {
					brace_depth--
				}
			}
			col++
		}
	}
	return pending_asm || asm_depths.len > 0
}

fn source_occurrence_is_sql_expression(lines []string, target_line int, start_byte int) bool {
	if target_line < 0 || target_line >= lines.len || start_byte < 0
		|| start_byte > lines[target_line].len {
		return false
	}
	mut brace_depth := 0
	mut sql_depths := []int{}
	// 1 means the contextual `sql` keyword was seen; 2 means its database
	// expression has started and remains active until the query block opens.
	mut sql_connection_state := 0
	mut scan_state := ImportScanState{}
	for line_idx, raw_line in lines {
		if line_idx > target_line {
			break
		}
		fragment := if line_idx == target_line { raw_line[..start_byte] } else { raw_line }
		line := source_line_import_code(fragment, mut scan_state)
		mut col := 0
		for col < line.len {
			if is_ident_char(line[col]) {
				identifier_start := col
				col++
				for col < line.len && is_ident_char(line[col]) {
					col++
				}
				identifier := line[identifier_start..col]
				if sql_connection_state == 0 && sql_depths.len == 0 && identifier == 'sql' {
					sql_connection_state = 1
				} else if sql_connection_state == 1 {
					sql_connection_state = 2
				}
				continue
			}
			if line[col] == `{` {
				brace_depth++
				if sql_connection_state == 2 {
					sql_depths << brace_depth
				}
				sql_connection_state = 0
			} else if line[col] == `}` {
				if sql_depths.len > 0 && sql_depths.last() == brace_depth {
					sql_depths.delete_last()
				}
				if brace_depth > 0 {
					brace_depth--
				}
				sql_connection_state = 0
			} else if sql_connection_state == 1 && line[col] != ` ` && line[col] != `\t`
				&& line[col] != `\r` {
				sql_connection_state = 0
			} else if sql_connection_state == 2 && line[col] == `;` {
				sql_connection_state = 0
			}
			col++
		}
	}
	return sql_depths.len > 0
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
	mut attribute_depth := 0
	mut scan_state := ImportScanState{}
	for line_idx, raw_line in lines {
		if line_idx > target_line {
			break
		}
		fragment := if line_idx == target_line { raw_line[..start_byte] } else { raw_line }
		line := source_line_import_code(fragment, mut scan_state)
		mut col := 0
		for col < line.len {
			if attribute_depth == 0 && col + 1 < line.len && line[col] == `@`
				&& line[col + 1] == `[` {
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
		if name == '' || (name[0] >= `0` && name[0] <= `9`) {
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

fn source_occurrence_is_for_binding(lines []string, line_idx int, start_byte int, end_byte int) bool {
	if line_idx < 0 || line_idx >= lines.len || start_byte < 0 || end_byte <= start_byte
		|| end_byte > lines[line_idx].len {
		return false
	}
	mut scan_state := ImportScanState{}
	mut before_lines := []string{cap: line_idx + 1}
	for current_line in 0 .. line_idx + 1 {
		raw_line := lines[current_line]
		fragment := if current_line == line_idx { raw_line[..start_byte] } else { raw_line }
		before_lines << source_line_import_code(fragment, mut scan_state)
	}
	mut has_for := false
	mut has_in := false
	before := before_lines.join('\n')
	mut col := 0
	for col < before.len {
		if before[col] in [`{`, `}`, `;`] {
			has_for = false
			has_in = false
			col++
			continue
		}
		if !is_ident_char(before[col]) {
			col++
			continue
		}
		start := col
		col++
		for col < before.len && is_ident_char(before[col]) {
			col++
		}
		word := before[start..col]
		if word == 'for' {
			has_for = true
			has_in = false
		} else if has_for && word == 'in' {
			has_in = true
		}
	}
	if !has_for || has_in {
		return false
	}
	mut after_lines := []string{cap: lines.len - line_idx}
	for current_line in line_idx .. lines.len {
		raw_line := lines[current_line]
		fragment := if current_line == line_idx { raw_line[end_byte..] } else { raw_line }
		after_lines << source_line_import_code(fragment, mut scan_state)
	}
	after := after_lines.join('\n')
	col = 0
	for col < after.len {
		if after[col] in [`{`, `}`, `;`] {
			return false
		}
		if !is_ident_char(after[col]) {
			col++
			continue
		}
		start := col
		col++
		for col < after.len && is_ident_char(after[col]) {
			col++
		}
		if after[start..col] == 'in' {
			return true
		}
	}
	return false
}

fn source_occurrence_has_type_suffix(lines []string, line_idx int, end_byte int) bool {
	if line_idx < 0 || line_idx >= lines.len || end_byte < 0
		|| end_byte > lines[line_idx].len {
		return false
	}
	mut scan_state := ImportScanState{}
	for current_line in 0 .. line_idx + 1 {
		raw_line := lines[current_line]
		fragment := if current_line == line_idx { raw_line[..end_byte] } else { raw_line }
		source_line_import_code(fragment, mut scan_state)
	}
	code := source_line_import_code(lines[line_idx][end_byte..], mut scan_state)
	mut has_separator := false
	for c in code {
		if c in [` `, `\t`, `\r`] {
			has_separator = true
			continue
		}
		is_type_start := (is_ident_char(c) && !(c >= `0` && c <= `9`))
			|| c in [`[`, `?`, `&`, `.`]
		return has_separator && is_type_start
	}
	return false
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
		if is_for_binding_highlight(line, start_byte, end_byte)
			|| source_occurrence_is_for_binding(lines, occurrence.line, start_byte, end_byte) {
			return true
		}
		if source_occurrence_precedes_local_declaration(lines, occurrence.line, end_byte) {
			return true
		}
		if source_occurrence_is_generic_parameter(lines, occurrence.line, start_byte, end_byte) {
			return true
		}
		if source_occurrence_has_type_suffix(lines, occurrence.line, end_byte) {
			return true
		}
	}
	return false
}

// active_indexed_source_file_names applies the compiler's native build-file
// filtering without removing inactive sources from the broader symbol index.
// The requesting test file is a direct compiler input, but sibling tests are
// separate targets. Normalize its `_test` suffix before checking eligibility.
fn (app &App) active_indexed_source_file_names(dir string, active_test_file_name string) map[string]bool {
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
	if active_test_file_name in test_names {
		build_name := active_test_file_name[..active_test_file_name.len - '_test.v'.len] + '.v'
		if build_prefs.should_compile_filtered_files(dir, [build_name]).len == 1 {
			active[active_test_file_name] = true
		}
	}
	return active
}

// find_indexed_source_definition finds one unambiguous top-level declaration
// in `dir`. Methods and fields are intentionally excluded because resolving
// them safely requires receiver type information.
fn (mut app App) find_indexed_source_definition(dir string, symbol string, active_test_file_name string, require_public bool, expected_module string) ?Location {
	if dir == '' || dir == '/' || !os.is_dir(dir) || expected_module == '' {
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
	active_file_names := app.active_indexed_source_file_names(dir, active_test_file_name)
	mut matches := []Location{}
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		path := uri_to_path(uri)
		if normalized_index_path(os.dir(path)) != normalized_dir {
			continue
		}
		if os.file_name(path) !in active_file_names {
			continue
		}
		entry := app.symbol_index[uri] or { continue }
		if entry.module_name != expected_module {
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
	if source_occurrence_is_method_declaration(lines, position.line, start_byte) {
		return none
	}
	if source_occurrence_is_interface_method_signature(lines, position.line, start_byte, end_byte) {
		return none
	}
	if source_occurrence_has_compile_time_prefix(line, start_byte) {
		return none
	}
	if source_line_is_hash_directive(lines, position.line)
		|| source_occurrence_is_asm_block(lines, position.line, end_byte)
		|| source_occurrence_is_sql_expression(lines, position.line, start_byte) {
		return none
	}
	if source_occurrence_has_dot_suffix(line, end_byte) {
		if symbol == 'C' || symbol == 'JS' || symbol in parse_import_aliases(content) {
			return none
		}
	}
	if_occurrences := file_occurrences['if'] or { []TokenOccurrence{} }
	if source_occurrence_has_colon_suffix(line, end_byte)
		|| source_occurrence_is_goto_target(line, start_byte)
		|| source_occurrence_is_compile_time_condition(lines, position.line, start_byte, if_occurrences, app.position_encoding) {
		return none
	}
	alias, has_member_access, standalone_qualifier := member_qualifier_at_cursor(line, end,
		app.position_encoding)
	if has_member_access {
		has_local_binding := app.local_scope_bindings(content, position).any(it.name == alias)
		if standalone_qualifier && !has_local_binding {
			if module_path := parse_import_aliases(content)[alias] {
				module_dir := app.resolve_indexed_import_module_dir(module_path,
					os.dir(uri_to_path(uri)))
				return app.find_indexed_source_definition(module_dir, symbol, '', true,
					module_path.all_after_last('.'))
			}
		}
		receiver_type := app.infer_receiver_type(uri, content, alias, position.line)
		method_locations := app.indexed_method_symbols(uri, content, receiver_type, symbol).locations
		if method_locations.len == 1 {
			return method_locations[0]
		}
		return none
	}
	if source_occurrences_have_potential_local_binding(lines, occurrences, app.position_encoding) {
		return none
	}
	requesting_path := uri_to_path(uri)
	active_test_file_name := if requesting_path.ends_with('_test.v') {
		os.file_name(requesting_path)
	} else {
		''
	}
	return app.find_indexed_source_definition(os.dir(requesting_path), symbol,
		active_test_file_name, false, get_module_name(content))
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
					close_idx := rest.index(')') or { break }
					rest[close_idx + 1..].trim_space()
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
	mut scan_state := ImportScanState{}
	for raw_line in content.split_into_lines() {
		trimmed := source_line_import_code(raw_line, mut scan_state).trim_space()
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
	if !is_import_completion_line(line) {
		return []
	}
	trimmed := line.trim_space()
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
	vlib_dir := os.join_path(find_v_dir(), 'vlib')
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
		module_dir := os.join_path(find_v_dir(), 'vlib', rel)
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
	builtin_dir := os.join_path(find_v_dir(), 'vlib', 'builtin')
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
		module_dir := os.join_path(find_v_dir(), 'vlib', module_rel)
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
			is_float_char := (c >= `0` && c <= `9`) || c == `.` || c == `-` || c == `_`
			if !is_float_char {
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
		is_int_char := (c >= `0` && c <= `9`) || c == `-` || c == `_`
		if !is_int_char {
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
		vlib_mod_dir := os.join_path(find_v_dir(), 'vlib', mod_path)
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
	code_lines := source_code_lines(content)
	mut symbols := []DocumentSymbol{}
	// Track whether we are inside a struct or enum block to collect children.
	mut in_struct := false
	mut in_enum := false
	mut in_struct_attribute := false
	mut current_parent_idx := -1 // index into `symbols` for the current parent

	for i, raw_line in lines {
		line := code_lines[i].trim_space()

		// Skip blank lines and pure comment lines
		if line == '' || line.starts_with('//') {
			continue
		}

		// Closing brace ends a struct/enum body
		if line == '}' {
			in_struct = false
			in_enum = false
			in_struct_attribute = false
			current_parent_idx = -1
			continue
		}

		// Inside a struct body — collect field names
		if in_struct && current_parent_idx >= 0 {
			if in_struct_attribute {
				if line.contains(']') {
					in_struct_attribute = false
				}
				continue
			}
			if line.starts_with('@[') {
				in_struct_attribute = !line.contains(']')
				continue
			}
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
					in_struct_attribute = false
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
	selection_name := if kind == sym_kind_method { extract_simple_fn_name(name) } else { name }
	mut col_start := raw_line.index(selection_name) or { 0 }
	if kind == sym_kind_method {
		// A receiver type can contain the method name as an identifier. Search
		// after the receiver so selectionRange points at the declared method.
		if receiver_end := raw_line.index(')') {
			if method_offset := raw_line[receiver_end + 1..].index(selection_name) {
				col_start = receiver_end + 1 + method_offset
			}
		}
	}
	col_end := col_start + selection_name.len
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
		close_idx := t.index(')') or { return '' }
		rest := t[close_idx + 1..].trim_space()
		name := first_word_paren(rest)
		if name == '' {
			return ''
		}
		receiver := t[1..close_idx]
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
			message := diag.message.to_lower()
			if message.contains('unknown module') || message.contains('cannot import module') {
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

// collect_module_completions returns all top-level declarations visible within
// the current module from the persistent, open-buffer-aware source index.
fn (mut app App) collect_module_completions(current_file_uri string, working_dir string) IndexedModuleCompletionResult {
	current_content := app.open_files[current_file_uri] or {
		os.read_file(uri_to_path(current_file_uri)) or { '' }
	}
	current_module := get_module_name(current_content)
	for uri, _ in app.open_files {
		if normalized_index_path(os.dir(uri_to_path(uri))) == normalized_index_path(working_dir) {
			app.reindex_uri(uri)
		}
	}
	app.ensure_dir_shallow_indexed(working_dir)
	requesting_path := uri_to_path(current_file_uri)
	active_test_name := if requesting_path.ends_with('_test.v') {
		os.file_name(requesting_path)
	} else {
		''
	}
	active_names := app.active_indexed_source_file_names(working_dir, active_test_name)
	normalized_dir := normalized_index_path(working_dir)
	mut items := []Detail{}
	mut has_conditional := false
	mut indexed_uris := app.symbol_index.keys()
	indexed_uris.sort()
	for indexed_uri in indexed_uris {
		entry := app.symbol_index[indexed_uri] or { continue }
		if normalized_index_path(os.dir(uri_to_path(indexed_uri))) != normalized_dir
			|| os.file_name(uri_to_path(indexed_uri)) !in active_names
			|| entry.module_name != current_module {
			continue
		}
		if entry.has_conditional_module_completions {
			has_conditional = true
		}
		items << entry.module_completions
	}
	return IndexedModuleCompletionResult{
		items:        items
		use_compiler: has_conditional
	}
}

// parse_module_fn_completions extracts free-function declarations (`pub fn` and `fn`)
// from V source content and returns them as completion Detail items.
// Method receivers (e.g. `fn (r Recv) method()`) are skipped.
// When a function has parameters a snippet insertText with tab-stops is produced.
fn parse_module_fn_completions(content string) []Detail {
	return parse_module_member_completions(content, false).items.filter(it.kind == 3)
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
	close_idx := params_str.index(')') or { return fn_name + '()' }
	inner := params_str[1..close_idx].trim_space()
	if inner == '' {
		return fn_name + '()'
	}
	// Split parameters by comma and extract their names.
	raw_params := split_top_level_commas(inner)
	mut placeholders := []string{}
	for raw_param in raw_params {
		// Each token looks like `name Type` or `mut name Type` or `_ Type`.
		trimmed := raw_param.trim_space()
		if trimmed == '' {
			continue
		}
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
			param_name = 'arg${placeholders.len + 1}'
		}
		placeholders << '\${${placeholders.len + 1}:${param_name}}'
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
			if !enabled {
				app.cancel_all_scheduled_diagnostics()
			}
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

	sectioned_flat := json2.decode[DidChangeConfigurationParams](params_json) or {
		DidChangeConfigurationParams{}
	}
	merge_workspace_settings(mut resolved, sectioned_flat.settings.vls.inlay_hints,
		sectioned_flat.settings.vls.diagnostics)

	sectioned_inlay_nested := json2.decode[DidChangeConfigurationParamsCompat](params_json) or {
		DidChangeConfigurationParamsCompat{}
	}
	merge_workspace_settings(mut resolved,
		sectioned_inlay_nested.settings.vls.inlay_hints.enabled,
		sectioned_inlay_nested.settings.vls.diagnostics)

	sectioned_diagnostics_nested := json2.decode[DidChangeConfigurationParamsNestedDiagnosticsCompat](params_json) or {
		DidChangeConfigurationParamsNestedDiagnosticsCompat{}
	}
	merge_workspace_settings(mut resolved,
		sectioned_diagnostics_nested.settings.vls.inlay_hints,
		sectioned_diagnostics_nested.settings.vls.diagnostics.enabled)

	sectioned_nested := json2.decode[DidChangeConfigurationParamsNestedFeaturesCompat](params_json) or {
		DidChangeConfigurationParamsNestedFeaturesCompat{}
	}
	merge_workspace_settings(mut resolved, sectioned_nested.settings.vls.inlay_hints.enabled,
		sectioned_nested.settings.vls.diagnostics.enabled)

	direct_flat := json2.decode[DidChangeConfigurationDirectParams](params_json) or {
		DidChangeConfigurationDirectParams{}
	}
	merge_workspace_settings(mut resolved, direct_flat.settings.inlay_hints,
		direct_flat.settings.diagnostics)

	direct_inlay_nested := json2.decode[DidChangeConfigurationDirectParamsCompat](params_json) or {
		DidChangeConfigurationDirectParamsCompat{}
	}
	merge_workspace_settings(mut resolved, direct_inlay_nested.settings.inlay_hints.enabled,
		direct_inlay_nested.settings.diagnostics)

	direct_diagnostics_nested := json2.decode[DidChangeConfigurationDirectParamsNestedDiagnosticsCompat](params_json) or {
		DidChangeConfigurationDirectParamsNestedDiagnosticsCompat{}
	}
	merge_workspace_settings(mut resolved, direct_diagnostics_nested.settings.inlay_hints,
		direct_diagnostics_nested.settings.diagnostics.enabled)

	direct_nested := json2.decode[DidChangeConfigurationDirectParamsNestedFeaturesCompat](params_json) or {
		DidChangeConfigurationDirectParamsNestedFeaturesCompat{}
	}
	merge_workspace_settings(mut resolved, direct_nested.settings.inlay_hints.enabled,
		direct_nested.settings.diagnostics.enabled)
	return resolved
}

fn merge_workspace_settings(mut resolved ResolvedWorkspaceSettings, inlay_hints ?bool,
	diagnostics ?bool) {
	if !resolved.has_inlay_hints {
		if enabled := inlay_hints {
			resolved.inlay_hints = enabled
			resolved.has_inlay_hints = true
		}
	}
	if !resolved.has_diagnostics {
		if enabled := diagnostics {
			resolved.diagnostics = enabled
			resolved.has_diagnostics = true
		}
	}
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

// code_lens_fn_name returns the name of a free-function declaration on one line.
fn code_lens_fn_name(line string) string {
	mut declaration := line.trim_space()
	if declaration.starts_with('pub ') {
		declaration = declaration[4..].trim_space()
	}
	if !declaration.starts_with('fn ') {
		return ''
	}
	after_fn := declaration[3..].trim_space()
	if after_fn.starts_with('(') {
		return ''
	}
	paren_idx := after_fn.index('(') or { return '' }
	name := after_fn[..paren_idx].trim_space()
	if !is_valid_v_identifier_name(name) {
		return ''
	}
	return name
}

fn code_lens_range(line int, raw_line string, encoding PositionEncoding) LSPRange {
	return LSPRange{
		start: Position{
			line: line
			char: 0
		}
		end:   Position{
			line: line
			char: byte_to_encoded_col(raw_line, raw_line.len, encoding)
		}
	}
}

// handle_code_lens handles textDocument/codeLens requests.
// It returns Run Main for main and Run File plus Run Test for test functions.
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
	mut scan_state := ImportScanState{}
	is_test_file := uri_to_path(uri).ends_with('_test.v')
	for i, raw_line in lines {
		code := source_line_import_code(raw_line, mut scan_state)
		fn_name := code_lens_fn_name(code)
		if fn_name == 'main' {
			lenses << CodeLens{
				range:   code_lens_range(i, raw_line, app.position_encoding)
				command: Command{
					title:     'Run Main'
					command:   'vls.runFile'
					arguments: [uri]
				}
			}
		}
		if is_test_file && fn_name.starts_with('test_') {
			lenses << CodeLens{
				range:   code_lens_range(i, raw_line, app.position_encoding)
				command: Command{
					title:     'Run File'
					command:   'vls.runTests'
					arguments: [uri]
				}
			}
			lenses << CodeLens{
				range:   code_lens_range(i, raw_line, app.position_encoding)
				command: Command{
					title:     'Run Test'
					command:   'vls.runTests'
					arguments: [uri, fn_name]
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

fn (app &App) code_lens_command_target(arguments []string) (string, string, string) {
	if arguments.len == 0 || arguments[0].trim_space() == '' {
		return '', '', 'missing file argument'
	}
	raw_path := arguments[0]
	if raw_path.contains('://') && !raw_path.starts_with('file:') {
		return '', '', 'only local files can be run'
	}
	path := normalize_overlay_path(os.abs_path(uri_to_path(raw_path)))
	mut uri := if raw_path.starts_with('file:') { raw_path } else { path_to_uri(path) }
	mut is_open := uri in app.open_files
	if !is_open {
		path_key := normalized_index_path(path)
		for open_uri, _ in app.open_files {
			if normalized_index_path(uri_to_path(open_uri)) == path_key {
				uri = open_uri
				is_open = true
				break
			}
		}
	}
	if !is_open && !os.is_file(path) {
		return '', '', 'file does not exist: ${path}'
	}
	if !path.ends_with('.v') && !path.ends_with('.vsh') {
		return '', '', 'not a V source file: ${path}'
	}
	return uri, path, ''
}

// handle_execute_command handles workspace/executeCommand by invoking the V compiler.
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
			uri, path, path_error := app.code_lens_command_target(args)
			if path_error != '' {
				app.send_show_message('vls: cannot run main: ${path_error}', 1)
			} else if !compiler_is_available() {
				app.send_show_message('vls: the V compiler (`v`) was not found on PATH.', 1)
			} else {
				app.start_code_lens_run(CodeLensRunJob{
					kind:           .main
					title:          'Run Main'
					uri:            uri
					path:           path
					open_files:     app.open_files.clone()
					write_mutex:    app.write_mutex
					tcp_conn:       app.tcp_conn
					capture_output: app.capture_output
				})
			}
		}
		'vls.runTests' {
			args := params.arguments or { [] }
			uri, path, path_error := app.code_lens_command_target(args)
			if path_error != '' {
				app.send_show_message('vls: cannot run tests: ${path_error}', 1)
			} else if !path.ends_with('_test.v') {
				app.send_show_message('vls: tests can only be run from a _test.v file.', 1)
			} else {
				fn_name := if args.len > 1 { args[1] } else { '' }
				if fn_name != ''
					&& (!fn_name.starts_with('test_') || !is_valid_v_identifier_name(fn_name)) {
					app.send_show_message('vls: invalid test function: ${fn_name}', 1)
				} else {
					title := if fn_name == '' { 'Run File' } else { 'Run Test' }
					kind := if fn_name == '' {
						CodeLensRunKind.test_file
					} else {
						CodeLensRunKind.test_function
					}
					if !compiler_is_available() {
						app.send_show_message('vls: the V compiler (`v`) was not found on PATH.',
							1)
					} else {
						app.start_code_lens_run(CodeLensRunJob{
							kind:           kind
							title:          title
							uri:            uri
							path:           path
							fn_name:        fn_name
							open_files:     app.open_files.clone()
							write_mutex:    app.write_mutex
							tcp_conn:       app.tcp_conn
							capture_output: app.capture_output
						})
					}
				}
			}
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
		abs_idx := col + idx
		before_ok := abs_idx == 0 || !is_ident_char(line_text[abs_idx - 1])
		after_ok := abs_idx + symbol.len >= line_text.len || !is_ident_char(line_text[abs_idx + symbol.len])
		if before_ok && after_ok {
			sc := byte_to_encoded_col(line_text, abs_idx, app.position_encoding)
			ec := byte_to_encoded_col(line_text, abs_idx + symbol.len, app.position_encoding)
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
		col = abs_idx + 1
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
