module main

// The "Add import" quick fix, the inverse of "Remove unknown import": a buffer
// that writes `os.join_path(...)` without an `import os` is one line short, and
// the lightbulb over the name offers to write it. Everything here reads the
// buffer it is handed and the modules its file can import, so it works on an
// unsaved edit exactly as it does on the file on disk.

// build_add_import_action returns the quick fix that imports the module the
// identifier under `rng` is used as, or none when there is nothing to import:
// the name is a keyword or a builtin, the file already imports that module, the
// module is not one this file can import, the buffer never writes the name as a
// module prefix, or the file declares the name itself.
fn (mut app App) build_add_import_action(uri string, content string, rng LSPRange) ?CodeAction {
	if content == '' {
		return none
	}
	masked := masked_v_code(content)
	starts := line_start_offsets(content)
	at := position_to_byte_offset(content, starts, rng.start.line, rng.start.char,
		app.position_encoding)
	name := aimp_module_name_at(masked, at) or { return none }
	if name in v_keywords || name in v_builtins || name in v_builtin_types {
		return none
	}
	for binding in parse_import_bindings(content) {
		if binding.module_path == name || binding.alias == name {
			return none
		}
	}
	offered := app.aimp_offered_module(uri_to_path(uri), name) or { return none }
	if !aimp_used_as_module_prefix(masked, name) {
		return none
	}
	if app.aimp_is_declared_name(uri, content, name) {
		return none
	}
	return CodeAction{
		title: 'Add import `${name}`'
		kind:  code_action_kind_quickfix
		edit:  WorkspaceEdit{
			changes: {
				uri: [import_spot(content).edit(offered.path)]
			}
		}
	}
}

// aimp_module_name_at returns the module name a new import should name for the
// identifier the cursor sits on: the qualifier of `name.member`, the callee of a
// bare `name(`, or — with the cursor on the member of a qualified expression,
// `join` of `os.join` — the qualifier the member is written after. A bare
// identifier that is neither followed by a `.` nor called is not a use of a
// module, so it returns none. The member comes first, because a method of a
// module is a bare call too, and it is the module it is called on that the
// import has to name.
fn aimp_module_name_at(masked string, at int) ?string {
	if at < 0 || at >= masked.len || !is_ident_char(masked[at]) {
		return none
	}
	mut end := at
	for end < masked.len && is_ident_char(masked[end]) {
		end++
	}
	mut start := at
	for start > 0 && is_ident_char(masked[start - 1]) {
		start--
	}
	if start == end {
		return none
	}
	word := masked[start..end]
	if !is_valid_v_identifier_name(word) {
		return none
	}
	if masked[end..].starts_with('.') {
		return word
	}
	if masked[..start].trim_right(' \t').ends_with('.') {
		return aimp_qualifier_before(masked, start)
	}
	if masked[end..].starts_with('(') {
		return word
	}
	return none
}

// aimp_qualifier_before returns the identifier the selector chain ending at the
// `.` in front of `start` begins with: `os` for `os.join`, and the base of a
// longer chain, `a` for the `.` in front of `c` of `a.b.c`, since only the base
// can be the module.
fn aimp_qualifier_before(masked string, start int) ?string {
	mut dot := start - 1
	for {
		if dot < 0 || masked[dot] != `.` {
			return none
		}
		mut begin := dot
		for begin > 0 && is_ident_char(masked[begin - 1]) {
			begin--
		}
		if begin == dot {
			return none
		}
		word := masked[begin..dot]
		if begin == 0 || masked[begin - 1] != `.` {
			return word
		}
		dot = begin - 1
	}
}

// aimp_used_as_module_prefix reports whether the buffer writes `name` as the
// qualifier of a member (`name.field`) or as the callee of a bare call
// (`name(...)`), which is what a use of a module looks like. A bare mention of
// the name — in a declaration, or as a value of its own — is not, and neither
// is a member of something else, `other.name.field`: only the base of a chain
// can name a module.
fn aimp_used_as_module_prefix(masked string, name string) bool {
	mut from := 0
	for {
		at := masked.index_after(name, from) or { return false }
		from = at + name.len
		if at > 0 && (is_ident_char(masked[at - 1]) || masked[at - 1] == `.`) {
			continue
		}
		if from < masked.len && is_ident_char(masked[from]) {
			continue
		}
		if masked[from..].starts_with('.') || masked[from..].starts_with('(') {
			return true
		}
	}
}

// aimp_offered_module returns the module the file at `file_path` can import that
// its code reaches as `name`, preferring the one whose import path is the name
// itself when two modules share it. Only an `offered` module is returned, so
// vlib's `builtin`, which every file has anyway, the internals of a vlib module
// and a module V refuses to build a program with are left out.
fn (mut app App) aimp_offered_module(file_path string, name string) ?ImportableModule {
	mut chosen := ImportableModule{}
	mut found := false
	for m in app.importable_modules(file_path) {
		if !m.offered || m.name != name {
			continue
		}
		if m.path == name {
			return m
		}
		if !found {
			chosen = m
			found = true
		}
	}
	if found {
		return chosen
	}
	return none
}

// aimp_is_declared_name reports whether `name` is already a name of the file:
// one its index entry declares, or a local, a parameter or a loop variable its
// code binds. A module is shadowed by any of them, so the import would name
// something the file never uses.
fn (mut app App) aimp_is_declared_name(uri string, content string, name string) bool {
	app.reindex_uri(uri)
	if aimp_entry_declares(app.index_doc_symbols(uri), name) {
		return true
	}
	for line in source_code_lines(content) {
		if line_declares_top_level(line, name) {
			return true
		}
		if line_declares_local(line, name, aimp_is_signature_line(line)) {
			return true
		}
	}
	return false
}

// aimp_entry_declares reports whether the symbols of an index entry include
// `name`, at the top level of the file or as a member of a struct or an enum.
fn aimp_entry_declares(symbols []DocumentSymbol, name string) bool {
	for symbol in symbols {
		if symbol.name == name || symbol.name.all_before('[') == name {
			return true
		}
		if aimp_entry_declares(symbol.children, name) {
			return true
		}
	}
	return false
}

// aimp_is_signature_line reports whether `line` is the signature of a function,
// whose parameters it declares between its parentheses.
fn aimp_is_signature_line(line string) bool {
	rest := line.trim_left(' \t')
	return rest.starts_with('fn ') || rest.starts_with('pub fn ')
}
