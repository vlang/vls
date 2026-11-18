// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// Move declaration to a new file: a top-level declaration lifted out of the
// file that holds it into a module of its own.
//
// The refactor is textual, over the same masked buffer the other assists use:
// comments and string bodies are blanked, so no scan is fooled by a brace or an
// identifier inside one, while every offset it reports still addresses the
// original bytes. It reads the buffer, the directory the file sits in and
// nothing else, and it refuses rather than guess — a declaration moved under
// the wrong module name, or into a file that already exists, is worse than no
// action at all.

// ETfDeclKind is one kind of top-level declaration the refactor can move.
enum ETfDeclKind {
	function       // `fn make()`, a method with a receiver included
	struct_type    // `struct Point {}`
	enum_type      // `enum Color {}`
	interface_type // `interface Reader {}`
	type_alias     // `type Handler = fn (int)`, `type Foo struct {}`
	const_block    // `const (` ... `)`, or a `const name = 1` of its own
}

// ETfDeclaration is one top-level declaration: the kind of declaration, the
// name it is declared under, the lines it spans, and where its first byte and
// its last one are in the buffer.
struct ETfDeclaration {
	kind         ETfDeclKind
	name         string
	start_line   int
	end_line     int
	start_offset int
	text_end     int
}

// ETfSpan is the extent of a declaration: the byte just past its last one, and
// the line that byte falls on.
struct ETfSpan {
	text_end int
	end_line int
}

// build_extract_to_file_action returns the "Move declaration to a new file"
// quick fix for the top-level declaration the selection covers: the
// declaration's lines are deleted from the file, `import <module>` is written
// where that file takes its imports, and a `<module>.v` beside it is created
// holding the declaration under `module <module>` of its own.
//
// It is refused when the selection is not exactly one whole declaration, when
// the declaration is `fn main` or the file is `module main` itself, when the
// declaration is a C block (`fn C.printf`), when the file's directory has no
// `v.mod` above it, when the name the new module would take is the module the
// file already is, and when both the file names that could hold the
// declaration are taken. The new module is the declaration's name lowercased,
// with an underscore where a word began in the upper case.
fn (mut app App) build_extract_to_file_action(uri string, content string, sel_range LSPRange) ?CodeAction {
	masked := masked_v_code(content)
	starts := line_start_offsets(content)
	byte_start := position_to_byte_offset(content, starts, sel_range.start.line, sel_range.start.char,
		app.position_encoding)
	mut byte_end := byte_start
	if sel_range.end.line != sel_range.start.line || sel_range.end.char != sel_range.start.char {
		byte_end = position_to_byte_offset(content, starts, sel_range.end.line, sel_range.end.char,
			app.position_encoding)
	}
	if byte_start < 0 || byte_end > content.len || byte_end < byte_start {
		return none
	}
	from, to := etf_trim_selection(content, byte_start, byte_end)
	if to <= from {
		return none
	}
	decl := etf_selected_declaration(masked, starts, from, to) or { return none }
	// `fn main` is where a program starts, and a program is the one file it is
	// in: moving the start away would leave that file with none.
	if decl.kind == .function && decl.name == 'main' {
		return none
	}
	// An attribute left behind would name nothing, so the block that moves is
	// the declaration and the attributes attached to it.
	block_start := etf_attribute_block_start(masked, starts, decl) or { return none }
	dir := os.dir(uri_to_path(uri))
	if dir == '' || dir == '/' {
		return none
	}
	// The new file is created beside the one the declaration is moved out of,
	// which only means anything when the directory is part of a project.
	if find_project_root(dir) == '' {
		return none
	}
	// A file of `module main` is a program rather than a module, and the module
	// being created must not be the one the file already is.
	current := etf_current_module(content)
	if current == 'main' {
		return none
	}
	module_name := etf_module_name(decl.name)
	if module_name == current {
		return none
	}
	file_name := etf_new_file_name(dir, module_name) or { return none }
	// The lines go, their terminator with them, so no blank line is left where
	// the declaration was. A declaration that ends the file is ended by its
	// last byte instead, because a client may reject a range naming a line that
	// does not exist.
	delete_end := if decl.end_line + 1 < starts.len {
		Position{
			line: decl.end_line + 1
			char: 0
		}
	} else {
		byte_offset_to_position(content, content.len, app.position_encoding)
	}
	return CodeAction{
		title: 'Move declaration to a new file'
		kind:  code_action_kind_quickfix
		edit:  WorkspaceEdit{
			changes:          {
				uri: [
					TextEdit{
						range:    LSPRange{
							start: Position{
								line: block_start
								char: 0
							}
							end:   delete_end
						}
						new_text: ''
					},
					import_spot(content).edit(module_name),
				]
			}
			document_changes: [
				TextDocumentEdit{
					text_document: OptionalVersionedTextDocumentIdentifier{
						uri:     path_to_uri(os.join_path(dir, file_name))
						version: json2.Any(json2.null)
					}
					edits:         [
						TextEdit{
							range:    LSPRange{
								start: Position{
									line: 0
									char: 0
								}
								end:   Position{
									line: 0
									char: 0
								}
							}
							new_text: etf_new_file_text(content, starts, block_start, decl, module_name)
						},
					]
				},
			]
		}
	}
}

// etf_current_module returns the module the file declares, which is `main`
// when it declares none.
fn etf_current_module(content string) string {
	declared := get_module_name(content)
	if declared == '' {
		return 'main'
	}
	return declared
}

// etf_module_name returns the module a declaration is named after: its name
// lowercased, with an underscore where a word began in the upper case
// (`UserService` becomes `user_service`). A name already written with them
// keeps them, so `parse_headers` stays `parse_headers`.
fn etf_module_name(name string) string {
	mut out := []u8{cap: name.len + 8}
	for idx in 0 .. name.len {
		c := name[idx]
		if c < `A` || c > `Z` {
			out << c
			continue
		}
		if out.len > 0 && out[out.len - 1] != `_` && etf_starts_a_word(name, idx) {
			out << `_`
		}
		out << c + 32
	}
	return out.bytestr()
}

// etf_starts_a_word reports whether the upper-case letter at `idx` begins a
// word: one after a lower-case letter or a digit (`userService`), or the last
// of a run of capitals that a lower-case letter follows (`HTTPServer`).
fn etf_starts_a_word(name string, idx int) bool {
	if idx == 0 {
		return false
	}
	prev := name[idx - 1]
	if prev >= `a` && prev <= `z` {
		return true
	}
	if prev >= `0` && prev <= `9` {
		return true
	}
	return prev >= `A` && prev <= `Z` && idx + 1 < name.len && name[idx + 1] >= `a`
		&& name[idx + 1] <= `z`
}

// etf_new_file_name returns the file the declaration is written to: the module
// name's own, or `<name>_ext.v` when that one is taken, and none when both
// are. The file the declaration is moved out of counts as taken, so a
// declaration named after its module always lands beside it with the suffix.
fn etf_new_file_name(dir string, module_name string) ?string {
	plain := '${module_name}.v'
	if !os.exists(os.join_path(dir, plain)) {
		return plain
	}
	extended := '${module_name}_ext.v'
	if !os.exists(os.join_path(dir, extended)) {
		return extended
	}
	return none
}

// etf_new_file_text returns the text of the file the declaration moves into:
// the module it belongs to from now on, a blank line, and the declaration as it
// was written — the attributes attached to it included.
fn etf_new_file_text(content string, starts []int, block_start int, decl ETfDeclaration, module_name string) string {
	mut text := 'module ${module_name}\n\n'
	last := decl.end_line + 1
	for idx in block_start .. last {
		text += line_text_of(content, starts, idx)
	}
	if !text.ends_with('\n') {
		text += '\n'
	}
	return text
}

// etf_trim_selection narrows the selected bytes to the text between them: the
// blanks an editor drags in at either end of a selection are not part of what
// it covers, so a selection reaching to the end of the line, or beginning on
// the blank one above, still covers the declaration between them.
fn etf_trim_selection(content string, from int, to int) (int, int) {
	mut start := from
	for start < to && content[start] in [` `, `\t`, `\r`, `\n`] {
		start++
	}
	mut end := to
	for end > start && content[end - 1] in [` `, `\t`, `\r`, `\n`] {
		end--
	}
	return start, end
}

// etf_selected_declaration returns the one top-level declaration the selection
// [from, to) covers exactly, or none when it covers none of them or part of
// one. A selection covering two of them is refused, because moving one would
// move only part of the other.
fn etf_selected_declaration(masked string, starts []int, from int, to int) ?ETfDeclaration {
	mut chosen := ETfDeclaration{}
	mut found := false
	for decl in etf_top_level_declarations(masked, starts) {
		if decl.start_offset == from {
			chosen = decl
			found = true
			break
		}
	}
	if !found {
		return none
	}
	if to < chosen.text_end {
		return none
	}
	line_end := if chosen.end_line + 1 < starts.len {
		starts[chosen.end_line + 1]
	} else {
		masked.len
	}
	if to > line_end {
		return none
	}
	// Only blanks may sit between the declaration's last byte and the end of
	// the selection: the mask turns a comment into blanks, so one trailing the
	// closing brace is part of the line and not more text.
	if masked[chosen.text_end..to].trim_space() != '' {
		return none
	}
	return chosen
}

// etf_top_level_declarations returns every top-level declaration in the buffer,
// in order, with the extent of each. They never nest, since the body of one is
// indented and a line opening one of its own is the next declaration, so the
// scan walks line by line and steps over the body it has just measured.
fn etf_top_level_declarations(masked string, starts []int) []ETfDeclaration {
	mut decls := []ETfDeclaration{}
	mut line := 0
	for line < starts.len {
		mut next := line + 1
		if k := etf_declaration_kind(masked, starts, line) {
			if span := etf_declaration_span(masked, starts, line, k) {
				next = span.end_line + 1
				if n := etf_declaration_name(masked, starts, line, k) {
					decls << ETfDeclaration{
						kind:         k
						name:         n
						start_line:   line
						end_line:     span.end_line
						start_offset: etf_line_offset(masked, starts, line)
						text_end:     span.text_end
					}
				}
			}
		}
		line = next
	}
	return decls
}

// etf_declaration_kind returns the kind of declaration `line` opens, or none
// when it opens nothing: a blank line, a continuation of another declaration
// (indented, because every body is), or one of the header's other words — a
// module line, an import, an attribute or a `#flag`.
fn etf_declaration_kind(masked string, starts []int, line int) ?ETfDeclKind {
	text := line_text_without_terminator(masked, starts, line)
	if line_indent(text) != '' {
		return none
	}
	match first_word(etf_after_pub(text.trim_space())) {
		'fn' { return .function }
		'struct' { return .struct_type }
		'enum' { return .enum_type }
		'interface' { return .interface_type }
		'type' { return .type_alias }
		'const' { return .const_block }
		else { return none }
	}
}

// etf_declaration_span returns the extent of the declaration `line` opens, or
// none when it opens nothing this can measure: a body brace that never closes,
// or a header that runs on past the next declaration.
fn etf_declaration_span(masked string, starts []int, line int, kind ETfDeclKind) ?ETfSpan {
	match kind {
		.function {
			// The parameter list comes first, so the body brace is the first
			// one after it: a brace inside a parameter type cannot be mistaken
			// for the body.
			open := etf_byte_after(masked, starts[line], `(`) or { return none }
			close := matching_delimiter(masked, open, `(`, `)`)
			if close < 0 {
				return none
			}
			return etf_braced_span(masked, starts, close + 1)
		}
		.struct_type, .enum_type, .interface_type, .type_alias {
			return etf_maybe_braced_span(masked, starts, line)
		}
		.const_block {
			return etf_maybe_paren_span(masked, starts, line)
		}
	}
}

// etf_braced_span measures a declaration that opens a body: the brace that
// follows `from`, matched to the one that closes it.
fn etf_braced_span(masked string, starts []int, from int) ?ETfSpan {
	open := etf_bounded_brace(masked, starts, from) or { return none }
	close := matching_delimiter(masked, open, `{`, `}`)
	if close < 0 {
		return none
	}
	return ETfSpan{
		text_end: close + 1
		end_line: byte_to_line_number(starts, close + 1)
	}
}

// etf_maybe_braced_span measures a declaration that may open a body: a struct
// type does, a type alias of a function or a plain type does not. One that
// opens none is measured to the end of its line.
fn etf_maybe_braced_span(masked string, starts []int, line int) ?ETfSpan {
	if open := etf_bounded_brace(masked, starts, starts[line]) {
		close := matching_delimiter(masked, open, `{`, `}`)
		if close < 0 {
			return none
		}
		return ETfSpan{
			text_end: close + 1
			end_line: byte_to_line_number(starts, close + 1)
		}
	}
	return etf_inline_span(masked, starts, line)
}

// etf_maybe_paren_span measures a `const`: a block is the parentheses after the
// keyword matched, a declaration of one is measured to the end of its line.
// Only a `(` directly after the keyword opens a block, so a `const n = f(1)`
// is a line and not one.
fn etf_maybe_paren_span(masked string, starts []int, line int) ?ETfSpan {
	from := etf_past_first_word_offset(masked, starts, line)
	if from < masked.len && masked[from] == `(` {
		close := matching_delimiter(masked, from, `(`, `)`)
		if close < 0 {
			return none
		}
		return ETfSpan{
			text_end: close + 1
			end_line: byte_to_line_number(starts, close + 1)
		}
	}
	return etf_inline_span(masked, starts, line)
}

// etf_inline_span measures a declaration that opens no bracket to the end of
// its line, or refuses it when the brackets on that line are not all closed
// there: a header that continues below is one this cannot follow. The extent
// ends at the last byte that is not blank, so a comment trailing it is covered
// by the line instead of being measured as part of it.
fn etf_inline_span(masked string, starts []int, line int) ?ETfSpan {
	text := line_text_without_terminator(masked, starts, line)
	mut depth := 0
	for c in text {
		if c == `(` || c == `[` || c == `{` {
			depth++
		} else if c == `)` || c == `]` || c == `}` {
			depth--
		}
	}
	if depth != 0 {
		return none
	}
	mut last := text.len
	for last > 0 && text[last - 1] in [` `, `\t`] {
		last--
	}
	return ETfSpan{
		text_end: starts[line] + last
		end_line: line
	}
}

// etf_bounded_brace returns the offset of the first brace at or after `from`,
// or none when a line opening a declaration of its own comes first: a header
// cannot run on past one of those.
fn etf_bounded_brace(masked string, starts []int, from int) ?int {
	mut i := from
	for i < masked.len {
		if masked[i] == `{` {
			return i
		}
		if masked[i] == `\n`
			&& etf_line_opens_a_declaration(masked, starts, byte_to_line_number(starts, i) + 1) {
			return none
		}
		i++
	}
	return none
}

// etf_line_opens_a_declaration reports whether `line` begins a top-level
// declaration, which is where the header of another one can no longer continue.
fn etf_line_opens_a_declaration(masked string, starts []int, line int) bool {
	if line >= starts.len {
		return true
	}
	if line_indent(line_text_without_terminator(masked, starts, line)) != '' {
		return false
	}
	if _ := etf_declaration_kind(masked, starts, line) {
		return true
	}
	return false
}

// etf_declaration_name returns the name the declaration is declared under: the
// identifier after `fn`, past the receiver of a method, or after the keyword of
// a type declaration. A `const` block has no name of its own, so it takes the
// first name it assigns. A name that is not a plain identifier — `C.printf`,
// whose dot gives away a C block — refuses the declaration.
fn etf_declaration_name(masked string, starts []int, line int, kind ETfDeclKind) ?string {
	if kind == .const_block {
		return etf_const_block_name(masked, starts, line)
	}
	head := line_text_without_terminator(masked, starts, line).trim_space()
	mut rest := etf_past_first_word(etf_after_pub(head))
	if kind == .function && rest.starts_with('(') {
		close := matching_delimiter(rest, 0, `(`, `)`)
		if close < 0 {
			return none
		}
		rest = rest[close + 1..].trim_space()
	}
	word := etf_declaration_word(rest)
	if !is_plain_identifier(word) {
		return none
	}
	return word
}

// etf_const_block_name returns the first name a `const` block assigns, since
// the block itself has no name. An empty block, and one whose first entry is
// not a plain `name = value`, names nothing and refuses the refactor.
fn etf_const_block_name(masked string, starts []int, line int) ?string {
	head := line_text_without_terminator(masked, starts, line).trim_space()
	rest := etf_past_first_word(head)
	mut from := starts[line] + head.len - rest.len
	block := rest.starts_with('(')
	mut to := masked.len
	if block {
		from++
		close := matching_delimiter(masked, from - 1, `(`, `)`)
		if close < 0 {
			return none
		}
		to = close
	} else {
		to = starts[line] + head.len
	}
	if from > to {
		return none
	}
	for entry_line in masked[from..to].split_into_lines() {
		entry := entry_line.trim_space()
		if entry == '' {
			continue
		}
		word := etf_declaration_word(entry)
		mut after := entry[word.len..].trim_space()
		if !is_plain_identifier(word) || !after.starts_with('=') {
			return none
		}
		return word
	}
	return none
}

// etf_attribute_block_start returns the first line the refactor moves: the
// declaration's own line, or the one above it when attributes are attached to
// it. The lines of a multi-line attribute, which this reads line by line and
// therefore cannot follow, refuse the whole declaration.
fn etf_attribute_block_start(masked string, starts []int, decl ETfDeclaration) ?int {
	mut first := decl.start_line
	for first > 0 {
		text := line_text_without_terminator(masked, starts, first - 1).trim_space()
		mut balance := 0
		for c in text {
			if c == `[` {
				balance++
			} else if c == `]` {
				balance--
			}
		}
		if balance != 0 {
			return none
		}
		if !text.starts_with('@[') {
			break
		}
		first--
	}
	return first
}

// etf_after_pub returns `text` past a leading `pub`, which every declaration
// may carry and which hides the keyword from the head of the line.
fn etf_after_pub(text string) string {
	if text.starts_with('pub ') {
		return text[4..].trim_space()
	}
	return text
}

// etf_past_first_word returns `text` past its first word and the blanks that
// follow it.
fn etf_past_first_word(text string) string {
	mut i := 0
	for i < text.len && text[i] !in [` `, `\t`] {
		i++
	}
	for i < text.len && text[i] in [` `, `\t`] {
		i++
	}
	return text[i..]
}

// etf_past_first_word_offset returns the offset just past the first word of
// `line` and the blanks that follow it.
fn etf_past_first_word_offset(masked string, starts []int, line int) int {
	text := line_text_without_terminator(masked, starts, line)
	return starts[line] + text.len - etf_past_first_word(text).len
}

// etf_declaration_word returns the name a declaration is written with: the
// text up to the blank, the parameter list or a type parameter list that
// follows it.
fn etf_declaration_word(rest string) string {
	mut end := 0
	for end < rest.len && rest[end] !in [` `, `\t`, `(`, `[`, `{`] {
		end++
	}
	return rest[..end]
}

// etf_byte_after returns the offset of the first `want` at or after `from`, or
// none when there is none.
fn etf_byte_after(text string, from int, want u8) ?int {
	mut i := from
	for i < text.len {
		if text[i] == want {
			return i
		}
		i++
	}
	return none
}

// etf_line_offset returns the offset of the first byte of `line` that is not a
// blank, which is where the declaration on it starts.
fn etf_line_offset(masked string, starts []int, line int) int {
	text := line_text_without_terminator(masked, starts, line)
	return starts[line] + line_indent(text).len
}
