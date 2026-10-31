// Copyright (c) 2025 Alexander Medavednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os

// --- Implement missing members ---

// V matches an interface by shape, not by declaration: nothing says
// `struct Dog implements Speaker`, so a struct either has the methods an
// interface names or it does not. This offer reads the interfaces of the program
// the struct belongs to and writes the methods the struct is still missing, when
// exactly one of them fits.
//
// An interface fits when the struct declares no method the interface does not
// name, because a struct that carries a method of its own is implementing some
// other type's interface, and when the interface names at least one method the
// struct does not have, because otherwise there would be nothing to write. Two
// interfaces that fit are left alone: the names cannot say which one the author
// meant, and stubs for the wrong one are worse than none.
//
// The stubs are written after the closing brace of the struct rather than inside
// its body, because a V struct body holds fields and nothing else: a method
// declared between those braces is an `unexpected token }` where the closing
// brace should be.

// ImplMember is one method an interface declares, in the words the interface
// declares it in: the parameter list and the return type written after its name,
// and the value a stub for it returns.
struct ImplMember {
	name        string
	params      string
	return_type string
	zero        string // what the stub returns; '' when the member returns nothing
}

// ImplCandidate is an interface a struct can implement, and the members of it
// the struct is still missing.
struct ImplCandidate {
	iface   string
	missing []ImplMember
}

// ImplStruct is the struct a cursor sits on: the name it is declared under with
// its type parameters, the methods and fields it already has, the name its own
// receivers use, and where the stubs are written.
struct ImplStruct {
	decl_line   int
	name        string
	type_params string // `[T]`, or '' when the struct takes no parameters
	insert      int    // byte offset the stubs are written at
	nl          string // the line terminator the closing brace uses
	ends_file   bool   // the closing brace is the last byte of the file
	indent      string // the indentation the struct is declared at
mut:
	methods     []string
	fields      []string
	recv_name   string
	body_indent string // the indentation the body of a stub is written at
}

// build_implement_members_action returns the "Implement missing members" quick
// fix for the struct whose declaration line `rng` sits on, or none when the
// range is on no struct declaration, when no interface of the program fits the
// struct, or when more than one does.
fn (mut app App) build_implement_members_action(uri string, content string, rng LSPRange) ?CodeAction {
	mut st := impl_struct_declaration(content, rng) or { return none }
	dir := os.dir(uri_to_path(uri)).replace('\\', '/').trim_right('/')
	if dir != '' && dir != '/' {
		app.ensure_dir_shallow_indexed(dir)
	}
	if uri in app.open_files {
		app.reindex_uri(uri)
	}
	app.impl_read_struct_members(uri, content, dir, mut st)
	candidates := app.impl_interface_candidates(uri, content, dir, st)
	if candidates.len != 1 {
		return none
	}
	chosen := candidates[0]
	at := byte_offset_to_position(content, st.insert, app.position_encoding)
	return CodeAction{
		title: 'Implement missing members of `${chosen.iface}`'
		kind:  code_action_kind_quickfix
		edit:  WorkspaceEdit{
			changes: {
				uri: [
					TextEdit{
						range:    LSPRange{
							start: at
							end:   at
						}
						new_text: impl_stub_text(st, chosen.missing)
					},
				]
			}
		}
	}
}

// impl_struct_declaration returns the struct whose declaration line `rng` sits
// on, with where the stubs for it are written, or none when the range is on no
// such line.
fn impl_struct_declaration(content string, rng LSPRange) ?ImplStruct {
	lines := content.split_into_lines()
	code := source_code_lines(content)
	if rng.start.line < 0 || rng.start.line >= lines.len || rng.start.line >= code.len {
		return none
	}
	decl_line := rng.start.line
	mut header := code[decl_line].trim_space()
	if header.starts_with('pub ') {
		header = header[4..].trim_space()
	}
	// The declaration line is the one that opens the body, `struct Name {`. A
	// struct whose brace sits on a later line is left alone, because the members
	// are written at a brace this does not have.
	if !header.starts_with('struct ') || !header.contains('{') {
		return none
	}
	declared := first_word(header[7..].trim_space())
	if declared == '' || !declared[0].is_capital() {
		return none
	}
	masked := masked_v_code(content)
	starts := line_start_offsets(content)
	open := impl_brace_offset(masked, starts, decl_line, `{`)
	if open < 0 {
		return none
	}
	close := matching_delimiter(masked, open, `{`, `}`)
	if close < 0 {
		return none
	}
	close_line := assist_line_of(starts, close)
	name := declared.all_before('[')
	decl_indent := line_indent(lines[decl_line])
	return ImplStruct{
		decl_line:   decl_line
		name:        name
		type_params: declared[name.len..]
		insert:      close + 1
		nl:          line_ending_after_line(content, close_line)
		ends_file:   close + 1 >= content.len
		indent:      decl_indent
		body_indent: decl_indent + '\t'
	}
}

// impl_read_struct_members records what the struct already has: the names of its
// fields, from the index of the file it is declared in, the names of the methods
// the program declares on it, and the name the first of those receivers uses.
fn (mut app App) impl_read_struct_members(uri string, content string, dir string, mut st ImplStruct) {
	for sym in app.index_doc_symbols(uri) {
		if sym.kind != sym_kind_struct || sym.range.start.line != st.decl_line {
			continue
		}
		for child in sym.children {
			if child.kind == sym_kind_field && child.name !in st.fields {
				st.fields << child.name
			}
		}
		break
	}
	for text in app.impl_program_files(uri, content, dir) {
		for line in source_code_lines(text) {
			recv, typ, method := impl_method_receiver(line)
			if recv == '' || normalize_receiver_type(typ) != st.name {
				continue
			}
			if method !in st.methods {
				st.methods << method
			}
			if st.recv_name == '' {
				st.recv_name = recv
			}
		}
	}
}

// impl_program_files returns the text of the file being edited first, then the
// text of every other indexed file in the same module directory, in a stable
// order. A V module occupies one directory, so those files are the program the
// struct belongs to.
fn (mut app App) impl_program_files(uri string, content string, dir string) []string {
	mut files := [content]
	if dir == '' || dir == '/' {
		return files
	}
	mut others := []string{}
	want_key := impl_dir_key(dir)
	for other, _ in app.symbol_index {
		if other == uri || impl_dir_key(os.dir(uri_to_path(other))) != want_key {
			continue
		}
		others << other
	}
	others.sort()
	for other in others {
		files << app.file_text(other)
	}
	return files
}

// impl_interface_candidates returns every interface of the program that `st` can
// implement: one that names every method the struct declares and at least one
// member it does not, and whose members are all methods with a signature that
// fits on one line.
fn (mut app App) impl_interface_candidates(uri string, content string, dir string, st ImplStruct) []ImplCandidate {
	mut candidates := []ImplCandidate{}
	for text in app.impl_program_files(uri, content, dir) {
		masked := masked_v_code(text)
		starts := line_start_offsets(text)
		code := source_code_lines(text)
		for line_idx, source_line in code {
			mut header := source_line.trim_space()
			if header.starts_with('pub ') {
				header = header[4..].trim_space()
			}
			if !header.starts_with('interface ') {
				continue
			}
			declared := first_word(header[10..].trim_space())
			if declared == '' || !declared[0].is_capital() {
				continue
			}
			open := impl_brace_offset(masked, starts, line_idx, `{`)
			if open < 0 {
				continue
			}
			close := matching_delimiter(masked, open, `{`, `}`)
			if close < 0 {
				continue
			}
			members := impl_interface_members(code, line_idx, assist_line_of(starts, close)) or {
				continue
			}
			candidate := impl_candidate_for(declared.all_before('['), members, st) or {
				continue
			}
			candidates << candidate
		}
	}
	return candidates
}

// impl_interface_members parses the members of the interface declared on
// `decl_line` of a file whose masked code is `code`, whose body ends on
// `close_line`. It returns none when the interface declares anything that cannot
// be stubbed as a method: an embedded interface, a `mut:` section, a field, or a
// signature that does not fit on one line.
fn impl_interface_members(code []string, decl_line int, close_line int) ?[]ImplMember {
	mut members := []ImplMember{}
	for i in decl_line + 1 .. close_line {
		if i < 0 || i >= code.len {
			break
		}
		raw := code[i].trim_space()
		if raw == '' {
			continue
		}
		mut end := 0
		for end < raw.len && is_ident_char(raw[end]) {
			end++
		}
		name := raw[..end]
		// An embedded interface is a type, so it is capitalized, and `mut:` opens
		// a section: neither is a member this can stub. A field is a name followed
		// by its type rather than by a parameter list.
		if name == '' || name[0].is_capital() || !raw[end..].trim_left(' \t').starts_with('(') {
			return none
		}
		rest := raw[end..].trim_left(' \t')
		open_paren := end + (raw.len - end - rest.len)
		close_paren := matching_delimiter(raw, open_paren, `(`, `)`)
		if close_paren < 0 {
			return none
		}
		if name in members.map(it.name) {
			continue
		}
		members << ImplMember{
			name:        name
			params:      raw[open_paren + 1..close_paren].trim_space()
			return_type: raw[close_paren + 1..].trim_space()
		}
	}
	return members
}

// impl_candidate_for returns the candidate `members` makes for `st`, or none
// when the struct declares a method the interface does not name, when it already
// holds a field a missing member would take the name of, when a missing member
// returns a type no value can be written for, or when nothing is missing at all.
fn impl_candidate_for(iface string, members []ImplMember, st ImplStruct) ?ImplCandidate {
	mut names := []string{cap: members.len}
	for member in members {
		names << member.name
	}
	for method in st.methods {
		if method !in names {
			return none
		}
	}
	mut missing := []ImplMember{}
	for member in members {
		if member.name in st.methods {
			continue
		}
		if member.name in st.fields {
			return none
		}
		zero := impl_member_zero_value(member.return_type) or { return none }
		missing << ImplMember{
			name:        member.name
			params:      member.params
			return_type: member.return_type
			zero:        zero
		}
	}
	if missing.len == 0 {
		return none
	}
	return ImplCandidate{
		iface:   iface
		missing: missing
	}
}

// impl_member_zero_value returns the value a stub for a member returns: `''` for
// a string, `0` for a number, `false` for a bool, an empty composite for a slice
// or a map, and the empty literal of a named type. A member that returns nothing
// has the empty zero. A return type no value can be written for — an optional, a
// result, a reference, or anything this does not recognise — has none, which
// refuses the interface rather than write a stub that will not compile.
fn impl_member_zero_value(return_type string) ?string {
	mut t := return_type.trim_space()
	if t == '' {
		return ''
	}
	if t[0] in [`?`, `!`, `&`] || t.contains(' ') || t.contains('\t') {
		return none
	}
	if t.starts_with('[]') || t.starts_with('map[') {
		return t + '{}'
	}
	if t == 'string' {
		return "''"
	}
	if t == 'bool' {
		return 'false'
	}
	if t in zero_integer_field_types {
		return '0'
	}
	if is_type_name(t) {
		return t + '{}'
	}
	return none
}

// impl_stub_text builds the members written after the struct's closing brace:
// one stub per missing member, each carrying the signature the interface
// declares and the zero value of its return type. The receiver is named after
// the struct's own receivers, so the stubs read like the methods already there.
fn impl_stub_text(st ImplStruct, missing []ImplMember) string {
	recv := if st.recv_name != '' { st.recv_name } else { 's' }
	mut lines := []string{cap: missing.len * 4}
	for member in missing {
		lines << '${st.indent}// ${member.name} does ...'
		mut header := '${st.indent}fn (mut ${recv} ${st.name}${st.type_params}) ${member.name}(${member.params})'
		if member.return_type != '' {
			header += ' ' + member.return_type
		}
		header += ' {'
		lines << header
		if member.zero != '' {
			lines << st.body_indent + 'return ' + member.zero
		}
		lines << st.indent + '}'
	}
	if lines.len == 0 {
		return ''
	}
	// The brace the stubs follow is still on its line, so a blank line separates
	// the struct from the methods that implement it, and the text that follows it
	// already ends that brace's line unless it is the last byte of the file. The
	// stubs take the terminator of the file they are written into.
	nl := st.nl
	mut text := nl + nl + lines.join(nl)
	if st.ends_file {
		text += nl
	}
	return text
}

// impl_method_receiver returns the name of the receiver of the method `line`
// declares, the type it is declared on, and the name of the method itself, or
// three empty strings when the line declares no method.
fn impl_method_receiver(line string) (string, string, string) {
	mut header := line.trim_space()
	if header.starts_with('pub ') {
		header = header[4..].trim_space()
	}
	if !header.starts_with('fn ') {
		return '', '', ''
	}
	rest := header[3..].trim_space()
	// A free function holds its parameters where a method holds its receiver, so
	// the first `(` is the receiver's only when it opens the line.
	open := rest.index('(') or { return '', '', '' }
	if open != 0 {
		return '', '', ''
	}
	close := matching_delimiter(rest, 0, `(`, `)`)
	if close < 0 {
		return '', '', ''
	}
	words := rest[1..close].trim_space().fields()
	if words.len < 2 {
		return '', '', ''
	}
	mut recv := words[0]
	mut typ := words[1]
	if recv == 'mut' {
		if words.len < 3 {
			return '', '', ''
		}
		recv = words[1]
		typ = words[2]
	}
	after := rest[close + 1..].trim_space()
	mut end := 0
	for end < after.len && is_ident_char(after[end]) {
		end++
	}
	method := after[..end]
	if method == '' || !after[end..].trim_left(' \t').starts_with('(') {
		return '', '', ''
	}
	return recv, typ, method
}

// impl_brace_offset returns the offset of the first `brace` on `line` of the
// masked text, or -1 when that line holds none.
fn impl_brace_offset(masked string, starts []int, line int, brace u8) int {
	if line < 0 || line >= starts.len {
		return -1
	}
	mut i := starts[line]
	end := if line + 1 < starts.len { starts[line + 1] } else { masked.len }
	for i < end {
		if masked[i] == brace {
			return i
		}
		i++
	}
	return -1
}

// impl_dir_key returns a comparable key for the directory of a file. The index
// holds URIs whose spellings of one directory agree, and on Windows they differ
// in case.
fn impl_dir_key(dir string) string {
	mut key := dir.replace('\\', '/').trim_right('/')
	$if windows {
		key = key.to_lower()
	}
	return key
}
