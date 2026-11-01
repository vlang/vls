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

// --- Extract variable ---

// AssistExprScan walks a masked expression byte by byte and refuses anything
// that is not one of the pure forms. One level of the scan is one expression:
// a primary, the field, call and index trailers hanging off it, and the base
// identifier they all traverse from. The base of every level that calls or
// indexes is kept, because those are the only receivers the caller can check
// against the buffer — a call on anything but a local is a call the language
// server cannot vouch for.
struct AssistExprScan {
	masked string
mut:
	pos       int
	levels    []string
	receivers []string
}

// assist_pure_expression reports whether `masked` is a side-effect-free
// expression — an identifier, a literal, a field access, a call or an index on
// a local, or a parenthesised combination of those — and returns the receiver
// of every call and index it holds. Each receiver must be a local before the
// expression is extracted, which the caller verifies against the buffer.
fn assist_pure_expression(masked string) ?[]string {
	mut scan := AssistExprScan{
		masked: masked
	}
	if !scan.parse_expr() {
		return none
	}
	scan.skip_ws()
	if scan.pos != masked.len {
		return none
	}
	if !assist_expression_alphabet_is_safe(masked) {
		return none
	}
	return scan.receivers
}

fn (mut s AssistExprScan) at_end() bool {
	return s.pos >= s.masked.len
}

fn (mut s AssistExprScan) skip_ws() {
	for !s.at_end() && s.masked[s.pos] in [` `, `\t`, `\r`, `\n`] {
		s.pos++
	}
}

// parse_expr parses one expression: a primary followed by the field, call and
// index trailers that hang off it. Trailing text the grammar does not reach
// makes it fail, so `x + y` and `x or { 0 }` are both refused.
fn (mut s AssistExprScan) parse_expr() bool {
	s.levels << ''
	level := s.levels.len - 1
	if !s.parse_primary(level) {
		s.drop_level()
		return false
	}
	mut calls_or_indexes := false
	for {
		s.skip_ws()
		if s.at_end() {
			break
		}
		c := s.masked[s.pos]
		if c == `.` {
			s.pos++
			if !s.parse_ident(level) {
				s.drop_level()
				return false
			}
			continue
		}
		if c == `(` || c == `[` {
			closing := if c == `(` { `)` } else { `]` }
			if !s.parse_group(c, closing) {
				s.drop_level()
				return false
			}
			calls_or_indexes = true
			continue
		}
		// Any other byte ends this expression, and the reader around it decides
		// whether that was legal: the top level check that the whole selection
		// was consumed, or the bracket that holds this expression.
		break
	}
	base := s.levels[level]
	s.drop_level()
	// A call or an index runs code the language server cannot read, so the value
	// it runs on has to be a local: `s.replace(...)`, `items[0]`, `foo.bar()`.
	if calls_or_indexes && base != '' {
		s.receivers << base
	}
	return true
}

// drop_level closes the level on top of the stack, handing its base to the level
// below when that one has none. A parenthesised primary is the base of the
// expression around it, so `(a).b()` traverses `a` and not `b`.
fn (mut s AssistExprScan) drop_level() {
	level := s.levels.len - 1
	base := s.levels[level]
	s.levels.delete_last()
	if base != '' && s.levels.len > 0 && s.levels[s.levels.len - 1] == '' {
		s.levels[s.levels.len - 1] = base
	}
}

// parse_primary parses the value an expression starts from: a parenthesised
// expression, a string or a number, or an identifier.
fn (mut s AssistExprScan) parse_primary(level int) bool {
	s.skip_ws()
	if s.at_end() {
		return false
	}
	c := s.masked[s.pos]
	if c == `(` {
		s.pos++
		s.skip_ws()
		// An empty group is not an expression, so `()` is never a candidate.
		if s.at_end() || s.masked[s.pos] == `)` {
			return false
		}
		if !s.parse_expr() {
			return false
		}
		s.skip_ws()
		if s.at_end() || s.masked[s.pos] != `)` {
			return false
		}
		s.pos++
		return true
	}
	if c == `'` || c == `"` || c == 96 {
		return s.parse_string(c)
	}
	if c >= `0` && c <= `9` {
		return s.parse_number()
	}
	return s.parse_ident(level)
}

// parse_group parses a call's arguments or an index. An index holds exactly one
// expression; a call may hold any number of them, and every one of those is
// itself held to the same purity by the recursive parse_expr.
fn (mut s AssistExprScan) parse_group(open u8, close u8) bool {
	s.pos++
	s.skip_ws()
	if !s.at_end() && s.masked[s.pos] == close {
		// `x[]` is not an index; `x()` is a call taking nothing.
		if open == `[` {
			return false
		}
		s.pos++
		return true
	}
	mut items := 0
	for {
		if !s.parse_expr() {
			return false
		}
		items++
		s.skip_ws()
		if s.at_end() {
			return false
		}
		c := s.masked[s.pos]
		if c == close {
			if close == `]` && items != 1 {
				return false
			}
			s.pos++
			return true
		}
		if c != `,` {
			return false
		}
		s.pos++
	}
	return false
}

// parse_ident consumes one identifier and remembers it as the base of `level`
// when that level has none yet. It refuses the keywords that only look like a
// value: `fn`, `unsafe`, `or`, `int` and the rest never denote a value on their
// own.
fn (mut s AssistExprScan) parse_ident(level int) bool {
	s.skip_ws()
	mut start := s.pos
	for !s.at_end() && is_ident_char(s.masked[s.pos]) {
		s.pos++
	}
	if s.pos == start {
		return false
	}
	if s.masked[start..s.pos] in assist_non_value_keywords {
		s.pos = start
		return false
	}
	if s.levels[level] == '' {
		s.levels[level] = s.masked[start..s.pos]
	}
	return true
}

// parse_string consumes a string or a rune literal. The mask has already
// blanked its body, quotes included where they are escaped, so the first
// unblanked quote after the opener is the one that closes it.
fn (mut s AssistExprScan) parse_string(quote u8) bool {
	s.pos++
	for !s.at_end() && s.masked[s.pos] != quote {
		s.pos++
	}
	if s.at_end() {
		return false
	}
	s.pos++
	return true
}

// parse_number consumes one numeric literal, including its radix prefix, its
// digit separators and the exponent that follows an `e`.
fn (mut s AssistExprScan) parse_number() bool {
	for !s.at_end() {
		c := s.masked[s.pos]
		if is_ident_char(c) || c == `.` || c == `_` {
			s.pos++
			continue
		}
		if (c == `+` || c == `-`) && s.pos > 0 && (s.masked[s.pos - 1] == `e`
			|| s.masked[s.pos - 1] == `E`) {
			s.pos++
			continue
		}
		break
	}
	return s.pos > 0
}

// assist_expression_alphabet_is_safe reports whether every byte of a candidate
// expression is one a pure form can hold: an identifier, a literal, a bracket, a
// comma or whitespace. A `{`, an `=`, an `&`, a `?`, a `#` or a `$` refuses the
// expression whatever the grammar made of it.
fn assist_expression_alphabet_is_safe(masked string) bool {
	for i in 0 .. masked.len {
		c := masked[i]
		if is_ident_char(c) || c == 96 {
			continue
		}
		match c {
			` `, `\t`, `\r`, `\n`, `.`, `(`, `)`, `[`, `]`, `,`, `'`, `"`, `+`, `-` {}
			else {
				return false
			}
		}
	}
	return true
}

// Words that never denote a value, so none of them may be the expression a
// variable is extracted from: the control-flow keywords, the type names that
// only look like a value in a declaration, and the module-level words.
const assist_non_value_keywords = ['fn', 'if', 'for', 'match', 'mut', 'unsafe', 'or', 'go', 'spawn',
	'return', 'in', 'is', 'as', 'typeof', 'sizeof', 'dump', 'panic', 'error', 'select', 'lock',
	'rlock', 'shared', 'static', 'atomic', 'defer', 'continue', 'break', 'import', 'module', 'const',
	'struct', 'enum', 'interface', 'type', 'assert', 'nil', 'bool', 'byte', 'charptr', 'f32', 'f64',
	'i8', 'i16', 'i32', 'i64', 'i128', 'int', 'isize', 'rune', 'string', 'u8', 'u16', 'u32', 'u64',
	'u128', 'usize', 'voidptr']!

// build_extract_variable_action returns the "Extract variable" quick fix for
// the expression the range selects: the selection is replaced by a fresh name
// and that name is bound to the text of the selection in front of the statement
// holding it. It is refused when the selection does not cover exactly one pure
// expression, when it is the target of an assignment, or when the statement it
// sits in cannot be located.
fn (app &App) build_extract_variable_action(uri string, content string, sel_range LSPRange) ?CodeAction {
	starts := line_start_offsets(content)
	mut start := position_to_byte_offset(content, starts, sel_range.start.line, sel_range.start.char,
		app.position_encoding)
	mut end := start
	if sel_range.end.line != sel_range.start.line || sel_range.end.char != sel_range.start.char {
		end = position_to_byte_offset(content, starts, sel_range.end.line, sel_range.end.char,
			app.position_encoding)
	}
	if end <= start || start < 0 || end > content.len {
		return none
	}
	masked := masked_v_code(content)
	for start < end && masked[start] in [` `, `\t`, `\r`, `\n`] {
		start++
	}
	for end > start && masked[end - 1] in [` `, `\t`, `\r`, `\n`] {
		end--
	}
	if end <= start {
		return none
	}
	stmt_start := assist_statement_start(masked, starts, start)
	if stmt_start < 0 || stmt_start > start {
		return none
	}
	// The left of an assignment is not a value: binding `extracted_0 := x` in
	// front of `x := f(x)` would read x before it is written. An index inside the
	// target is not itself the target: `arr[i] = 1` assigns to arr, not to i.
	if assist_selection_is_assignment_target(masked, stmt_start, start, end) {
		return none
	}
	receivers := assist_pure_expression(masked[start..end]) or { return none }
	for receiver in receivers {
		if !assist_binding_exists_before(masked, receiver, start) {
			return none
		}
	}
	// The base of a longer selector is only a value when it is a local: `math`
	// in `math.pi` names a module, which no variable can hold.
	if end < masked.len && masked[end] == `.` {
		base := assist_identifier_at(masked, start) or { return none }
		if !assist_binding_exists_before(masked, base, start) {
			return none
		}
	}
	name := assist_fresh_extract_name(content, app.position_encoding)
	stmt_line := assist_line_of(starts, stmt_start)
	insert_at := byte_offset_to_position(content, starts[stmt_line], app.position_encoding)
	indent := line_indent(line_text_without_terminator(content, starts, stmt_line))
	return CodeAction{
		title: 'Extract variable'
		kind:  code_action_kind_quickfix
		edit:  WorkspaceEdit{
			changes: {
				uri: [
					TextEdit{
						range:    LSPRange{
							start: insert_at
							end:   insert_at
						}
						new_text: indent + 'mut ${name} := ' + content[start..end] + '\n'
					},
					TextEdit{
						range:    LSPRange{
							start: byte_offset_to_position(content, start, app.position_encoding)
							end:   byte_offset_to_position(content, end, app.position_encoding)
						}
						new_text: name
					},
				]
			}
		}
	}
}

// assist_statement_start returns the byte offset at which the statement holding
// `probe` begins, or -1 when no statement can be located for it. A `;`, a brace
// or a `:` at bracket depth zero opens a later statement on the same line, and
// the lines the statement continues from are absorbed before that. A statement
// that begins in the middle of its line is refused: a declaration cannot be
// written in front of a `case` arm or an `else` without leaving its block.
fn assist_statement_start(masked string, starts []int, probe int) int {
	if probe < 0 || probe >= masked.len {
		return -1
	}
	mut line := assist_line_of(starts, probe)
	for line > 0 && assist_line_continues_previous(masked, starts, line - 1) {
		line--
	}
	mut stmt := starts[line] + line_indent(line_text_without_terminator(masked, starts, line)).len
	stop := assist_statement_separator(masked, stmt, probe)
	if probe < assist_line_end(masked.len, starts, line) && stop >= 0 {
		stmt = stop
	}
	stmt_line := assist_line_of(starts, stmt)
	if stmt != starts[stmt_line] + line_indent(line_text_without_terminator(masked, starts,
		stmt_line)).len {
		return -1
	}
	if assist_line_takes_no_declaration(line_text_without_terminator(masked, starts, stmt_line)) {
		return -1
	}
	return stmt
}

// assist_line_continues_previous reports whether `prev_line` is a line the next
// one continues: empty, or ending on a token that needs a right operand.
fn assist_line_continues_previous(masked string, starts []int, prev_line int) bool {
	trimmed := line_text_without_terminator(masked, starts, prev_line).trim_space()
	if trimmed == '' {
		return true
	}
	return trimmed[trimmed.len - 1] in [`,`, `.`, `(`, `[`, `+`, `-`, `*`, `/`, `%`, `&`, `|`,
		`^`, `<`, `>`, `=`, `!`, `?`]
}

// assist_statement_separator returns the byte offset just past the `;`, brace or
// `:` at bracket depth zero in [from, to), or -1 when there is none. Each of
// those opens a statement that is not the one starting at `from`.
fn assist_statement_separator(masked string, from int, to int) int {
	mut depth := 0
	for i in from .. to {
		c := masked[i]
		if c == `(` || c == `[` {
			depth++
			continue
		}
		if c == `)` || c == `]` {
			if depth > 0 {
				depth--
			}
			continue
		}
		if c == `}` {
			if depth == 0 {
				return i + 1
			}
			depth--
			continue
		}
		if (c == `;` || c == `:`) && depth == 0 {
			return i + 1
		}
	}
	return -1
}

// assist_line_takes_no_declaration reports whether a declaration can be written
// in front of the statement on `line`: never for a blank line, and never for a
// line beginning with a token that only continues a block — `}`, `else` or
// `case` — because the declaration would then move out of the block that holds
// it.
fn assist_line_takes_no_declaration(line string) bool {
	trimmed := line.trim_space()
	return trimmed == '' || trimmed.starts_with('}') || trimmed.starts_with('else')
		|| trimmed.starts_with('case ')
}

// assist_selection_is_assignment_target reports whether the selection sits on
// the left of an assignment: `x = 1`, `x += 1` and `x := 1` all bind x, so
// extracting x would bind a name to a value that is not in scope yet. The `==`
// of a comparison, and the `<=`, `>=` and `!=` that share its byte, are not
// assignments. An expression inside a bracketed index is not the target either:
// `arr[i] = 1` assigns to arr, not to i.
fn assist_selection_is_assignment_target(masked string, stmt_start int, sel_start int, sel_end int) bool {
	mut line_end := stmt_start
	for line_end < masked.len && masked[line_end] != `\n` {
		line_end++
	}
	mut depth := 0
	mut sel_depth := 0
	mut operator := -1
	for i in stmt_start .. line_end {
		c := masked[i]
		if i == sel_start {
			sel_depth = depth
		}
		if c == `(` || c == `[` || c == `{` {
			depth++
			continue
		}
		if c == `)` || c == `]` || c == `}` {
			if depth > 0 {
				depth--
			}
			continue
		}
		if depth != 0 || c != `=` {
			continue
		}
		if i + 1 < line_end && masked[i + 1] == `=` {
			return false
		}
		if i > 0 && masked[i - 1] in [`<`, `>`, `!`] {
			return false
		}
		operator = i
		break
	}
	if operator < 0 {
		return false
	}
	return sel_depth == 0 && sel_end <= operator
}

// assist_fresh_extract_name returns the first `extracted_N` that no identifier
// in `content` already uses, so the new name cannot capture an existing binding.
fn assist_fresh_extract_name(content string, enc PositionEncoding) string {
	used := extract_identifier_occurrences(content, enc)
	mut n := 0
	for 'extracted_${n}' in used {
		n++
	}
	return 'extracted_${n}'
}

// assist_binding_exists_before reports whether `name` is bound before `offset`,
// either by a `name :=` declaration or as a parameter of the enclosing function.
// That is what makes it a *local*, and therefore the only kind of receiver a
// call chain on it can be trusted not to have side effects.
fn assist_binding_exists_before(masked string, name string, offset int) bool {
	mut i := 0
	for i < offset {
		if i + name.len <= masked.len && masked[i..i + name.len] == name
			&& (i == 0 || !is_ident_char(masked[i - 1]))
			&& (i + name.len == masked.len || !is_ident_char(masked[i + name.len])) {
			mut k := i + name.len
			for k < offset && (masked[k] == ` ` || masked[k] == `\t`) {
				k++
			}
			if k + 1 < masked.len && masked[k] == `:` && masked[k + 1] == `=` {
				return true
			}
		}
		i++
	}
	return assist_fn_parameter_before(masked, name, offset)
}

// assist_fn_parameter_before reports whether `name` is a parameter of the
// function enclosing `offset`. A call chain on a parameter is exactly as pure
// as one on a `:=` local, so refusing it would refuse the commonest case there
// is: `s.len()` inside `fn f(s string)`.
fn assist_fn_parameter_before(masked string, name string, offset int) bool {
	fn_index := last_fn_keyword_index(masked[..offset])
	if fn_index < 0 {
		return false
	}
	mut open := fn_index
	for open < offset && masked[open] != `(` {
		open++
	}
	if open >= offset {
		return false
	}
	close := matching_delimiter(masked, open, `(`, `)`)
	if close < 0 || close >= offset {
		return false
	}
	for param in masked[open + 1..close].split(',') {
		mut token := param.trim_space()
		if token.starts_with('mut ') {
			token = token[4..].trim_space()
		}
		if token.all_before(' ').all_before('\t') == name {
			return true
		}
	}
	return false
}

// assist_identifier_at returns the identifier covering byte `offset`, or none
// when that byte is not inside one.
fn assist_identifier_at(text string, offset int) ?string {
	if offset < 0 || offset >= text.len {
		return none
	}
	mut end := offset
	for end < text.len && is_ident_char(text[end]) {
		end++
	}
	mut start := offset
	for start > 0 && is_ident_char(text[start - 1]) {
		start--
	}
	if start == end {
		return none
	}
	name := text[start..end]
	if !is_valid_v_identifier_name(name) {
		return none
	}
	return name
}

// assist_line_of returns the index of the line holding byte `offset`.
fn assist_line_of(starts []int, offset int) int {
	mut line := 0
	for line + 1 < starts.len && starts[line + 1] <= offset {
		line++
	}
	return line
}

// assist_line_end returns the byte offset at which the terminator of `line`
// begins, which is also where the next line starts.
fn assist_line_end(text_len int, starts []int, line int) int {
	return if line + 1 < starts.len { starts[line + 1] } else { text_len }
}

// assist_block_end_line returns the first line after `decl_line` whose
// indentation comes back in above the declaration's, or the line count when
// nothing brings it back. That closing line is the brace of the block the local
// was declared in, so everything from it on belongs to another scope.
fn assist_block_end_line(content string, starts []int, decl_line int, decl_indent int) int {
	mut i := decl_line + 1
	for i < starts.len {
		if line_indent(line_text_without_terminator(content, starts, i)).len < decl_indent {
			return i
		}
		i++
	}
	return starts.len
}

// --- Inline variable ---

// AssistInline is a local that can be folded back into its uses: the name it
// binds, the expression it was bound to, the line declaring it, and every use
// the expression replaces.
struct AssistInline {
	name      string
	expr      string
	decl_line int
	uses      []TokenOccurrence
}

// build_inline_variable_action returns the "Inline variable" quick fix for the
// local the cursor or range sits on: the declaration line is removed and every
// later use of the name is replaced by the expression it was bound to. It is
// refused unless the name is declared `name := expr` on a line of its own and is
// never assigned or rebound afterwards, since a second writing of the
// identifier would have to be reordered to inline it.
fn (app &App) build_inline_variable_action(uri string, content string, sel_range LSPRange) ?CodeAction {
	inline := app.inline_variable_span(content, sel_range) or { return none }
	enc := app.position_encoding
	starts := line_start_offsets(content)
	decl_end := assist_line_end(content.len, starts, inline.decl_line)
	mut edits := []TextEdit{}
	// The whole line goes, terminator included, so no blank line is left where
	// the declaration was. The final line of a file without a terminator is
	// ended by the last character instead of the start of a line that does not
	// exist, which some clients reject as an out-of-range edit.
	edits << TextEdit{
		range:    LSPRange{
			start: Position{
				line: inline.decl_line
				char: 0
			}
			end:   if inline.decl_line + 1 < starts.len {
				Position{
					line: inline.decl_line + 1
					char: 0
				}
			} else {
				byte_offset_to_position(content, decl_end, enc)
			}
		}
		new_text: ''
	}
	for use in inline.uses {
		line_text := line_text_without_terminator(content, starts, use.line)
		start := starts[use.line] + encoded_col_to_byte(line_text, use.start_char, enc)
		end := starts[use.line] + encoded_col_to_byte(line_text, use.end_char, enc)
		edits << TextEdit{
			range:    LSPRange{
				start: byte_offset_to_position(content, start, enc)
				end:   byte_offset_to_position(content, end, enc)
			}
			new_text: inline.expr
		}
	}
	return CodeAction{
		title: 'Inline variable'
		kind:  code_action_kind_quickfix
		edit:  WorkspaceEdit{
			changes: {
				uri: edits
			}
		}
	}
}

// inline_variable_span resolves the local under `sel_range` into the
// declaration, the uses and the reassignment verdict, or none when the cursor is
// not on a local that can be folded back into its uses.
fn (app &App) inline_variable_span(content string, sel_range LSPRange) ?AssistInline {
	starts := line_start_offsets(content)
	start := position_to_byte_offset(content, starts, sel_range.start.line, sel_range.start.char,
		app.position_encoding)
	mut end := start
	if sel_range.end.line != sel_range.start.line || sel_range.end.char != sel_range.start.char {
		end = position_to_byte_offset(content, starts, sel_range.end.line, sel_range.end.char,
			app.position_encoding)
	}
	masked := masked_v_code(content)
	mut selected := ''
	if end > start {
		candidate := content[start..end].trim_space()
		if is_valid_v_identifier_name(candidate) {
			selected = candidate
		}
	}
	name := if selected != '' {
		selected
	} else {
		assist_identifier_at(masked, start) or { return none }
	}
	if name in assist_non_value_keywords {
		return none
	}
	decl_line := assist_declaration_line(content, masked, starts, name,
		assist_line_of(starts, start))
	if decl_line < 0 {
		return none
	}
	expr := assist_line_declaration(content, masked, starts, decl_line, name) or { return none }
	// An expression that mentions the name being removed would keep a reference
	// to a binding that no longer exists.
	if name in extract_identifier_occurrences(expr, app.position_encoding) {
		return none
	}
	mut uses := []TokenOccurrence{}
	// A local lives inside the block that declares it, and in a Go-shaped file
	// that block ends where the indentation comes back in. A same-named local
	// further down the file belongs to another scope, so it keeps its name.
	decl_indent := line_indent(line_text_without_terminator(content, starts, decl_line)).len
	block_end := assist_block_end_line(content, starts, decl_line, decl_indent)
	for occurrence in extract_identifier_occurrences(content, app.position_encoding)[name] or {
		return none
	} {
		if occurrence.line <= decl_line || occurrence.line >= block_end {
			continue
		}
		line_text := line_text_without_terminator(content, starts, occurrence.line)
		use_start := starts[occurrence.line] + encoded_col_to_byte(line_text, occurrence.start_char,
			app.position_encoding)
		use_end := starts[occurrence.line] + encoded_col_to_byte(line_text, occurrence.end_char,
			app.position_encoding)
		if assist_is_reassignment(masked, use_end) {
			return none
		}
		// A field of another object (`obj.x`), a struct field initialiser or a
		// label (`x:`), and a declaration of some other `x` (`x int` in a struct
		// body or a parameter list) are not uses of this local, and inlining
		// them would rewrite a different symbol.
		if !assist_is_use(masked, use_start, use_end) {
			continue
		}
		uses << occurrence
	}
	if uses.len == 0 {
		return none
	}
	return AssistInline{
		name:      name
		expr:      expr
		decl_line: decl_line
		uses:      uses
	}
}

// assist_declaration_line returns the line of the `name := expr` declaration
// the cursor's `line` can see, searching upwards from it, or -1 when it has
// none. The first match wins, so a use further down a file inlines the nearest
// declaration above it.
fn assist_declaration_line(content string, masked string, starts []int, name string, line int) int {
	mut i := line
	for i >= 0 {
		if _ := assist_line_declaration(content, masked, starts, i, name) {
			return i
		}
		i--
	}
	return -1
}

// assist_line_declaration returns the expression `name` is bound to by the
// `name := expr` declaration that is the whole code of `line`, or none when that
// line does not declare it. A line shared with other code, a multi-target
// declaration, a re-binding with `=` and a trailing comment are all refused: a
// deletion of that line would take the other code, or the comment, with it.
fn assist_line_declaration(content string, masked string, starts []int, line int, name string) ?string {
	masked_line := line_text_without_terminator(masked, starts, line)
	mut pos := line_indent(masked_line).len
	if word := assist_word_at(masked_line, pos) {
		if word == 'mut' {
			pos += word.len
			for pos < masked_line.len && masked_line[pos] in [` `, `\t`] {
				pos++
			}
		}
	}
	bound := assist_word_at(masked_line, pos) or { return none }
	if bound != name {
		return none
	}
	pos += bound.len
	for pos < masked_line.len && masked_line[pos] in [` `, `\t`] {
		pos++
	}
	if pos + 1 >= masked_line.len || masked_line[pos] != `:` || masked_line[pos + 1] != `=` {
		return none
	}
	pos += 2
	// The expression is read from the unmasked line: the mask blanks string
	// bodies, and the binding would then carry a blank string instead of the
	// value the file holds. With no comment on the line the two lines agree on
	// where the expression ends, because a mask only ever turns bytes into
	// spaces.
	expr := line_text_without_terminator(content, starts, line)[pos..].trim_space()
	if expr == '' {
		return none
	}
	if assist_comment_offset(line_text_without_terminator(content, starts, line)) >= 0 {
		return none
	}
	return expr
}

// assist_word_at returns the identifier starting at byte `pos`, or none when
// none starts there.
fn assist_word_at(text string, pos int) ?string {
	mut i := pos
	for i < text.len && is_ident_char(text[i]) {
		i++
	}
	if i == pos {
		return none
	}
	return text[pos..i]
}

// assist_comment_offset returns the offset of the `//` that starts a comment on
// `text`, or -1 when the line has none. String bodies are skipped, so a `//` in
// a literal is not mistaken for the start of one.
fn assist_comment_offset(text string) int {
	mut quote := u8(0)
	mut i := 0
	for i < text.len {
		c := text[i]
		if quote != 0 {
			if c == `\\` {
				i += 2
				continue
			}
			if c == quote {
				quote = 0
			}
			i++
			continue
		}
		if c == `"` || c == `'` || c == 96 {
			quote = c
			i++
			continue
		}
		if c == `/` && i + 1 < text.len && text[i + 1] == `/` {
			return i
		}
		i++
	}
	return -1
}

// assist_is_reassignment reports whether the identifier ending at `end` is
// followed by an assignment: `x = 1`, `x += 1` and `x := 1` all write x, and a
// use that writes the name being inlined would have to be reordered with the
// declaration the edit removes. A `==` compares, and the `<=`, `>=`, `!=`,
// `<<=` and `>>=` that share its operator bytes are told apart by what follows
// the pair.
fn assist_is_reassignment(masked string, end int) bool {
	mut k := end
	for k < masked.len && masked[k] in [` `, `\t`] {
		k++
	}
	if k >= masked.len {
		return false
	}
	c := masked[k]
	if c == `=` {
		return !(k + 1 < masked.len && masked[k + 1] == `=`)
	}
	if c == `:` {
		return k + 1 < masked.len && masked[k + 1] == `=`
	}
	if c == `<` || c == `>` {
		return k + 1 < masked.len && masked[k + 1] == c
	}
	return c in [`+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`]
		&& k + 1 < masked.len && masked[k + 1] == `=`
}

// assist_is_use reports whether the identifier occupying [start, end) is a value
// use of it rather than the same name belonging to something else: a field
// access (`obj.x`), a field initialiser or a label (`x:`), and a declaration of
// a different `x` (`x int` in a struct body or a parameter list) all keep the
// name and are left alone.
fn assist_is_use(masked string, start int, end int) bool {
	if start > 0 && (is_ident_char(masked[start - 1]) || masked[start - 1] == `.`) {
		return false
	}
	if end < masked.len {
		if is_ident_char(masked[end]) || masked[end] == `:` {
			return false
		}
		mut k := end
		for k < masked.len && masked[k] in [` `, `\t`] {
			k++
		}
		if k < masked.len && is_ident_char(masked[k]) {
			return false
		}
	}
	return true
}
