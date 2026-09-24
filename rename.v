module main

import os

// A rename edits every occurrence of the symbol under the cursor and nothing
// else, or refuses: an occurrence left behind breaks the program. The
// compiler's go-to-definition (`gd^`) tells which declaration an occurrence
// names, but it gives nothing for a declaration itself or for the key of a
// struct literal, and in `Color.red` it names the value for `Color` as well.

// RenameTarget is the symbol that a rename changes: its name and the position
// of the name in its declaration.
struct RenameTarget {
	symbol string
	anchor Location
}

// rename_target resolves the declaration that the identifier at the cursor names.
fn (mut app App) rename_target(uri string, line int, ch int, scope IndexScope, mut cache map[string]?Location) !RenameTarget {
	// The cursor may also sit right after the name, where it is after typing it.
	word := app.word_location(uri, line, ch) or {
		return error('there is no symbol to rename here')
	}
	symbol := app.identifier_at(word)
	if symbol == '' || !is_ident_start(symbol[0]) {
		return error('there is no symbol to rename here')
	}
	if symbol in v_keywords || symbol in v_builtins || symbol in v_builtin_types {
		return error('`${symbol}` is part of V and cannot be renamed')
	}
	if app.is_module_line_occurrence(word) {
		return error('`${symbol}` names a module, and modules cannot be renamed here')
	}
	anchor := app.rename_anchor(word, symbol, scope, mut cache) or {
		// `time` in `time.now()`, unless a local of that name hides the module.
		if app.is_module_qualifier(word) {
			return error('`${symbol}` names a module, and modules cannot be renamed here')
		}
		return err
	}
	if !uri_is_in_index_scope(anchor.uri, scope) {
		return error('`${symbol}` is declared in ${os.file_name(uri_to_path(anchor.uri))}, outside this project, so it cannot be renamed here')
	}
	app.check_interface_member(anchor, symbol, scope)!
	return RenameTarget{
		symbol: symbol
		anchor: anchor
	}
}

// rename_anchor finds the declaration that `word`, an occurrence of `symbol`,
// names.
fn (mut app App) rename_anchor(word Location, symbol string, scope IndexScope, mut cache map[string]?Location) !Location {
	// A use: the compiler names its declaration.
	if resolved := app.resolve_symbol_anchor_cached(word.uri, word.range.start.line, word.range.start.char, mut
		cache)
	{
		named := app.declaration_named(resolved, symbol) or {
			return error('could not tell which declaration `${symbol}` names')
		}
		return app.canonical_declaration(named, symbol, mut cache)
	}
	// A function, method, type, field, enum value or constant declared right here.
	if app.is_indexed_declaration(word) {
		return word
	}
	// The key of a struct literal names a field of the literal's struct.
	if field := app.struct_literal_field(word, symbol, mut cache) {
		return app.canonical_declaration(field, symbol, mut cache)
	}
	// A type named where the compiler does not answer.
	if decl := app.module_type_declaration(word, symbol) {
		return decl
	}
	// A local or a parameter declared here: its uses lead back to it.
	if app.uses_lead_back(word, symbol, scope, false, mut cache) {
		return word
	}
	// Last, as it costs a compiler launch per lookup, the same questions to a
	// compiler process of its own, which also sees inside a generic function
	// that another file instantiates (see run_v_line_info_once).
	if resolved := app.resolve_occurrence(word, true, mut cache) {
		named := app.declaration_named(resolved, symbol) or {
			return error('could not tell which declaration `${symbol}` names')
		}
		return app.canonical_declaration(named, symbol, mut cache)
	}
	if app.uses_lead_back(word, symbol, scope, true, mut cache) {
		return word
	}
	return error('could not tell which declaration `${symbol}` names')
}

// uses_lead_back reports whether another occurrence of `symbol` resolves to
// `word`, which is then the declaration of a local or a parameter. With
// `one_shot`, each lookup starts a compiler process of its own.
fn (mut app App) uses_lead_back(word Location, symbol string, scope IndexScope, one_shot bool, mut cache map[string]?Location) bool {
	candidates := app.rename_candidates(symbol, scope, word)
	if one_shot && candidates.len > rename_max_occurrences() {
		return false
	}
	if !one_shot {
		app.v3_prefetch_anchors(candidates, mut cache)
	}
	for cand in candidates {
		if same_anchor_location(cand, word) {
			continue
		}
		resolved := app.resolve_occurrence(cand, one_shot, mut cache) or { continue }
		if same_anchor_location(resolved, word) {
			return true
		}
	}
	return false
}

// resolve_occurrence returns the declaration that the occurrence at `loc` names,
// asked to the persistent compiler, or with `one_shot` to a compiler process of
// its own. Both answers are kept in `cache`, apart.
fn (mut app App) resolve_occurrence(loc Location, one_shot bool, mut cache map[string]?Location) ?Location {
	if !one_shot {
		return app.resolve_symbol_anchor_cached(loc.uri, loc.range.start.line, loc.range.start.char, mut
			cache)
	}
	key := 'once:' + anchor_cache_key(loc.uri, loc.range.start.line, loc.range.start.char)
	if key !in cache {
		cache[key] = app.resolve_symbol_anchor_by(loc.uri, loc.range.start.line, loc.range.start.char,
			true)
	}
	if resolved := cache[key] {
		return resolved
	}
	return none
}

// rename_max_occurrences is how many occurrences a rename checks, one compiler
// lookup each, before it refuses: VLS_RENAME_MAX_OCCURRENCES when it holds a
// positive number, and reference_semantic_max_candidates otherwise.
fn rename_max_occurrences() int {
	from_env := os.getenv('VLS_RENAME_MAX_OCCURRENCES').trim_space()
	n := from_env.int()
	return if n > 0 && n.str() == from_env { n } else { reference_semantic_max_candidates }
}

// rename_locations returns every occurrence of `target` in `scope`. It refuses
// when an occurrence cannot be told apart from the target.
fn (mut app App) rename_locations(target RenameTarget, scope IndexScope, request_id int, mut cache map[string]?Location) ![]Location {
	candidates := app.rename_candidates(target.symbol, scope, target.anchor)
	max_occurrences := rename_max_occurrences()
	if candidates.len > max_occurrences {
		return error('`${target.symbol}` appears ${candidates.len} times in this project, more than the ${max_occurrences} a rename checks (VLS_RENAME_MAX_OCCURRENCES sets that number)')
	}
	mut locations := []Location{}
	mut unresolved := []Location{}
	mut other_declarations := []Location{}
	app.v3_prefetch_anchors(candidates, mut cache)
	for cand in candidates {
		if request_id in app.cancelled_requests {
			return error('the rename was cancelled')
		}
		if same_anchor_location(cand, target.anchor) {
			locations << cand
			continue
		}
		if resolved := app.resolve_symbol_anchor_cached(cand.uri, cand.range.start.line, cand.range.start.char, mut
			cache)
		{
			named, is_target := app.declaration_resolved(resolved, target, mut cache)
			if is_target {
				locations << cand
			} else {
				other_declarations << named
			}
			continue
		}
		unresolved << cand
	}
	target_is_type := app.index_doc_symbols(target.anchor.uri).any(it.kind in type_declaration_kinds
		&& same_anchor_location(Location{ uri: target.anchor.uri, range: it.selection_range }, target.anchor))
	target_is_local := !app.is_indexed_declaration(target.anchor)
	mut unknown := []Location{}
	for cand in unresolved {
		// The declaration of another symbol with the same name, or a module: in
		// front of a dot too, unless the target is a local, which V lets have the
		// name of an imported module.
		if other_declarations.any(same_anchor_location(it, cand)) || app.is_indexed_declaration(cand)
			|| app.is_module_line_occurrence(cand)
			|| (!target_is_local && app.is_module_qualifier(cand)) {
			continue
		}
		if target_is_type {
			if decl := app.module_type_declaration(cand, target.symbol) {
				if same_anchor_location(decl, target.anchor) {
					locations << cand
				}
				continue
			}
		}
		if field := app.struct_literal_field(cand, target.symbol, mut cache) {
			if same_anchor_location(app.canonical_declaration(field, target.symbol, mut cache),
				target.anchor)
			{
				locations << cand
			}
			continue
		}
		unknown << cand
	}
	// What is still unknown goes to a compiler process of its own, which also
	// sees inside a generic function that another file instantiates. That costs
	// a launch each, so the last occurrences go first: a use names its local or
	// parameter, whose declaration then needs no launch.
	mut still_unknown := []Location{}
	for i := unknown.len - 1; i >= 0; i-- {
		cand := unknown[i]
		if request_id in app.cancelled_requests {
			return error('the rename was cancelled')
		}
		if other_declarations.any(same_anchor_location(it, cand)) {
			continue
		}
		resolved := app.resolve_occurrence(cand, true, mut cache) or {
			still_unknown.prepend(cand)
			continue
		}
		named, is_target := app.declaration_resolved(resolved, target, mut cache)
		if is_target {
			locations << cand
		} else {
			other_declarations << named
		}
	}
	for cand in still_unknown {
		if other_declarations.any(same_anchor_location(it, cand)) {
			continue
		}
		return error('`${target.symbol}` at ${os.file_name(uri_to_path(cand.uri))}:${cand.range.start.line + 1}:${cand.range.start.char + 1} could not be resolved, and renaming around it could break the program')
	}
	return locations
}

// declaration_resolved returns the declaration that an occurrence resolved to
// `resolved` names, and whether that is the target.
fn (mut app App) declaration_resolved(resolved Location, target RenameTarget, mut cache map[string]?Location) (Location, bool) {
	named := app.declaration_named(resolved, target.symbol) or { resolved }
	return named, same_anchor_location(app.canonical_declaration(named, target.symbol, mut cache),
		target.anchor)
}

// rename_candidates returns the occurrences of `symbol` that may name the
// declaration at `anchor`. A local or a parameter is seen only inside its
// function, so only that function is searched when `anchor` is one.
fn (mut app App) rename_candidates(symbol string, scope IndexScope, anchor Location) []Location {
	candidates := app.collect_semantic_candidates(symbol, scope)
	if app.is_indexed_declaration(anchor) {
		return candidates
	}
	first, last := app.enclosing_fn_lines(anchor) or { return candidates }
	return candidates.filter(it.uri == anchor.uri && it.range.start.line >= first
		&& it.range.start.line <= last)
}

// enclosing_fn_lines returns the lines where the function whose declaration or
// body holds `loc` starts and ends.
fn (mut app App) enclosing_fn_lines(loc Location) ?(int, int) {
	content := app.open_files[loc.uri] or { os.read_file(uri_to_path(loc.uri)) or { return none } }
	lines := content.split_into_lines()
	code := source_code_lines(content)
	for s in app.index_doc_symbols(loc.uri) {
		if s.kind != sym_kind_function && s.kind != sym_kind_method {
			continue
		}
		first := s.range.start.line
		if first > loc.range.start.line || first >= code.len {
			continue
		}
		last := declaration_end_line(lines, code, first)
		if loc.range.start.line <= last {
			return first, last
		}
	}
	return none
}

// What starts a declaration at the top level of a file.
const top_level_starts = ['fn ', 'pub fn ', 'struct ', 'pub struct ', 'union ', 'pub union ', 'enum ',
	'pub enum ', 'interface ', 'pub interface ', 'type ', 'pub type ', 'const ', 'pub const ',
	'__global', 'pub __global', '@[', 'module ', 'import ', '$if ', '#']

// declaration_end_line returns the last line of the declaration that starts on
// line `first`: the one before the next line that starts a declaration at the
// top level, with every brace closed, or the last line of the file. The brace
// that first closes a block would not do, since the declaration line may hold a
// pair of its own, as `fn f(p struct { x int }) int {` does. A function taken
// for shorter than it is would leave uses of its locals out of a rename; one
// taken for longer only has more occurrences checked. `code` holds `lines`
// without their strings and comments.
fn declaration_end_line(lines []string, code []string, first int) int {
	mut depth := 0
	for i in first .. code.len {
		if i > first && depth == 0 && i < lines.len && top_level_starts.any(lines[i].starts_with(it)) {
			return i - 1
		}
		for c in code[i] {
			if c == `{` {
				depth++
			} else if c == `}` {
				depth--
			}
		}
	}
	return code.len - 1
}

// Names that V calls by itself: a rename from or to one of them compiles and
// changes what the program does.
const implicit_fn_names = ['main', 'init', 'cleanup', 'testsuite_begin', 'testsuite_end']
const implicit_method_names = ['str', 'next', 'free']

// check_implicit_name refuses a rename of a function or method from or to a
// name that V calls by itself.
fn (mut app App) check_implicit_name(target RenameTarget, new_name string) ! {
	mut kind := 0
	for s in app.index_doc_symbols(target.anchor.uri) {
		if same_anchor_location(Location{ uri: target.anchor.uri, range: s.selection_range },
			target.anchor)
		{
			kind = s.kind
			break
		}
	}
	names := match kind {
		sym_kind_function { implicit_fn_names }
		sym_kind_method { implicit_method_names }
		else { return }
	}
	is_test_file := uri_to_path(target.anchor.uri).ends_with('_test.v')
	for name in [target.symbol, new_name] {
		if name in names || (kind == sym_kind_function && is_test_file && name.starts_with('test_')) {
			return error('V calls `${name}` by itself, so this rename would change what the program does')
		}
	}
}

// The methods of `IError`: a type that has them is an error, and V passes it
// around and prints it through them.
const ierror_method_names = ['msg', 'code']

// check_interface_member refuses a rename of a member of an interface, or of a
// method or a field with the name of one: V needs no declaration to implement
// an interface, so the types that implement it must keep that name, and a
// rename cannot see which types those are.
fn (mut app App) check_interface_member(anchor Location, symbol string, scope IndexScope) ! {
	if app.in_interface_body(anchor) {
		return error('`${symbol}` is a member of an interface: the types that implement it must keep that name, and V does not say which types those are, so this rename could break the program')
	}
	kind := app.indexed_declaration_kind(anchor)
	if kind !in [sym_kind_method, sym_kind_field] {
		return
	}
	if (kind == sym_kind_method && symbol in ierror_method_names)
		|| symbol in app.interface_member_names(scope) {
		return error('`${symbol}` has the name of a member of an interface: a type that implements it must keep that name, and V does not say which types those are, so this rename could break the program')
	}
}

// indexed_declaration_kind is the kind of the declaration of the index whose
// name is at `loc`, the field of a struct included, or 0 when there is none.
fn (mut app App) indexed_declaration_kind(loc Location) int {
	for s in app.index_doc_symbols(loc.uri) {
		if same_anchor_location(Location{ uri: loc.uri, range: s.selection_range }, loc) {
			return s.kind
		}
		for child in s.children {
			if same_anchor_location(Location{ uri: loc.uri, range: child.selection_range }, loc) {
				return child.kind
			}
		}
	}
	return 0
}

// in_interface_body reports whether `loc` is in the body of an interface: the
// name of one of its members, which the index does not list.
fn (mut app App) in_interface_body(loc Location) bool {
	content := app.open_files[loc.uri] or { os.read_file(uri_to_path(loc.uri)) or { return false } }
	lines := content.split_into_lines()
	code := source_code_lines(content)
	for s in app.index_doc_symbols(loc.uri) {
		if s.kind != sym_kind_interface {
			continue
		}
		first := s.range.start.line
		if loc.range.start.line > first && loc.range.start.line <= declaration_end_line(lines, code, first) {
			return true
		}
	}
	return false
}

// interface_member_names returns the names of the methods and fields that the
// interfaces of `scope` declare.
fn (mut app App) interface_member_names(scope IndexScope) []string {
	mut names := []string{}
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		if !uri_is_in_index_scope(uri, scope)
			|| !app.index_doc_symbols(uri).any(it.kind == sym_kind_interface) {
			continue
		}
		content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { continue } }
		lines := content.split_into_lines()
		code := source_code_lines(content)
		for s in app.index_doc_symbols(uri) {
			if s.kind != sym_kind_interface {
				continue
			}
			first := s.range.start.line
			last := declaration_end_line(lines, code, first)
			for i in first + 1 .. last + 1 {
				if i >= code.len {
					break
				}
				member := code[i].trim_space()
				mut end := 0
				for end < member.len && is_ident_char(member[end]) {
					end++
				}
				// An embedded interface is a type, capitalized; `mut:` opens a section.
				name := member[..end]
				if name != '' && !name[0].is_capital() && !member[end..].starts_with(':') {
					names << name
				}
			}
		}
	}
	return names
}

const type_declaration_kinds = [sym_kind_struct, sym_kind_enum, sym_kind_interface, sym_kind_class]

// module_type_declaration returns the declaration of the type that `word`
// names, found by the name alone. The compiler does not answer for every place
// a type is written, as `[]Point{}`, `map[string]Point{}` or `decode[Point](s)`,
// but in V a capitalized name that is not reached through a dot is the type its
// module declares under that name, unless a generic parameter around it has the
// name. That module is the directory of the file; a name declared twice there,
// as in files for different platforms, is left alone.
fn (mut app App) module_type_declaration(word Location, symbol string) ?Location {
	if symbol == '' || !symbol[0].is_capital() || app.is_reached_through_dot(word)
		|| app.is_generic_parameter(word, symbol) {
		return none
	}
	dir := os.dir(uri_to_path(word.uri))
	mut found := []Location{}
	for uri, entry in app.symbol_index {
		if os.dir(uri_to_path(uri)) != dir {
			continue
		}
		for s in entry.doc_symbols {
			if s.name == symbol && s.kind in type_declaration_kinds {
				found << Location{
					uri:   uri
					range: s.selection_range
				}
			}
		}
	}
	return if found.len == 1 { found[0] } else { none }
}

// is_reached_through_dot reports whether a dot comes right before `loc`, as in
// `mod.Point` or `user.Base`.
fn (app &App) is_reached_through_dot(loc Location) bool {
	content := app.open_files[loc.uri] or { os.read_file(uri_to_path(loc.uri)) or { return false } }
	lines := content.split_into_lines()
	if loc.range.start.line < 0 || loc.range.start.line >= lines.len {
		return false
	}
	col := app.client_col_to_byte_col(loc.uri, loc.range.start.line, loc.range.start.char)
	return col > 0 && lines[loc.range.start.line][col - 1] == `.`
}

// is_generic_parameter reports whether a function or type declared around `loc`
// has a generic parameter named `symbol`, as `T` in `fn show[T](x T)`.
fn (mut app App) is_generic_parameter(loc Location, symbol string) bool {
	content := app.open_files[loc.uri] or { os.read_file(uri_to_path(loc.uri)) or { return false } }
	lines := content.split_into_lines()
	code := source_code_lines(content)
	for s in app.index_doc_symbols(loc.uri) {
		first := s.range.start.line
		if first > loc.range.start.line || first >= lines.len {
			continue
		}
		last := declaration_end_line(lines, code, first)
		if loc.range.start.line <= last && symbol in generic_list_names(lines[first]) {
			return true
		}
	}
	return false
}

// generic_list_names returns the capitalized names between square brackets in a
// declaration line: `T` and `U` in `fn pair[T, U](a T, b U)`, `T` in
// `fn (b Box[T]) get() T`.
fn generic_list_names(header string) []string {
	mut names := []string{}
	mut i := 0
	for i < header.len {
		if header[i] != `[` {
			i++
			continue
		}
		end := header.index_after(']', i) or { break }
		for part in header[i + 1..end].split(',') {
			name := part.trim_space()
			if name != '' && name[0].is_capital() && name.bytes().all(is_ident_char(it)) {
				names << name
			}
		}
		i = end + 1
	}
	return names
}

// canonical_declaration follows the compiler from a declaration to the one it
// stands for, if any: a struct embedded in another is also a field named after
// it, and a name in the capture list of a closure is the variable it captures.
// Both names must change together.
fn (mut app App) canonical_declaration(loc Location, symbol string, mut cache map[string]?Location) Location {
	mut current := loc
	for _ in 0 .. 4 {
		next := app.resolve_symbol_anchor_cached(current.uri, current.range.start.line, current.range.start.char, mut
			cache) or { break }
		named := app.declaration_named(next, symbol) or { break }
		if same_anchor_location(named, current) {
			break
		}
		current = named
	}
	return current
}

// is_module_line_occurrence reports whether `loc` is part of the module name in
// a `module` or `import` line, as `util` in `import util { Settings }`: a module,
// which is not what a rename of a symbol with the same name changes.
fn (app &App) is_module_line_occurrence(loc Location) bool {
	text := app.line_text(loc) or { return false }
	trimmed := text.trim_left(' \t')
	if !trimmed.starts_with('module ') && !trimmed.starts_with('import ') {
		return false
	}
	col := app.client_col_to_byte_col(loc.uri, loc.range.start.line, loc.range.start.char)
	brace := text.index('{') or { text.len }
	return col < brace
}

// is_module_qualifier reports whether `loc` is a name the file imports a module
// as, in front of a dot, as `time` in `time.now()`. It may also be a local of
// that name, which V lets hide the module.
fn (app &App) is_module_qualifier(loc Location) bool {
	text := app.line_text(loc) or { return false }
	col := app.client_col_to_byte_col(loc.uri, loc.range.start.line, loc.range.start.char)
	mut end := col
	for end < text.len && is_ident_char(text[end]) {
		end++
	}
	if end == col || end >= text.len || text[end] != `.` || (col > 0 && text[col - 1] == `.`) {
		return false
	}
	content := app.open_files[loc.uri] or { os.read_file(uri_to_path(loc.uri)) or { return false } }
	return text[col..end] in parse_import_aliases(content)
}

// line_text returns the line of `loc`, as the editor holds it.
fn (app &App) line_text(loc Location) ?string {
	content := app.open_files[loc.uri] or { os.read_file(uri_to_path(loc.uri)) or { return none } }
	lines := content.split_into_lines()
	if loc.range.start.line < 0 || loc.range.start.line >= lines.len {
		return none
	}
	return lines[loc.range.start.line]
}

// code_only returns `content` with the text of its strings and its comments
// turned into spaces, lines and positions unchanged, so that a brace in a string
// or a comment is not taken for one of the code. What a string interpolates
// with `${}` is code, and stays.
fn code_only(content string) string {
	mut out := content.bytes()
	mut i := 0
	mut quote := u8(0)
	mut raw := false
	mut block_depth := 0
	// For each open `${`: the quote of its string, and the braces open inside it.
	mut open_quotes := []u8{}
	mut open_braces := []int{}
	for i < content.len {
		c := content[i]
		next := if i + 1 < content.len { content[i + 1] } else { u8(0) }
		if block_depth > 0 {
			if (c == `*` && next == `/`) || (c == `/` && next == `*`) {
				block_depth += if c == `/` { 1 } else { -1 }
				out[i] = ` `
				out[i + 1] = ` `
				i += 2
				continue
			}
			if c != `\n` {
				out[i] = ` `
			}
			i++
			continue
		}
		if quote != 0 {
			if !raw && c == `\\` && next != 0 {
				out[i] = ` `
				if next != `\n` {
					out[i + 1] = ` `
				}
				i += 2
				continue
			}
			if !raw && quote != `\`` && c == `$` && next == `{` {
				open_quotes << quote
				open_braces << 0
				quote = 0
				out[i] = ` `
				out[i + 1] = ` `
				i += 2
				continue
			}
			if c == quote {
				quote = 0
				raw = false
			}
			if c != `\n` {
				out[i] = ` `
			}
			i++
			continue
		}
		if c == `/` && next == `/` {
			for i < content.len && content[i] != `\n` {
				out[i] = ` `
				i++
			}
			continue
		}
		if c == `/` && next == `*` {
			block_depth = 1
			out[i] = ` `
			out[i + 1] = ` `
			i += 2
			continue
		}
		if open_quotes.len > 0 && c == `}` && open_braces.last() == 0 {
			// the end of a `${}`: back inside its string
			open_braces.pop()
			quote = open_quotes.pop()
			out[i] = ` `
			i++
			continue
		}
		if open_quotes.len > 0 && c == `{` {
			open_braces[open_braces.len - 1]++
		} else if open_quotes.len > 0 && c == `}` {
			open_braces[open_braces.len - 1]--
		}
		if c == `'` || c == `"` || c == `\`` {
			quote = c
			raw = i > 0 && content[i - 1] == `r` && (i < 2 || !is_ident_char(content[i - 2]))
			out[i] = ` `
		}
		i++
	}
	return out.bytestr()
}

// check_new_name refuses a name that V would not accept in place of `old`: not
// an identifier, a keyword, or a name whose case does not fit what `old` is,
// since types are capitalized and everything else is lowercase.
fn check_new_name(old string, new string) ! {
	if new == '' || !is_ident_start(new[0]) || !new.bytes().all(is_ident_char(it)) {
		return error('`${new}` is not a valid name')
	}
	if new in v_keywords {
		return error('`${new}` is a keyword of V')
	}
	if new == old {
		return
	}
	if old[0].is_capital() && !new[0].is_capital() {
		return error('`${new}` must start with a capital letter, as `${old}` does')
	}
	if !old.bytes().any(it.is_capital()) && new.bytes().any(it.is_capital()) {
		return error('`${new}` must be lowercase, as `${old}` is')
	}
}

// declaration_named returns `loc` when it declares `symbol`. In `Color.red` the
// compiler names the value for both identifiers; the declaration that `Color`
// names is then the enum that the value belongs to.
fn (mut app App) declaration_named(loc Location, symbol string) ?Location {
	if app.identifier_at(loc) == symbol {
		return loc
	}
	for s in app.index_doc_symbols(loc.uri) {
		if s.name != symbol {
			continue
		}
		for child in s.children {
			if same_anchor_location(Location{ uri: loc.uri, range: child.selection_range }, loc) {
				return Location{
					uri:   loc.uri
					range: s.selection_range
				}
			}
		}
	}
	return none
}

// is_indexed_declaration reports whether `loc` is the name in a declaration of
// the index: a function, method, type, field, enum value or constant.
fn (mut app App) is_indexed_declaration(loc Location) bool {
	for s in app.index_doc_symbols(loc.uri) {
		if same_anchor_location(Location{ uri: loc.uri, range: s.selection_range }, loc) {
			return true
		}
		for child in s.children {
			if same_anchor_location(Location{ uri: loc.uri, range: child.selection_range }, loc) {
				return true
			}
		}
	}
	return false
}

// index_doc_symbols returns the declarations that the index holds for `uri`.
fn (mut app App) index_doc_symbols(uri string) []DocumentSymbol {
	if entry := app.symbol_index[uri] {
		return entry.doc_symbols
	}
	return []DocumentSymbol{}
}

// struct_literal_field returns the field that `word` names when it is the key
// of a struct literal, as `x` in `Point{ x: 1 }`: the field `symbol` of the
// struct the literal builds.
fn (mut app App) struct_literal_field(word Location, symbol string, mut cache map[string]?Location) ?Location {
	content := app.open_files[word.uri] or { os.read_file(uri_to_path(word.uri)) or { return none } }
	lines := content.split_into_lines()
	line := word.range.start.line
	if line < 0 || line >= lines.len {
		return none
	}
	col := app.client_col_to_byte_col(word.uri, line, word.range.start.char)
	if col < 0 || col + symbol.len > lines[line].len {
		return none
	}
	after := lines[line][col + symbol.len..].trim_left(' \t')
	if !after.starts_with(':') || after.starts_with(':=') {
		return none
	}
	// The `{` that opens the literal, and the type right before it.
	starts := line_start_offsets(content)
	// Braces in strings and comments are not the literal's.
	code := code_only(content)
	mut pos := starts[line] + col - 1
	mut depth := 0
	for pos >= 0 {
		c := code[pos]
		if c == `}` {
			depth++
		} else if c == `{` {
			if depth == 0 {
				break
			}
			depth--
		}
		pos--
	}
	mut end := pos
	for end > 0 && code[end - 1] in [` `, `\t`] {
		end--
	}
	if end > 0 && code[end - 1] == `]` {
		// The arguments of a generic struct, `Box[int]{`.
		mut brackets := 0
		for end > 0 {
			end--
			if code[end] == `]` {
				brackets++
			} else if code[end] == `[` {
				brackets--
				if brackets == 0 {
					break
				}
			}
		}
	}
	mut begin := end
	for begin > 0 && (code[begin - 1].is_alnum() || code[begin - 1] == `_`) {
		begin--
	}
	if pos < 0 || begin >= end || !code[begin].is_capital() {
		return none
	}
	mut type_line := line
	for type_line > 0 && starts[type_line] > begin {
		type_line--
	}
	type_col := byte_to_encoded_col(lines[type_line], begin - starts[type_line], app.position_encoding)
	struct_decl := app.resolve_symbol_anchor_cached(word.uri, type_line, type_col, mut cache)?
	for s in app.index_doc_symbols(struct_decl.uri) {
		if !same_anchor_location(Location{ uri: struct_decl.uri, range: s.selection_range }, struct_decl) {
			continue
		}
		for child in s.children {
			if child.name == symbol {
				return Location{
					uri:   struct_decl.uri
					range: child.selection_range
				}
			}
		}
	}
	return none
}

// word_location returns where the identifier at `line`, `ch` of `uri` starts and ends.
fn (app &App) word_location(uri string, line int, ch int) ?Location {
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { return none } }
	lines := content.split_into_lines()
	if line < 0 || line >= lines.len {
		return none
	}
	start, end := find_word_bounds_at_col(lines[line], ch, app.position_encoding)
	if start < 0 || end <= start {
		return none
	}
	return Location{
		uri:   uri
		range: LSPRange{
			start: Position{
				line: line
				char: start
			}
			end:   Position{
				line: line
				char: end
			}
		}
	}
}

// identifier_at returns the identifier that starts at `loc`. The compiler can
// report a column one unit before it.
fn (app &App) identifier_at(loc Location) string {
	for delta in [0, 1] {
		if word := app.word_location(loc.uri, loc.range.start.line, loc.range.start.char + delta) {
			content := app.open_files[loc.uri] or {
				os.read_file(uri_to_path(loc.uri)) or { return '' }
			}
			lines := content.split_into_lines()
			return substr_by_char_bounds(lines[word.range.start.line], word.range.start.char,
				word.range.end.char, app.position_encoding)
		}
	}
	return ''
}
