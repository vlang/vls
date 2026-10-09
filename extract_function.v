// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

// Extract function: lift whole statements out of a function into a new one.
//
// The refactor is textual, over the same masked buffer the fill-struct and
// extract-variable assists use: comments and string bodies are blanked, so no
// scan steps on a brace or an identifier inside them, and every offset it
// reports addresses the original bytes. It knows nothing about types beyond
// what a declaration line in the file states, and it refuses rather than
// guessing — a wrong parameter list is worse than no action.

// ByteRange is a half-open byte range of the buffer.
struct ByteRange {
	start int
	end   int
}

// ExtractFnFrame is the function that encloses a selection: where its
// declaration starts, the indentation of its body, and the names it declares
// with the types their declarations state.
struct ExtractFnFrame {
	decl_line   int
	body_indent string
	params      map[string]string
	locals      map[string]string
}

// extract_fn_frame returns the function whose body holds the byte `offset`,
// or none when the offset is outside every function body. Braces are walked
// over the masked buffer, so a brace inside a string never shifts the depth.
fn (app &App) extract_fn_frame(content string, masked string, starts []int, offset int) ?ExtractFnFrame {
	mut stack := []int{}
	mut line := 0
	for i := 0; i < masked.len && i < offset; i++ {
		if masked[i] == `\n` {
			line++
			continue
		}
		if masked[i] == `{` {
			stack << i
		} else if masked[i] == `}` {
			if stack.len > 0 {
				stack.pop()
			}
		}
	}
	if stack.len == 0 {
		return none
	}
	open_off := stack.last()
	open_line := byte_to_line_number(starts, open_off)
	open_text := line_text_of(content, starts, open_line).trim_space()
	decl_line := if open_text.starts_with('fn ') {
		open_line
	} else {
		above := declaration_line_above(content, starts, open_line) or { return none }
		above
	}
	sel_line := byte_to_line_number(starts, offset)
	if sel_line == decl_line {
		return none
	}
	return app.parse_extract_fn_frame(content, decl_line)
}

// parse_extract_fn_frame reads the declaration line's parameters and the
// locals its body declares, the only types this refactor trusts.
fn (app &App) parse_extract_fn_frame(content string, decl_line int) ?ExtractFnFrame {
	lines := content.split_into_lines()
	signature := lines[decl_line]
	mut params := map[string]string{}
	popen := signature.index('(') or { -1 }
	if popen >= 0 {
		params = extract_signature_params(signature[popen + 1..])
	}
	return ExtractFnFrame{
		decl_line:   decl_line
		body_indent: line_indent(signature) + '\t'
		params:      params
		locals:      extract_fn_locals(lines, decl_line)
	}
}

// extract_signature_params reads `mut name Type, other bool` into a map of
// name to type text. A parameter without a type is recorded with an empty
// type, which refuses the refactor later.
fn extract_signature_params(text string) map[string]string {
	mut params := map[string]string{}
	mut depth := 0
	mut start := 0
	bytes := text.bytes()
	for idx := 0; idx < bytes.len; idx++ {
		c := bytes[idx]
		if c == `(` || c == `[` || c == `{` {
			depth++
		} else if c == `)` {
			if depth == 0 {
				insert_param(mut params, text[start..idx])
				break
			}
			depth--
		} else if c == `]` || c == `}` {
			depth--
		} else if c == `,` && depth == 0 {
			insert_param(mut params, text[start..idx])
			start = idx + 1
		}
	}
	return params
}

// insert_param records one parameter of the form `mut name Type` or `name`.
fn insert_param(mut params map[string]string, text string) {
	words := text.all_before('//').trim_space().fields()
	if words.len == 0 {
		return
	}
	mut idx := 0
	if words[0] in ['mut', 'shared', 'static'] {
		idx = 1
	}
	if idx >= words.len {
		return
	}
	params[words[idx]] = words[idx + 1..].join(' ')
}

// extract_fn_locals collects the locals a function body declares, with the
// type the declaration states. Only the forms whose type is written down are
// kept; a name this cannot type is absent, which refuses the refactor.
fn extract_fn_locals(lines []string, decl_line int) map[string]string {
	mut locals := map[string]string{}
	decl_indent := line_indent(lines[decl_line])
	for idx := decl_line + 1; idx < lines.len; idx++ {
		text := lines[idx]
		trimmed := text.trim_space()
		if trimmed.starts_with('}') && line_indent(text) == decl_indent {
			break
		}
		if trimmed == '' {
			continue
		}
		// `name := expr` and `mut name := expr`
		op := trimmed.index(' := ') or { -1 }
		if op > 0 {
			lhs := trimmed[..op].trim_space().trim_string_left('mut ').trim_space()
			if is_plain_identifier(lhs) {
				ltype := extract_inferred_type(trimmed[op + 4..].trim_space())
				if ltype != '' {
					locals[lhs] = ltype
				}
			}
			continue
		}
		// `mut name Type` and `mut name = expr`
		if trimmed.starts_with('mut ') {
			rest := trimmed[4..].trim_space()
			space := rest.index(' ') or { -1 }
			if space > 0 {
				lhs := rest[..space]
				tail := rest[space + 1..].trim_space()
				if is_plain_identifier(lhs) {
				if tail.starts_with('=') {
					stype := extract_inferred_type(tail[1..].trim_space())
					if stype != '' {
						locals[lhs] = stype
					}
				} else if is_type_text(tail) {
						locals[lhs] = tail
					}
				}
			}
		}
	}
	return locals
}

// extract_inferred_type names the type of a simple right-hand side, or '' when
// the type is not written on the line.
fn extract_inferred_type(rhs string) string {
	r := rhs.trim_space()
	if r == '' {
		return ''
	}
	first := r[0]
	if first == `'` || first == `"` || first == `$` {
		return 'string'
	}
	if r.starts_with('r\'') || r.starts_with('r\"') {
		return 'string'
	}
	if r == 'true' || r == 'false' {
		return 'bool'
	}
	if r.starts_with('[]') && r.contains('{') {
		return r.all_before('{').trim_space()
	}
	if r.starts_with('%{') {
		return 'string'
	}
	digits := r.replace('.', '')
	if decimal_text_is_valid(r) {
		return 'int'
	}
	if r.contains('.') && decimal_text_is_valid(digits) {
		return 'f64'
	}
	return ''
}

// is_type_text reports whether `text` reads as a type expression: words,
// brackets and dots, with no call or operator in it.
fn is_type_text(text string) bool {
	t := text.trim_space()
	if t == '' {
		return false
	}
	for c in t {
		if is_ident_char(c) || c == ` ` || c == `[` || c == `]` || c == `.` || c == `&` {
			continue
		}
		return false
	}
	return is_ident_char(t[0])
}

// is_plain_identifier reports whether `name` is a single V identifier.
fn is_plain_identifier(name string) bool {
	if name == '' {
		return false
	}
	if !is_ident_char(name[0]) || (name[0] >= `0` && name[0] <= `9`) {
		return false
	}
	for c in name {
		if !is_ident_char(c) {
			return false
		}
	}
	return true
}

// line_text_of returns one line of `content`.
fn line_text_of(content string, starts []int, line int) string {
	if line < 0 || line >= starts.len {
		return ''
	}
	from := starts[line]
	to := if line + 1 < starts.len { starts[line + 1] } else { content.len }
	return content[from..to]
}

// declaration_line_above finds the `fn` declaration line directly above the
// body-opening line.
fn declaration_line_above(content string, starts []int, open_line int) ?int {
	for idx := open_line - 1; idx >= 0 && idx >= open_line - 2; idx-- {
		if line_text_of(content, starts, idx).trim_space().starts_with('fn ') {
			return idx
		}
	}
	return none
}

// byte_to_line_number maps a byte offset to its line.
fn byte_to_line_number(starts []int, offset int) int {
	mut lo := 0
	mut hi := starts.len - 1
	if hi < 0 {
		return 0
	}
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if starts[mid] <= offset {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// extract_identifiers returns every identifier in masked[start:end), as byte
// ranges of the original buffer. A number is not an identifier, even though
// its digits are identifier characters.
fn extract_identifiers(masked string, start int, end int) []ByteRange {
	mut out := []ByteRange{}
	mut i := start
	for i < end {
		if !is_ident_char(masked[i]) {
			i++
			continue
		}
		s := i
		for i < end && is_ident_char(masked[i]) {
			i++
		}
		if masked[s] >= `0` && masked[s] <= `9` {
			continue
		}
		out << ByteRange{
			start: s
			end:   i
		}
	}
	return out
}

// extract_prev_nonspace returns the last non-space byte at or before `i`.
fn extract_prev_nonspace(s string, i int) u8 {
	mut j := i
	for j >= 0 {
		if s[j] != ` ` && s[j] != `\t` {
			return s[j]
		}
		j--
	}
	return u8(0)
}

// extract_next_nonspace returns the first non-space byte at or after `i`.
fn extract_next_nonspace(s string, i int) u8 {
	for j := i; j < s.len; j++ {
		if s[j] != ` ` && s[j] != `\t` {
			return s[j]
		}
	}
	return u8(0)
}

// extract_is_assignment reports whether the identifier ending at `end` is the
// target of an assignment rather than a comparison or a compound operator.
fn extract_is_assignment(masked string, end int) bool {
	mut j := end
	for j < masked.len && (masked[j] == ` ` || masked[j] == `\t`) {
		j++
	}
	if j >= masked.len || masked[j] != `=` {
		return false
	}
	if j + 1 < masked.len && masked[j + 1] == `=` {
		return false
	}
	if j > 0 && (masked[j - 1] == `=` || masked[j - 1] == `!` || masked[j - 1] == `<`
		|| masked[j - 1] == `>` || masked[j - 1] == `+` || masked[j - 1] == `-`
		|| masked[j - 1] == `*` || masked[j - 1] == `/` || masked[j - 1] == `%`) {
		return false
	}
	return true
}

// build_extract_function_action is the "Extract function" quick fix for the
// statements the range covers. It returns none unless the selection is one or
// more whole statements inside one function body, every name the new function
// needs has a type written in the file, at most one enclosing local is
// reassigned (which becomes the return value), and the selection holds no
// `return` of the enclosing function.
fn (mut app App) build_extract_function_action(uri string, content string, sel_range LSPRange) ?CodeAction {
	// `uri` keeps the signature the other assists share; the range and the
	// authoritative buffer passed in are what decide.
	_ = uri
	masked := masked_v_code(content)
	starts := line_start_offsets(content)
	byte_start := position_to_byte_offset(content, starts, sel_range.start.line, sel_range.start.char,
		app.position_encoding)
	mut byte_end := byte_start
	if sel_range.end.line != sel_range.start.line || sel_range.end.char != sel_range.start.char {
		byte_end = position_to_byte_offset(content, starts, sel_range.end.line, sel_range.end.char,
			app.position_encoding)
	}
	if byte_end <= byte_start || byte_start < 0 || byte_end > content.len {
		return none
	}
	sel_start_line := byte_to_line_number(starts, byte_start)
	sel_end_line := byte_to_line_number(starts, byte_end)
	if sel_end_line < sel_start_line {
		return none
	}
	lines := content.split_into_lines()
	// Whole lines only: nothing but indentation before the selection on its
	// first line, nothing but whitespace after it on the last one.
	head := line_text_of(content, starts, sel_start_line)
	head_text := head[..byte_start - starts[sel_start_line]]
	if head_text.trim_space() != '' {
		return none
	}
	tail := line_text_of(content, starts, sel_end_line)
	tail_text := tail[byte_end - starts[sel_end_line]..]
	if tail_text.trim_space() != '' {
		return none
	}
	for cand_idx in sel_start_line .. sel_end_line + 1 {
		trimmed := lines[cand_idx].trim_space()
		if trimmed == '' {
			continue
		}
		if trimmed.starts_with('}') || trimmed.starts_with('else') || trimmed.starts_with('case ')
			|| trimmed.starts_with('default:') {
			return none
		}
	}
	frame := app.extract_fn_frame(content, masked, starts, byte_start)?
	if frame.decl_line >= sel_start_line {
		return none
	}
	if sel_end_line > extract_body_end_line(masked, starts, byte_start, byte_end) {
		return none
	}
	ids := extract_identifiers(masked, byte_start, byte_end)
	declared_inside, assigned_inside := extract_bindings_in_selection(content, lines, starts, ids)
	mut params := map[string]string{}
	mut param_order := []string{}
	mut assigned_outside := []string{}
	for id in ids {
		name := content[id.start..id.end]
		if name in declared_inside {
			continue
		}
		prev := extract_prev_nonspace(masked, id.start - 1)
		next := extract_next_nonspace(masked, id.end)
		if prev == `.` {
			continue
		}
		in_frame := name in frame.params || name in frame.locals
		if !in_frame && (next == `(` || next == `[`) {
			// A call or an index on a name this file does not declare: a
			// function or type of the module, visible to both.
			continue
		}
		if name in frame.params {
			if name !in params {
				params[name] = frame.params[name]
				param_order << name
			}
			continue
		}
		if name in frame.locals {
			// A local the selection reassigns is a return value, not an input:
			// passing it in and returning it would say the same thing twice.
			if name in assigned_inside && name !in assigned_outside {
				assigned_outside << name
			} else if name !in params {
				params[name] = frame.locals[name]
				param_order << name
			}
			continue
		}
		// A name the file does not declare with a type: nothing trustworthy
		// to pass.
		return none
	}
	for _, ptype in params {
		if ptype == '' {
			return none
		}
	}
	// A parameter of the enclosing function reassigned inside the selection
	// cannot be lifted: the caller would keep its own value.
	for name, _ in assigned_inside {
		if name in frame.params {
			return none
		}
	}
	if assigned_outside.len > 1 {
		return none
	}
	mut return_type := ''
	if assigned_outside.len == 1 {
		name := assigned_outside[0]
		return_type = frame.locals[name]
		if return_type == '' {
			return none
		}
	}
	// A `return` that targets the enclosing function cannot be lifted.
	for id in ids {
		if content[id.start..id.end] == 'return' {
			return none
		}
	}
	fn_name := fresh_extracted_fn_name(content)
	mut signature := []string{}
	for name in param_order {
		signature << '${name} ${params[name]}'
	}
	body := extract_selected_lines(content, starts, sel_start_line, sel_end_line, frame.body_indent)
	mut fn_text := 'fn ${fn_name}('
	fn_text += signature.join(', ')
	fn_text += ')'
	if return_type != '' {
		fn_text += ' ${return_type}'
	}
	fn_text += ' {\n'
	fn_text += body
	if return_type != '' {
		fn_text += '${frame.body_indent}return ${assigned_outside[0]}\n'
	}
	fn_text += '}\n\n'
	call := '${fn_name}(' + param_order.join(', ') + ')'
	return CodeAction{
		title:        'Extract function'
		kind:         code_action_kind_quickfix
		is_preferred: true
		edit:         WorkspaceEdit{
			changes: {
				'': [
					TextEdit{
						range:    LSPRange{
							start: Position{
								line: frame.decl_line
								char: 0
							}
							end:   Position{
								line: frame.decl_line
								char: 0
							}
						}
						new_text: fn_text
					},
					TextEdit{
						range:    LSPRange{
							start: encoded_position(content, starts, byte_start, app.position_encoding)
							end:   encoded_position(content, starts, byte_end, app.position_encoding)
						}
						new_text: call
					},
				]
			}
		}
	}
}

// extract_bindings_in_selection returns the names the selection declares
// itself and the names it assigns, both found on declaration lines rather
// than from a scope analysis.
fn extract_bindings_in_selection(content string, lines []string, starts []int, ids []ByteRange) (map[string]bool, map[string]bool) {
	mut declared := map[string]bool{}
	mut assigned := map[string]bool{}
	for id in ids {
		name := content[id.start..id.end]
		line_idx := byte_to_line_number(starts, id.start)
		text := lines[line_idx]
		trimmed := text.trim_space()
		op := trimmed.index(' := ') or { -1 }
		if op > 0 {
			lhs := trimmed[..op].trim_space().trim_string_left('mut ').trim_space()
			if lhs == name {
				declared[name] = true
				continue
			}
		}
		if trimmed.starts_with('mut ') {
			rest := trimmed[4..].trim_space()
			space := rest.index(' ') or { -1 }
			if space > 0 && rest[..space] == name {
				declared[name] = true
				continue
			}
		}
		if extract_is_assignment(content, id.end) {
			assigned[name] = true
		}
	}
	return declared, assigned
}

// extract_body_end_line returns the line the enclosing body closes on, so a
// selection reaching past it is refused.
fn extract_body_end_line(masked string, starts []int, byte_start int, byte_end int) int {
	mut line := byte_to_line_number(starts, byte_start)
	mut depth := 0
	for i := byte_start; i < masked.len && i <= byte_end; i++ {
		if masked[i] == `{` {
			depth++
		} else if masked[i] == `}` {
			if depth == 0 {
				return line
			}
			depth--
		} else if masked[i] == `\n` {
			line++
		}
	}
	return line
}

// extract_selected_lines returns the selected statements, indented one level
// under `indent`.
fn extract_selected_lines(content string, starts []int, from_line int, to_line int, indent string) string {
	mut out := []string{}
	for line_idx in from_line .. to_line + 1 {
		text := line_text_of(content, starts, line_idx)
		if text.trim_space() == '' {
			continue
		}
		own := line_indent(text)
		stripped := text[own.len..]
		mut line := '${indent}${stripped}'
		if !line.ends_with('\n') {
			line += '\n'
		}
		out << line
	}
	return out.join('')
}

// fresh_extracted_fn_name returns the first `extracted_N` the file does not
// use.
fn fresh_extracted_fn_name(content string) string {
	for i in 0 .. 10000 {
		name := 'extracted_${i}'
		if !content.contains('fn ${name}(') {
			return name
		}
	}
	return 'extracted'
}

// encoded_position converts a byte offset into an LSP position in the
// negotiated encoding.
fn encoded_position(content string, starts []int, offset int, enc PositionEncoding) Position {
	line := byte_to_line_number(starts, offset)
	line_start := starts[line]
	column := byte_to_encoded_col(content[line_start..offset], offset - line_start, enc)
	return Position{
		line: line
		char: column
	}
}
