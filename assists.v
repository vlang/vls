// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os

// StructLiteralSpan is one struct literal in a buffer: the byte offsets of its
// braces and the type it constructs (`Pixel` in `p := Pixel{x: 1}`).
struct StructLiteralSpan {
	open_offset  int
	close_offset int
	type_name    string
}

// StructLiteralField is one field a literal does not set yet, together with the
// zero value to insert for it.
struct StructLiteralField {
	name  string
	value string
}

// StructDeclaredField is one field a struct declares itself. Promoted members of
// an embedded struct are deliberately absent: V silently ignores them in a
// literal, so filling them would produce code that does nothing.
struct StructDeclaredField {
	name          string
	declared_type string
}

// StructFieldZeroKind says how a field's declared type becomes a zero value.
enum StructFieldZeroKind {
	// `value` is the zero value itself: `''`, `0`, `false`, `[]T{}` ...
	literal
	// `value` names a type, which the caller asks the index about: `Name{}`
	// when the index sees it as a struct, skipped for anything else.
	named
	// No zero value can be written (optional, reference, enum, unknown type).
	unknown
}

struct StructFieldZero {
	kind  StructFieldZeroKind
	value string
}

// Field types whose zero value is the integer literal `0`. The float types are
// here too, because a float field accepts an integer literal (`ratio: 0`
// compiles), so one literal covers every numeric field.
const zero_integer_field_types = ['i8', 'i16', 'i32', 'i64', 'i128', 'int', 'isize', 'rune', 'u8',
	'u16', 'u32', 'u64', 'u128', 'usize', 'f32', 'f64']!

// Words after which a `{` opens a block, a declaration body or a loop rather
// than a struct literal: in `if Cond {` and `fn make() Bar {` the brace belongs
// to the construct, not to `Cond` or `Bar`.
const v_literal_preceding_keywords = ['if', 'for', 'in', 'match', 'fn', 'struct', 'enum', 'interface',
	'type', 'const', 'import', 'module']!

// build_fill_struct_literal_action returns the "Fill struct literal" quick fix
// for the literal the code-action range points at, or none when the range is
// not on a struct literal, when its type is unknown to the index, or when every
// field that could be given a zero value is already set.
fn (mut app App) build_fill_struct_literal_action(uri string, content string, sel_range LSPRange) ?CodeAction {
	span := app.struct_literal_span(content, sel_range) or { return none }
	declared := app.struct_declared_fields(uri, content, span.type_name)
	if declared.len == 0 {
		return none
	}
	masked := masked_v_code(content)
	body := masked[span.open_offset + 1..span.close_offset]
	present := struct_literal_field_names(body)
	mut missing := []StructLiteralField{}
	for field in declared {
		if field.declared_type == '' || field.name in present {
			continue
		}
		zero := struct_field_zero_value(field.declared_type)
		match zero.kind {
			.literal {
				missing << StructLiteralField{
					name:  field.name
					value: zero.value
				}
			}
			.named {
				if app.type_declaration(uri, content, zero.value).kind == 'struct' {
					missing << StructLiteralField{
						name:  field.name
						value: zero.value + '{}'
					}
				}
			}
			.unknown {}
		}
	}
	if missing.len == 0 {
		return none
	}
	field_indent := if body.trim_space() == '' {
		app.first_field_indent(content, span.open_offset)
	} else {
		body_indent(body)
	}
	// The new fields follow the last one the literal already sets, so the edit
	// starts at the end of that field rather than at the closing brace.
	last_field_end := span.open_offset + 1 + body.trim_right(' \t\r\n').len
	at := byte_offset_to_position(content, last_field_end, app.position_encoding)
	return CodeAction{
		title: 'Fill struct literal'
		kind:  code_action_kind_quickfix
		edit:  WorkspaceEdit{
			changes: {
				uri: [
					TextEdit{
						range:    LSPRange{
							start: at
							end:   at
						}
						new_text: fill_struct_literal_insert_text(body, field_indent, missing)
					},
				]
			}
		}
	}
}

// struct_literal_span finds the struct literal a code-action range points at:
// the literal the selection covers, or the one the range's start is on — its
// type name, its opening brace, or anywhere inside its body.
fn (app &App) struct_literal_span(content string, sel_range LSPRange) ?StructLiteralSpan {
	masked := masked_v_code(content)
	starts := line_start_offsets(content)
	start := position_to_byte_offset(content, starts, sel_range.start.line, sel_range.start.char,
		app.position_encoding)
	mut end := start
	if sel_range.end.line != sel_range.start.line || sel_range.end.char != sel_range.start.char {
		end = position_to_byte_offset(content, starts, sel_range.end.line, sel_range.end.char,
			app.position_encoding)
	}
	if end > start {
		if span := selected_literal_span(masked, start, end) {
			return span
		}
	}
	brace := literal_brace_at_or_after(masked, start)
	if brace >= 0 {
		if span := span_for_brace(masked, brace) {
			return span
		}
	}
	open := previous_unmatched_open_brace(masked, start)
	if open < 0 {
		return none
	}
	return span_for_brace(masked, open)
}

// selected_literal_span returns the first struct literal inside [start, end),
// which is how a selection covering a whole statement still finds the literal
// in it.
fn selected_literal_span(masked string, start int, end int) ?StructLiteralSpan {
	if end <= start || start < 0 || end > masked.len {
		return none
	}
	for i in start .. end {
		if masked[i] != `{` {
			continue
		}
		span := span_for_brace(masked, i) or { continue }
		if span.close_offset < end {
			return span
		}
	}
	return none
}

// literal_brace_at_or_after returns the offset of the `{` opening the literal
// that `probe` is already on: the byte at `probe`, or the brace after the type
// name the probe sits on. It never crosses a line, so a cursor at the end of a
// line cannot claim a literal on the next one.
fn literal_brace_at_or_after(masked string, probe int) int {
	if probe < 0 || probe >= masked.len {
		return -1
	}
	if masked[probe] == `{` {
		return probe
	}
	mut i := probe
	mut square_depth := 0
	for i < masked.len {
		c := masked[i]
		if is_ident_char(c) || c == `.` {
			i++
			continue
		}
		if c == `[` {
			square_depth++
			i++
			continue
		}
		if c == `]` && square_depth > 0 {
			square_depth--
			i++
			continue
		}
		break
	}
	if square_depth != 0 {
		return -1
	}
	for i < masked.len && (masked[i] == ` ` || masked[i] == `\t`) {
		i++
	}
	if i < masked.len && masked[i] == `{` {
		return i
	}
	return -1
}

// span_for_brace recognises the struct literal opening at `open`, or none when
// that brace belongs to a block, a function body or a composite literal.
fn span_for_brace(masked string, open int) ?StructLiteralSpan {
	close := matching_delimiter(masked, open, `{`, `}`)
	if close < 0 {
		return none
	}
	sel_start, type_name := literal_type_selector(masked, open)
	// `[]Pixel{` and `map[K]V{` are composite literals, not struct literals: the
	// selector of the first is `[]Pixel`, which no type name normalises to, and
	// that of the second is `map[K]V`, which is not a type name either.
	if sel_start < 0 || !is_type_name(normalize_receiver_type(type_name)) {
		return none
	}
	if word_before_is_keyword(masked, sel_start) {
		return none
	}
	// A brace whose text since the last `fn` holds no brace of its own is a
	// function body: `fn make() Bar {`, however capital its return type is.
	fn_index := last_fn_keyword_index(masked[..open])
	if fn_index >= 0 && !masked[fn_index..open].contains('{')
		&& !masked[fn_index..open].contains('}') {
		return none
	}
	return StructLiteralSpan{
		open_offset:  open
		close_offset: close
		type_name:    type_name
	}
}

// literal_type_selector returns the start offset and the text of the type
// selector ending at `open` (`Pixel`, `clock.Pixel`, `Box[int]`), or (-1, '')
// when nothing type-shaped ends there.
fn literal_type_selector(masked string, open int) (int, string) {
	mut end := open
	for end > 0 && masked[end - 1] in [` `, `\t`, `\r`, `\n`] {
		end--
	}
	mut start := end
	mut square_depth := 0
	for start > 0 {
		c := masked[start - 1]
		if c == `]` {
			square_depth++
			start--
			continue
		}
		if square_depth > 0 {
			if c == `[` {
				square_depth--
			}
			start--
			continue
		}
		if is_ident_char(c) || c == `.` {
			start--
			continue
		}
		break
	}
	if start == end || square_depth != 0 {
		return -1, ''
	}
	return start, masked[start..end]
}

// word_before_is_keyword reports whether a keyword from
// v_literal_preceding_keywords ends just before `sel_start`.
fn word_before_is_keyword(masked string, sel_start int) bool {
	mut end := sel_start
	for end > 0 && (masked[end - 1] == ` ` || masked[end - 1] == `\t`) {
		end--
	}
	mut start := end
	for start > 0 && is_ident_char(masked[start - 1]) {
		start--
	}
	if start == end {
		return false
	}
	return masked[start..end] in v_literal_preceding_keywords
}

// struct_literal_field_names lists the fields a literal body sets, so they are
// not offered twice.
fn struct_literal_field_names(body string) []string {
	mut names := []string{}
	for part in struct_literal_field_entries(body) {
		entry := part.trim_space()
		colon := entry.index(':') or { continue }
		if colon <= 0 {
			continue
		}
		name := entry[..colon].trim_space()
		if !is_valid_v_identifier_name(name) {
			continue
		}
		names << name
	}
	return names
}

// struct_literal_field_entries splits a literal body into its field entries. A
// V literal may separate them with commas, newlines, or both, and the brackets
// of a value — a nested literal, a map, a call — hold the separators they
// contain, so an inner `name:` is never mistaken for a field of this literal.
fn struct_literal_field_entries(body string) []string {
	mut parts := []string{}
	mut start := 0
	mut round_depth := 0
	mut square_depth := 0
	mut curly_depth := 0
	for idx, c in body {
		match c {
			`(` { round_depth++ }
			`)` { round_depth-- }
			`[` { square_depth++ }
			`]` { square_depth-- }
			`{` { curly_depth++ }
			`}` { curly_depth-- }
			`,`, `\n` {
				if round_depth == 0 && square_depth == 0 && curly_depth == 0 {
					parts << body[start..idx]
					start = idx + 1
				}
			}
			else {}
		}
	}
	parts << body[start..]
	return parts
}

// struct_declared_fields lists the fields `type_name` declares, in declaration
// order, resolved through the same scope rules the completion path uses: the
// requesting module for an unqualified name, the imported module for
// `module.Name`, and public fields only when the type comes from elsewhere.
fn (mut app App) struct_declared_fields(uri string, content string, type_name string) []StructDeclaredField {
	mut dir, mut short_name, mut require_public, mut expected_module := app.receiver_type_scope(uri,
		content, type_name)
	if dir == '' || short_name == '' || expected_module == '' || !os.is_dir(dir) {
		return []StructDeclaredField{}
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
	mut fields := []StructDeclaredField{}
	mut seen := map[string]bool{}
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
		code_lines := source_code_lines(source)
		for symbol in entry.doc_symbols {
			if symbol.kind != sym_kind_struct || normalize_receiver_type(symbol.name) != short_name {
				continue
			}
			if symbol.range.start.line >= 0 && symbol.range.start.line < entry.conditional_lines.len
				&& entry.conditional_lines[symbol.range.start.line] {
				continue
			}
			if require_public && !source_declaration_is_public(indexed_uri, symbol, app) {
				continue
			}
			for field in symbol.children {
				if field.kind != sym_kind_field || field.range.start.line < 0
					|| field.range.start.line >= code_lines.len {
					continue
				}
				field_line := code_lines[field.range.start.line]
				if embedded_struct_type(field_line) != '' {
					continue
				}
				if require_public && !struct_field_is_public(code_lines, symbol, field) {
					continue
				}
				if field.name in seen {
					continue
				}
				fields << StructDeclaredField{
					name:          field.name
					declared_type: struct_field_source_type(field_line, field.name)
				}
				seen[field.name] = true
			}
		}
	}
	return fields
}

// struct_field_zero_value decides the zero value for a field of `declared_type`,
// or `unknown` when none can be written safely.
fn struct_field_zero_value(declared_type string) StructFieldZero {
	mut t := declared_type.trim_space()
	if t == '' {
		return StructFieldZero{
			kind: .unknown
		}
	}
	// An optional field is left out of a literal on purpose, a result field
	// needs an error value, and a reference field has no literal zero.
	if t[0] in [`?`, `!`, `&`] {
		return StructFieldZero{
			kind: .unknown
		}
	}
	if t.starts_with('[]') || t.starts_with('map[') || t.starts_with('chan ') {
		return StructFieldZero{
			kind:  .literal
			value: t + '{}'
		}
	}
	if t == 'string' {
		return StructFieldZero{
			kind:  .literal
			value: "''"
		}
	}
	if t == 'bool' {
		return StructFieldZero{
			kind:  .literal
			value: 'false'
		}
	}
	if t in zero_integer_field_types {
		return StructFieldZero{
			kind:  .literal
			value: '0'
		}
	}
	if is_type_name(t) {
		return StructFieldZero{
			kind:  .named
			value: t
		}
	}
	return StructFieldZero{
		kind: .unknown
	}
}

// fill_struct_literal_insert_text builds the text inserted at the end of a
// literal's last field: `, field: zero, ...` for a one-line literal, one field
// per line at `field_indent` for a literal that already spans lines. A closing
// brace sharing a line with the last field moves down to a line of its own.
fn fill_struct_literal_insert_text(body string, field_indent string, missing []StructLiteralField) string {
	mut entries := []string{cap: missing.len}
	for field in missing {
		entries << '${field.name}: ${field.value}'
	}
	trimmed := body.trim_space()
	if !body.contains('\n') {
		if trimmed == '' {
			return entries.join(', ')
		}
		separator := if trimmed.ends_with(',') { ' ' } else { ', ' }
		return separator + entries.join(', ')
	}
	prefix := if trimmed == '' || trimmed.ends_with(',') {
		'\n' + field_indent
	} else {
		',\n' + field_indent
	}
	mut text := prefix + entries.join(',\n' + field_indent)
	last_line := body.all_after_last('\n')
	if last_line.trim_space() != '' {
		text += '\n' + line_indent(last_line)
	}
	return text
}

// body_indent returns the indentation of the last non-blank body line, which is
// where a new field belongs.
fn body_indent(body string) string {
	mut indent := ''
	for line in body.split('\n') {
		if line.trim_space() == '' {
			continue
		}
		indent = line_indent(line)
	}
	return indent
}

// first_field_indent returns the indentation a literal's first field takes
// before it has any: one level past the line its opening brace sits on, which is
// how the rest of the file indents the body of a literal there.
fn (app &App) first_field_indent(content string, open_offset int) string {
	lines := content.split_into_lines()
	line := byte_offset_to_position(content, open_offset, app.position_encoding).line
	if line < 0 || line >= lines.len {
		return '\t'
	}
	return line_indent(lines[line]) + '\t'
}

// line_indent returns the leading whitespace of `line`.
fn line_indent(line string) string {
	mut end := 0
	for end < line.len && line[end] in [` `, `\t`] {
		end++
	}
	return line[..end]
}

// byte_offset_to_position maps a byte offset in `content` to the LSP position
// it denotes in `enc` units.
fn byte_offset_to_position(content string, offset int, enc PositionEncoding) Position {
	starts := line_start_offsets(content)
	mut line := starts.len - 1
	for line > 0 && starts[line] > offset {
		line--
	}
	line_text := line_text_without_terminator(content, starts, line)
	mut in_line := offset - starts[line]
	if in_line < 0 {
		in_line = 0
	}
	if in_line > line_text.len {
		in_line = line_text.len
	}
	return Position{
		line: line
		char: byte_to_encoded_col(line_text, in_line, enc)
	}
}

// masked_v_code returns `content` with the bodies of its comments and strings
// blanked to spaces, one output byte for every input byte, so an offset into the
// result addresses the same byte of the original text. Brace and selector scans
// therefore cannot be fooled by a `}` inside a string or a comment, while the
// offsets they report stay usable for the edit. The `${...}` of an interpolation
// is blanked with the string holding it: a literal written in one is not
// recognised, and the braces of the interpolation still cancel each other out.
fn masked_v_code(content string) string {
	mut out := []u8{cap: content.len}
	mut quote := u8(0)
	mut raw_string := false
	mut line_comment := false
	mut block_comment := 0
	mut i := 0
	for i < content.len {
		c := content[i]
		if line_comment {
			if c == `\n` {
				line_comment = false
				out << c
			} else {
				out << ` `
			}
			i++
			continue
		}
		if block_comment > 0 {
			// A block comment spans lines, and its `*/` is two bytes of it.
			out << if c == `\n` { c } else { ` ` }
			if c == `*` && i + 1 < content.len && content[i + 1] == `/` {
				out << ` `
				block_comment--
				i += 2
				continue
			}
			i++
			continue
		}
		if quote != 0 {
			if !raw_string && c == `\n` {
				// A V string does not span lines, so an unterminated one ends here.
				quote = 0
				out << c
				i++
				continue
			}
			if !raw_string && c == `\\` && i + 1 < content.len {
				out << ` `
				out << ` `
				i += 2
				continue
			}
			out << if c == quote { c } else { ` ` }
			if c == quote {
				quote = 0
				raw_string = false
			}
			i++
			continue
		}
		if c == `/` && i + 1 < content.len && content[i + 1] == `/` {
			line_comment = true
			out << ` `
			out << ` `
			i += 2
			continue
		}
		if c == `/` && i + 1 < content.len && content[i + 1] == `*` {
			block_comment = 1
			out << ` `
			out << ` `
			i += 2
			continue
		}
		// `r'...'` and `r"..."` are raw: no escape is a literal in one.
		if c == `r` && i + 1 < content.len && (content[i + 1] == `"` || content[i + 1] == `'`)
			&& (i == 0 || !is_ident_char(content[i - 1])) {
			quote = content[i + 1]
			raw_string = true
			out << c
			out << content[i + 1]
			i += 2
			continue
		}
		if c == `"` || c == `'` || c == 96 {
			quote = c
			raw_string = c == 96
			out << c
			i++
			continue
		}
		out << c
		i++
	}
	return out.bytestr()
}
