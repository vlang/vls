module main

import os

// LanguageMember is a member that V itself gives to a kind of type. None of them
// is declared in a .v file (V1 generates them while parsing, V3 keeps them in
// lists), so completion takes them from language_members. In `receiver`,
// `params` and `ret`, `{T}` stands for the type itself, `{E}` for the element of
// an array or channel and `{K}`/`{V}` for the key and value of a map. A parameter
// named `predicate` or `callback` is inserted as the simplest function of its type.
struct LanguageMember {
	kinds     []string
	name      string
	receiver  string
	generic   string
	params    string
	ret       string
	is_field  bool
	is_static bool
}

fn language_field(kinds string, name string, typ string) LanguageMember {
	return LanguageMember{
		kinds:    kinds.fields()
		name:     name
		ret:      typ
		is_field: true
	}
}

fn language_method(kinds string, name string, params string, ret string) LanguageMember {
	return LanguageMember{
		kinds:  kinds.fields()
		name:   name
		params: params
		ret:    ret
	}
}

fn language_method_on(kinds string, receiver string, name string, params string, ret string) LanguageMember {
	return LanguageMember{
		kinds:    kinds.fields()
		name:     name
		receiver: receiver
		params:   params
		ret:      ret
	}
}

fn language_static(kinds string, name string, generic string, params string, ret string) LanguageMember {
	return LanguageMember{
		kinds:     kinds.fields()
		name:      name
		generic:   generic
		params:    params
		ret:       ret
		is_static: true
	}
}

// language_members lists them by the kinds of type that have them: `array`
// (`[]T`), `array_string`, `array_u8` and `array_rune` (arrays of those), `fixed`
// (`[N]T`), `map`, `chan`, `enum`, `flag` (`@[flag]` enums), `sum` (sum types),
// `typeof` (what `typeof(x)` returns) and `printable` (values V can turn into a
// string).
const language_members = [
	language_field('array fixed', 'len', 'int'),
	language_field('array', 'cap', 'int'),
	language_method('array', 'first', '', '{E}'),
	language_method('array', 'last', '', '{E}'),
	language_method('array', 'pop', '', '{E}'),
	language_method('array', 'pop_left', '', '{E}'),
	language_method('array fixed', 'contains', 'value {E}', 'bool'),
	language_method('array fixed', 'index', 'value {E}', 'int'),
	language_method('array', 'last_index', 'value {E}', 'int'),
	language_method('array fixed', 'filter', 'predicate fn ({E}) bool', '[]{E}'),
	language_method('array fixed', 'map', 'callback fn ({E}) U', '[]U'),
	language_method('array fixed', 'any', 'predicate fn ({E}) bool', 'bool'),
	language_method('array fixed', 'all', 'predicate fn ({E}) bool', 'bool'),
	language_method('array fixed', 'count', 'predicate fn ({E}) bool', 'int'),
	language_method('array fixed', 'sort', '', ''),
	language_method('array fixed', 'sorted', '', '{T}'),
	language_method('array', 'sort_with_compare', 'callback fn (a &{E}, b &{E}) int', ''),
	language_method('array', 'sorted_with_compare', 'callback fn (a &{E}, b &{E}) int',
		'{T}'),
	language_method('array', 'clone', '', '{T}'),
	language_method('array fixed', 'reverse', '', '{T}'),
	language_method('array', 'reverse_in_place', '', ''),
	language_method('array', 'repeat', 'count int', '{T}'),
	language_method('array', 'insert', 'i int, val {E}', ''),
	language_method('array', 'prepend', 'val {E}', ''),
	language_method('array', 'delete', 'i int', ''),
	language_method('array', 'delete_many', 'i int, size int', ''),
	language_method('array', 'delete_last', '', ''),
	language_method('array', 'clear', '', ''),
	language_method('array', 'trim', 'index int', ''),
	language_method('array', 'drop', 'num int', ''),
	language_method('array_string', 'join', 'sep string', 'string'),
	language_method('array_string', 'join_lines', '', 'string'),
	language_method('array_string', 'sort_by_len', '', ''),
	language_method('array_string', 'sort_ignore_case', '', ''),
	language_method('array_u8', 'bytestr', '', 'string'),
	language_method('array_u8', 'hex', '', 'string'),
	language_method('array_u8', 'byterune', '', '!rune'),
	language_method('array_rune', 'string', '', 'string'),
	language_field('map', 'len', 'int'),
	language_method('map', 'keys', '', '[]{K}'),
	language_method('map', 'values', '', '[]{V}'),
	language_method('map', 'delete', 'key {K}', ''),
	language_method('map', 'clear', '', ''),
	language_method('map', 'clone', '', '{T}'),
	language_method('map', 'move', '', '{T}'),
	language_method('chan', 'close', '', ''),
	language_method('chan', 'try_push', 'val {E}', 'ChanState'),
	language_method('chan', 'try_pop', 'mut val {E}', 'ChanState'),
	language_field('chan', 'len', 'int'),
	language_field('chan', 'cap', 'int'),
	language_field('chan', 'closed', 'bool'),
	language_static('enum', 'from', '[W]', 'input W', '!{T}'),
	language_static('flag', 'zero', '', '', '{T}'),
	language_method_on('flag', 'e &{T}', 'is_empty', '', 'bool'),
	language_method_on('flag', 'e &{T}', 'has', 'flag_ {T}', 'bool'),
	language_method_on('flag', 'e &{T}', 'all', 'flag_ {T}', 'bool'),
	language_method_on('flag', 'mut e {T}', 'set', 'flag_ {T}', ''),
	language_method_on('flag', 'mut e {T}', 'set_all', '', ''),
	language_method_on('flag', 'mut e {T}', 'clear', 'flag_ {T}', ''),
	language_method_on('flag', 'mut e {T}', 'clear_all', '', ''),
	language_method_on('flag', 'mut e {T}', 'toggle', 'flag_ {T}', ''),
	language_method('sum', 'type_name', '', 'string'),
	language_field('typeof', 'name', 'string'),
	language_field('typeof', 'idx', 'int'),
	language_field('typeof', 'indirections', 'u8'),
	language_method('printable', 'str', '', 'string'),
]

// language_member_items renders what language_members gives a type of the given
// kinds: its static functions (`Color.from`) or the members of its values.
fn language_member_items(typ string, kinds []string, statics bool) []Detail {
	elem, key, value := composite_type_parts(typ)
	fill := fn [typ, elem, key, value] (text string) string {
		return text.replace('{T}', typ).replace('{E}', elem).replace('{K}', key).replace('{V}',
			value)
	}
	default_receiver := '${language_receiver_name(kinds)} ${typ}'
	mut items := []Detail{}
	for member in language_members {
		if member.is_static != statics || !member.kinds.any(it in kinds) {
			continue
		}
		ret := fill(member.ret)
		if member.is_field {
			items << Detail{
				kind:   10 // CompletionItemKind.Property
				label:  member.name
				detail: ret
			}
			continue
		}
		params := fill(member.params)
		head := if statics {
			'fn ${typ}.${member.name}${member.generic}'
		} else {
			receiver := if member.receiver == '' { default_receiver } else { fill(member.receiver) }
			'fn (${receiver}) ${member.name}${member.generic}'
		}
		signature := '${head}(${params})' + if ret == '' { '' } else { ' ${ret}' }
		items << callable_member_item(member.name, signature, params, elem, if statics {
			3 // CompletionItemKind.Function
		} else {
			2 // CompletionItemKind.Method
		})
	}
	return items
}

// callable_member_item completes a method or static function: `name()` without
// parameters, the simplest function for a callback parameter, and a placeholder
// for the first parameter otherwise.
fn callable_member_item(name string, signature string, params string, generic_default string, kind int) Detail {
	if params == '' {
		return Detail{
			kind:               kind
			label:              name
			detail:             signature
			insert_text:        '${name}()'
			insert_text_format: 1
		}
	}
	if params.starts_with('predicate ') || params.starts_with('callback ') {
		if skeleton := callback_skeleton_text(params.all_after(' '), generic_default) {
			return Detail{
				kind:               kind
				label:              name
				detail:             signature
				insert_text:        '${name}(${skeleton})'
				insert_text_format: 2
			}
		}
	}
	first := params.all_before(',').trim_space()
	placeholder := if first.starts_with('mut ') {
		'mut \${1:${first[4..].all_before(' ')}}'
	} else {
		'\${1:${first.all_before(' ')}}'
	}
	return Detail{
		kind:               kind
		label:              name
		detail:             signature
		insert_text:        '${name}(${placeholder})\$0'
		insert_text_format: 2
	}
}

fn callback_skeleton_text(fn_type string, generic_default string) ?string {
	_, skeleton := callback_skeleton(fn_type, generic_default) or { return none }
	return skeleton
}

// language_receiver_name names the receiver in the signatures of a kind of type.
fn language_receiver_name(kinds []string) string {
	return if 'array' in kinds || 'fixed' in kinds {
		'a'
	} else if 'map' in kinds {
		'm'
	} else if 'chan' in kinds {
		'ch'
	} else if 'enum' in kinds {
		'e'
	} else {
		'x'
	}
}

// composite_member_kinds returns the kinds of a type V builds from other types
// (`[]T`, `[N]T`, `map[K]V`, `chan T`) and of what `typeof` returns, or none for
// a named or builtin type, whose kinds come from its declaration.
fn composite_member_kinds(typ string) []string {
	if typ == 'typeof' {
		return ['typeof']
	}
	if typ.starts_with('[]') {
		elem := typ[2..].trim_space()
		if elem == '' {
			return []
		}
		mut kinds := ['array']
		if elem == 'string' {
			kinds << 'array_string'
		} else if elem in ['u8', 'byte'] {
			kinds << 'array_u8'
		} else if elem == 'rune' {
			kinds << 'array_rune'
		}
		kinds << 'printable'
		return kinds
	}
	if typ.starts_with('[') {
		return ['fixed', 'printable']
	}
	if typ.starts_with('map[') {
		return ['map', 'printable']
	}
	if typ.starts_with('chan ') {
		return ['chan']
	}
	return []
}

// composite_type_parts returns the element type of `[]T`, `[N]T` and `chan T`, and
// the key and value types of `map[K]V`.
fn composite_type_parts(typ string) (string, string, string) {
	if typ.starts_with('map[') {
		close := matching_delimiter(typ, 3, `[`, `]`)
		if close > 0 {
			return '', typ[4..close].trim_space(), typ[close + 1..].trim_space()
		}
		return '', '', ''
	}
	if typ.starts_with('[') {
		close := matching_delimiter(typ, 0, `[`, `]`)
		if close > 0 {
			return typ[close + 1..].trim_space(), '', ''
		}
		return '', '', ''
	}
	if typ.starts_with('chan ') {
		return typ['chan '.len..].trim_space(), '', ''
	}
	return '', '', ''
}

// member_receiver_type strips what does not change the members of a type: a
// reference, `mut`, `shared`, and an option or result.
fn member_receiver_type(typ string) string {
	mut t := typ.trim_space()
	for {
		if t.starts_with('mut ') {
			t = t[4..].trim_space()
		} else if t.starts_with('shared ') {
			t = t[7..].trim_space()
		} else if t.len > 0 && t[0] in [`&`, `?`, `!`] {
			t = t[1..].trim_space()
		} else {
			return t
		}
	}
	return t
}

// type_modifiers returns what member_receiver_type strips from the front of
// `typ`: the `&` of `&Point`, the `?&` of `?&Point`.
fn type_modifiers(typ string) string {
	t := typ.trim_space()
	return t[..t.len - member_receiver_type(t).len]
}

fn top_level_slice_range(text string) bool {
	mut depth := 0
	mut in_string := false
	mut quote := `\0`
	mut i := 0
	for i < text.len {
		ch := text[i]
		if in_string {
			if ch == `\\` {
				i += 2
				continue
			}
			if ch == quote {
				in_string = false
			}
			i++
			continue
		}
		if ch in [`'`, `"`, `\``] {
			in_string = true
			quote = ch
			i++
			continue
		}
		if ch in [`(`, `[`, `{`] {
			depth++
			i++
			continue
		}
		if ch in [`)`, `]`, `}`] {
			if depth > 0 {
				depth--
			}
			i++
			continue
		}
		if depth == 0 && ch == `.` && i + 1 < text.len && text[i + 1] == `.` {
			return true
		}
		i++
	}
	return false
}

fn slice_result_type(typ string) string {
	t := member_receiver_type(typ)
	elem, _, _ := composite_type_parts(t)
	if elem == '' {
		return t
	}
	return '[]${elem}'
}

fn unwrap_option_type(typ string) string {
	t := typ.trim_space()
	if t.starts_with('?') || t.starts_with('!') {
		return t[1..].trim_space()
	}
	return t
}

// index_expression_type returns the type of `value[i]` for a value of type `typ`.
fn index_expression_type(typ string) string {
	t := member_receiver_type(typ)
	if t == 'string' {
		return 'u8'
	}
	elem, _, value := composite_type_parts(t)
	return if t.starts_with('map[') { value } else { elem }
}

fn is_type_name(name string) bool {
	short := name.all_after_last('.')
	return short.len > 0 && short[0] >= `A` && short[0] <= `Z`
}

// TypeDeclaration is what completion needs to know about the declaration of a
// named type: its kind (`struct`, `enum`, `interface`, `alias`, `sum`, or
// `builtin` for `int`, `string`...), whether an enum is a `@[flag]`, what an
// alias stands for, and where it is declared.
struct TypeDeclaration {
	kind           string
	name           string
	is_flag        bool
	alias_base     string
	dir            string
	module_name    string
	require_public bool
}

fn (mut app App) type_declaration(uri string, content string, typ string) TypeDeclaration {
	t := member_receiver_type(typ)
	if t in builtin_receiver_types {
		return TypeDeclaration{
			kind: 'builtin'
			name: t
		}
	}
	dir, name, require_public, expected_module := app.receiver_type_scope(uri, content, t)
	if dir == '' || name == '' || expected_module == '' || !os.is_dir(dir) {
		return TypeDeclaration{}
	}
	app.ensure_dir_shallow_indexed(dir)
	normalized_dir := normalized_index_path(dir)
	for open_uri, _ in app.open_files {
		if normalized_index_path(os.dir(uri_to_path(open_uri))) == normalized_dir {
			app.reindex_uri(open_uri)
		}
	}
	mut indexed_uris := app.symbol_index.keys()
	indexed_uris.sort()
	for indexed_uri in indexed_uris {
		entry := app.symbol_index[indexed_uri] or { continue }
		if normalized_index_path(os.dir(uri_to_path(indexed_uri))) != normalized_dir
			|| entry.module_name != expected_module {
			continue
		}
		for symbol in entry.doc_symbols {
			if symbol.name != name || symbol.kind !in [sym_kind_struct, sym_kind_enum,
				sym_kind_interface, sym_kind_class] {
				continue
			}
			source_lines := (app.index_source_for(indexed_uri) or { '' }).split_into_lines()
			line_idx := symbol.range.start.line
			mut decl := TypeDeclaration{
				name:           name
				dir:            dir
				module_name:    expected_module
				require_public: require_public
			}
			if symbol.kind == sym_kind_struct {
				decl = TypeDeclaration{
					...decl
					kind: 'struct'
				}
			} else if symbol.kind == sym_kind_interface {
				decl = TypeDeclaration{
					...decl
					kind: 'interface'
				}
			} else if symbol.kind == sym_kind_enum {
				decl = TypeDeclaration{
					...decl
					kind:    'enum'
					is_flag: declaration_has_attribute(source_lines, line_idx, 'flag')
				}
			} else {
				// `type Name = Base` or `type Name = A | B`
				line := if line_idx >= 0 && line_idx < source_lines.len {
					source_lines[line_idx]
				} else {
					''
				}
				rhs := line.all_after('=').all_before('//').trim_space()
				decl = if rhs.contains('|') {
					TypeDeclaration{
						...decl
						kind: 'sum'
					}
				} else {
					TypeDeclaration{
						...decl
						kind:       'alias'
						alias_base: rhs
					}
				}
			}
			return decl
		}
	}
	return TypeDeclaration{}
}

// declaration_has_attribute reports whether the attributes right above the
// declaration at `line_idx` (`@[flag]`, `@[flag; ...]`, or the old `[flag]`)
// include `name`.
fn declaration_has_attribute(lines []string, line_idx int, name string) bool {
	for i := line_idx - 1; i >= 0 && i < lines.len; i-- {
		line := lines[i].trim_space()
		start := if line.starts_with('@[') {
			2
		} else if line.starts_with('[') {
			1
		} else {
			-1
		}
		if start < 0 || !line.ends_with(']') || line.len <= start {
			return false
		}
		for attribute in line[start..line.len - 1].split(';') {
			if attribute.trim_space().all_before(':').trim_space() == name {
				return true
			}
		}
	}
	return false
}

// declaration_member_kinds returns the language_members kinds of a named type.
fn declaration_member_kinds(decl TypeDeclaration) []string {
	return match decl.kind {
		'enum' {
			if decl.is_flag {
				['enum', 'flag', 'printable']
			} else {
				['enum', 'printable']
			}
		}
		'sum' {
			['sum', 'printable']
		}
		'struct', 'alias', 'builtin' {
			['printable']
		}
		else {
			[]string{}
		}
	}
}

// type_members lists what can follow `value.` for a value of type `typ`: the
// fields and methods declared for it and for the structs it embeds, those of the
// type an alias stands for, and the members V gives its kind of type.
fn (mut app App) type_members(uri string, content string, typ string) IndexedCompletionResult {
	return app.type_members_at_depth(uri, content, typ, 0)
}

fn (mut app App) type_members_at_depth(uri string, content string, typ string, depth int) IndexedCompletionResult {
	t := member_receiver_type(typ)
	if t == '' || depth > 4 {
		return IndexedCompletionResult{
			use_compiler: true
		}
	}
	mut kinds := composite_member_kinds(t)
	mut items := []Detail{}
	mut field_types := map[string]string{}
	mut field_declared_types := map[string]string{}
	mut embedded_types := []string{}
	mut use_compiler := false
	mut resolved_type := false
	if kinds.len == 0 && !t.starts_with('thread') {
		declared := app.declared_type_members(uri, content, t)
		items = declared.items.clone()
		field_types = declared.field_types.clone()
		field_declared_types = declared.field_declared_types.clone()
		embedded_types = declared.embedded_types
		use_compiler = declared.use_compiler
		resolved_type = declared.resolved_type
		decl := app.type_declaration(uri, content, t)
		kinds = declaration_member_kinds(decl)
		if decl.alias_base != '' {
			base_type := qualify_member_type(decl.alias_base, t)
			base := app.type_members_at_depth(uri, content, base_type, depth + 1)
			for item in base.items {
				if !items.any(it.label == item.label) {
					items << item
				}
			}
			for field_name, field_type in base.field_types {
				if field_name !in field_types {
					field_types[field_name] = field_type
				}
			}
			for field_name, declared_type in base.field_declared_types {
				if field_name !in field_declared_types {
					field_declared_types[field_name] = declared_type
				}
			}
			use_compiler = use_compiler || base.use_compiler
		}
		if decl.kind in ['', 'interface'] && items.len == 0 {
			// Nothing the index knows about this type: the compiler may.
			use_compiler = true
		}
	}
	for item in language_member_items(t, kinds, false) {
		if !items.any(it.label == item.label) {
			items << item
		}
	}
	if wait_item := thread_wait_completion(t) {
		items << wait_item
	}
	return IndexedCompletionResult{
		items:                items
		use_compiler:         use_compiler
		embedded_types:       embedded_types
		field_types:          field_types
		field_declared_types: field_declared_types
		resolved_type:        resolved_type
	}
}

// declared_type_members lists the fields and methods declared for a named or
// builtin type and for the structs it embeds.
fn (mut app App) declared_type_members(uri string, content string, receiver_type string) IndexedCompletionResult {
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
		for detail in method_result.items {
			if detail.label !in seen {
				items << detail
				seen[detail.label] = true
			}
		}
	}
	return IndexedCompletionResult{
		items:                items
		use_compiler:         field_result.use_compiler || methods_use_compiler
		embedded_types:       field_result.embedded_types
		field_types:          field_result.field_types
		field_declared_types: field_result.field_declared_types
		resolved_type:        field_result.resolved_type
	}
}

// member_type returns the type of `value.name` for a value of type `typ`: a
// field's type or a method's return type, or '' when unknown.
fn (mut app App) member_type(uri string, content string, typ string, name string) string {
	t := member_receiver_type(typ)
	members := app.type_members(uri, content, t)
	if field_type := members.field_types[name] {
		// The lookup type is named for this file but has lost the field's `&`, `?`
		// or `!`; the declared one still has them.
		return type_modifiers(members.field_declared_types[name] or { '' }) + field_type
	}
	for item in members.items {
		if item.label != name {
			continue
		}
		if item.kind == 10 {
			return item.detail
		}
		if item.kind == 2 {
			return qualify_member_type(signature_return_type(item.detail), t)
		}
	}
	return ''
}

// signature_return_type returns the return type in a signature such as
// `fn (p Point) moved() Point` or `fn Color.from[W](input W) !Color`.
fn signature_return_type(signature string) string {
	mut s := signature.trim_space()
	if s.starts_with('pub ') {
		s = s[4..].trim_space()
	}
	if !s.starts_with('fn ') {
		return ''
	}
	s = s[3..].trim_space()
	if s.starts_with('(') {
		close := matching_delimiter(s, 0, `(`, `)`)
		if close < 0 {
			return ''
		}
		s = s[close + 1..].trim_space()
	}
	open := s.index('(') or { return '' }
	close := matching_delimiter(s, open, `(`, `)`)
	if close < 0 {
		return ''
	}
	return s[close + 1..].all_before('{').trim_space()
}

// qualify_member_type qualifies a type named in the declarations of `owner` so it
// resolves from the requesting file: `Time` becomes `time.Time` for a method of
// `time.Time`.
fn qualify_member_type(typ string, owner string) string {
	owner_type := member_receiver_type(owner)
	if !owner_type.contains('.') || typ == '' {
		return typ
	}
	qualifier := owner_type.all_before_last('.')
	mut prefix_len := 0
	for prefix_len < typ.len && typ[prefix_len] in [`&`, `?`, `!`] {
		prefix_len++
	}
	mut rest := typ[prefix_len..]
	mut arrays := ''
	for rest.starts_with('[') {
		close := rest.index(']') or { break }
		arrays += rest[..close + 1]
		rest = rest[close + 1..]
	}
	if rest == '' || rest.contains('.') || !is_type_name(rest) {
		return typ
	}
	return '${typ[..prefix_len]}${arrays}${qualifier}.${rest}'
}

// type_static_completions lists what can follow `Type.`: the values of an enum,
// the static functions declared for the type (`fn Point.origin()`), and those V
// gives its kind of type (`Color.from`, `Perm.zero`). It is none when `type_name`
// names no type the index knows.
fn (mut app App) type_static_completions(uri string, content string, type_name string) ?[]Detail {
	decl := app.type_declaration(uri, content, type_name)
	if decl.kind in ['', 'builtin', 'interface'] {
		return none
	}
	mut items := []Detail{}
	if decl.kind == 'enum' {
		items << app.indexed_enum_members(uri, content, type_name) or { []Detail{} }
	}
	items << app.declared_static_functions(decl)
	items << language_member_items(type_name, declaration_member_kinds(decl), true)
	if items.len == 0 {
		return none
	}
	return items
}

// declared_static_functions lists the `fn Type.name()` functions declared for the
// type of `decl`.
fn (mut app App) declared_static_functions(decl TypeDeclaration) []Detail {
	normalized_dir := normalized_index_path(decl.dir)
	prefix := '${decl.name}.'
	mut items := []Detail{}
	mut indexed_uris := app.symbol_index.keys()
	indexed_uris.sort()
	for indexed_uri in indexed_uris {
		entry := app.symbol_index[indexed_uri] or { continue }
		if normalized_index_path(os.dir(uri_to_path(indexed_uri))) != normalized_dir
			|| entry.module_name != decl.module_name {
			continue
		}
		source_lines := (app.index_source_for(indexed_uri) or { '' }).split_into_lines()
		for symbol in entry.doc_symbols {
			if symbol.kind != sym_kind_function || !symbol.name.starts_with(prefix) {
				continue
			}
			line_idx := symbol.range.start.line
			if line_idx < 0 || line_idx >= source_lines.len {
				continue
			}
			line := source_lines[line_idx].trim_space()
			if decl.require_public && !line.starts_with('pub ') {
				continue
			}
			after_fn := line.all_after('fn ').all_before('{').trim_space()
			paren := after_fn.index('(') or { continue }
			label := symbol.name[prefix.len..]
			insert := build_fn_snippet(label, after_fn[paren..])
			items << Detail{
				kind:               3 // CompletionItemKind.Function
				label:              label
				detail:             'fn ${after_fn}'
				insert_text:        insert
				insert_text_format: if insert.contains('\$') { 2 } else { 1 }
			}
		}
	}
	return items
}

// static_function_return_type returns what `Type.name(...)` returns.
fn (mut app App) static_function_return_type(uri string, content string, type_name string, name string) string {
	decl := app.type_declaration(uri, content, type_name)
	if decl.kind == '' {
		return ''
	}
	for item in app.declared_static_functions(decl) {
		if item.label == name {
			return qualify_member_type(signature_return_type(item.detail), type_name)
		}
	}
	for item in language_member_items(type_name, declaration_member_kinds(decl), true) {
		if item.label == name {
			return signature_return_type(item.detail)
		}
	}
	return ''
}

// member_expression_at_cursor returns the expression whose member is completed at
// `cursor_col`: `pts[0]` in `pts[0].fi`, `make_point()` in `make_point().`,
// `'abc'` in `'abc'.`. It is empty for a bare `.`.
fn member_expression_at_cursor(line string, cursor_col int, enc PositionEncoding) string {
	if line == '' || cursor_col <= 0 {
		return ''
	}
	cursor_byte := encoded_col_to_byte(line, cursor_col, enc)
	mut member_start := cursor_byte
	for member_start > 0 && is_ident_char(line[member_start - 1]) {
		member_start--
	}
	if member_start == 0 || line[member_start - 1] != `.` {
		return ''
	}
	dot := member_start - 1
	return line[expression_start_before(line, dot)..dot]
}

// expression_start_before returns where the operand that ends at `end` starts,
// walking back over identifiers, the dots and unwraps between them, balanced
// brackets and string literals.
fn expression_start_before(line string, end int) int {
	mut i := end
	for i > 0 {
		c := line[i - 1]
		if is_ident_char(c) {
			i--
		} else if c in [`)`, `]`, `}`] {
			open := opening_delimiter_before(line, i - 1)
			if open < 0 {
				break
			}
			i = open
		} else if c in [`'`, `"`, `\``] {
			open := line[..i - 1].last_index_u8(c)
			if open < 0 {
				break
			}
			i = open
			if i > 0 && line[i - 1] in [`r`, `c`] && (i == 1 || !is_ident_char(line[i - 2])) {
				i--
			}
		} else if c in [`.`, `!`, `?`] && i > 1
			&& (is_ident_char(line[i - 2]) || line[i - 2] in [`)`, `]`, `}`, `'`, `"`, `\``]) {
			i--
		} else {
			break
		}
	}
	return i
}

// opening_delimiter_before returns the index of the `(`, `[` or `{` matching the
// closing one at `close_idx`, or -1.
fn opening_delimiter_before(text string, close_idx int) int {
	close := text[close_idx]
	open := if close == `)` {
		`(`
	} else if close == `]` {
		`[`
	} else {
		`{`
	}
	mut depth := 0
	for i := close_idx; i >= 0; i-- {
		if text[i] == close {
			depth++
		} else if text[i] == open {
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// string_literal_end returns the index right after the string or rune literal at
// the start of `text` (`'...'`, `"..."`, `r'...'`, `c'...'`, a backquoted rune).
fn string_literal_end(text string) ?int {
	mut start := 0
	if text.len > 1 && text[0] in [`r`, `c`] && text[1] in [`'`, `"`] {
		start = 1
	}
	if start >= text.len || text[start] !in [`'`, `"`, `\``] {
		return none
	}
	quote := text[start]
	raw := start == 1 && text[0] == `r`
	mut i := start + 1
	for i < text.len {
		if text[i] == `\\` && !raw {
			i += 2
			continue
		}
		if text[i] == quote {
			return i + 1
		}
		i++
	}
	return none
}

// without_trailing_comment drops a `//` comment that ends `text`.
// type_at reads the complete type written at `start` and returns it with the
// index right after it, or an empty type when none starts there. A type is not
// always one word: `(int, string)`, `chan int`, `fn (a int) ?string`,
// `map[string][]&Point` and `Box[int]` are each a single type.
fn type_at(text string, start int) (string, int) {
	mut i := start
	for i < text.len && text[i] in [` `, `\t`] {
		i++
	}
	begin := i
	for i < text.len && text[i] in [`&`, `?`, `!`] {
		i++
	}
	if i + 3 <= text.len && text[i..i + 3] == '...' {
		i += 3
	}
	if i >= text.len {
		return '', start
	}
	if text[i] == `(` {
		// A tuple of results.
		close := matching_delimiter(text, i, `(`, `)`)
		if close < 0 {
			return '', start
		}
		return text[begin..close + 1], close + 1
	}
	if text[i] == `[` {
		// `[]T` and `[N]T`: the brackets, then the element type.
		close := matching_delimiter(text, i, `[`, `]`)
		if close < 0 {
			return '', start
		}
		elem, after := type_at(text, close + 1)
		if elem == '' {
			return '', start
		}
		return text[begin..close + 1] + elem, after
	}
	word_start := i
	for i < text.len && (is_ident_char(text[i]) || text[i] == `.`) {
		i++
	}
	if i == word_start {
		return '', start
	}
	word := text[word_start..i]
	prefix := text[begin..word_start]
	if word == 'fn' {
		// A function type: its parameters, then its own result, if any.
		mut j := i
		for j < text.len && text[j] in [` `, `\t`] {
			j++
		}
		if j < text.len && text[j] == `(` {
			close := matching_delimiter(text, j, `(`, `)`)
			if close < 0 {
				return '', start
			}
			result, after := type_at(text, close + 1)
			if result == '' {
				return '${prefix}fn ${text[j..close + 1]}', close + 1
			}
			return '${prefix}fn ${text[j..close + 1]} ${result}', after
		}
		return '${prefix}fn', i
	}
	if word == 'map' && i < text.len && text[i] == `[` {
		close := matching_delimiter(text, i, `[`, `]`)
		if close < 0 {
			return '', start
		}
		value, after := type_at(text, close + 1)
		if value == '' {
			return '', start
		}
		return prefix + text[word_start..close + 1] + value, after
	}
	if word in ['chan', 'thread', 'shared', 'atomic'] {
		// These spell their element type as a second word.
		elem, after := type_at(text, i)
		if elem != '' {
			return '${prefix}${word} ${elem}', after
		}
		return prefix + word, i
	}
	if i < text.len && text[i] == `[` {
		// Generic arguments written right after the name: `Box[int]`.
		close := matching_delimiter(text, i, `[`, `]`)
		if close > 0 {
			i = close + 1
		}
	}
	return text[begin..i], i
}

// function_literal_type renders the type of a function literal the way the
// source writes it, `fn (a int) string`, without the capture list, which is not
// part of the type, and without the body.
fn function_literal_type(expr string) ?string {
	if !expr.starts_with('fn') {
		return none
	}
	mut i := 2
	if i < expr.len && expr[i] !in [` `, `\t`, `(`, `[`] {
		return none
	}
	for i < expr.len && expr[i] in [` `, `\t`] {
		i++
	}
	if i < expr.len && expr[i] == `[` {
		capture_end := matching_delimiter(expr, i, `[`, `]`)
		if capture_end < 0 {
			return none
		}
		i = capture_end + 1
		for i < expr.len && expr[i] in [` `, `\t`] {
			i++
		}
	}
	if i >= expr.len || expr[i] != `(` {
		return none
	}
	params_end := matching_delimiter(expr, i, `(`, `)`)
	if params_end < 0 {
		return none
	}
	params := expr[i..params_end + 1]
	rest := expr[params_end + 1..]
	body_start := rest.index('{') or { rest.len }
	result := rest[..body_start].trim_space()
	if result == '' {
		return 'fn ${params}'
	}
	return 'fn ${params} ${result}'
}

fn without_trailing_comment(text string) string {
	mut i := 0
	for i < text.len {
		if text[i] in [`'`, `"`, `\``] {
			end := string_literal_end(text[i..]) or { return text }
			i += end
			continue
		}
		if text[i] == `/` && i + 1 < text.len && text[i + 1] == `/` {
			return text[..i]
		}
		i++
	}
	return text
}

// expression_type returns the type of `expr` as seen from `position` (`Point`,
// `[]int`, `map[string]Point`, `time.Time`), or '' when it cannot tell. It reads
// the operand the expression starts with (a binding, a literal, a call, a cast, a
// struct or array literal, a module or static function, `typeof`) and then each
// `.field`, `.method(...)`, `[index]`, `or {...}`, `!` and `?` after it. The type
// keeps the `&`, `?` and `!` the source declares; member lookup strips them.
fn (mut app App) expression_type(uri string, content string, expr string, position Position) string {
	// A binding's type can come from its declaration, which may name the binding
	// again (`x := x.next()`); stop before that loops.
	if app.expression_type_depth >= 8 {
		return ''
	}
	app.expression_type_depth++
	defer {
		app.expression_type_depth--
	}
	text := without_trailing_comment(expr).trim_space()
	if text == '' {
		return ''
	}
	mut typ, mut rest := app.operand_type(uri, content, text, position)
	for typ != '' && rest.trim_space() != '' {
		typ, rest = app.postfix_type(uri, content, typ, rest, position)
	}
	return typ
}

// operand_type reads the operand at the start of `text`, and returns its type and
// what follows it.
fn (mut app App) operand_type(uri string, content string, text string, position Position) (string, string) {
	if text == '' {
		return '', text
	}
	c := text[0]
	if c == `(` {
		close := matching_delimiter(text, 0, `(`, `)`)
		if close < 0 {
			return '', text
		}
		return app.expression_type(uri, content, text[1..close], position), text[close + 1..]
	}
	if c == `&` {
		if text.len == 1 {
			return '', text
		}
		typ, rest := app.operand_type(uri, content, text[1..].trim_space(), position)
		if typ == '' {
			return '', text
		}
		return '&${typ}', rest
	}
	if literal_end := string_literal_end(text) {
		typ := if c == `\`` {
			'rune'
		} else if c == `c` {
			'&u8'
		} else {
			'string'
		}
		return typ, text[literal_end..]
	}
	if c.is_digit() || (c == `-` && text.len > 1 && text[1].is_digit()) {
		mut end := 1
		mut is_float := false
		for end < text.len {
			ch := text[end]
			if ch.is_digit() || ch == `_` || ch.is_letter() {
				end++
			} else if ch == `.` && end + 1 < text.len && text[end + 1].is_digit() {
				is_float = true
				end++
			} else {
				break
			}
		}
		number := text[..end].to_lower().trim_left('-')
		if !number.starts_with('0x') && number.contains('e') {
			is_float = true
		}
		return if is_float { 'f64' } else { 'int' }, text[end..]
	}
	if c == `[` {
		return app.array_operand_type(uri, content, text, position)
	}
	if text.starts_with('map[') {
		close := matching_delimiter(text, 3, `[`, `]`)
		if close < 0 {
			return '', text
		}
		brace_rel := text[close..].index('{') or { return '', text }
		brace := close + brace_rel
		end := matching_delimiter(text, brace, `{`, `}`)
		if end < 0 {
			return '', text
		}
		return text[..brace].trim_space(), text[end + 1..]
	}
	if !is_ident_start(c) {
		return '', text
	}
	mut end := 0
	for end < text.len && is_ident_char(text[end]) {
		end++
	}
	name := text[..end]
	rest := text[end..]
	if name == 'typeof' {
		return typeof_operand(rest)
	}
	if rest.starts_with('{') && is_type_name(name) {
		close := matching_delimiter(rest, 0, `{`, `}`)
		if close < 0 {
			return '', text
		}
		return name, rest[close + 1..]
	}
	if rest.starts_with('(') {
		close := matching_delimiter(rest, 0, `(`, `)`)
		if close < 0 {
			return '', text
		}
		if name in builtin_receiver_types || is_type_name(name) {
			// A cast: `i64(5)`, `Meters(1.5)`.
			return name, rest[close + 1..]
		}
		return app.function_return_type_raw(uri, content, name), rest[close + 1..]
	}
	if rest.starts_with('.') && !app.local_scope_bindings(content, position).any(it.name == name) {
		mut member_end := 1
		for member_end < rest.len && is_ident_char(rest[member_end]) {
			member_end++
		}
		member := rest[1..member_end]
		after := rest[member_end..]
		if member != '' && name in parse_import_aliases(content) {
			// `time.now()`, `geo.Point{}`, `geo.Meters(2)`
			qualified := '${name}.${member}'
			if after.starts_with('(') || after.starts_with('{') {
				closing := if after[0] == `(` { `)` } else { `}` }
				close := matching_delimiter(after, 0, after[0], closing)
				if close < 0 {
					return '', text
				}
				if is_type_name(member) {
					return qualified, after[close + 1..]
				}
				if after[0] == `(` {
					return app.function_return_type_raw(uri, content, qualified), after[close + 1..]
				}
			}
			return '', text
		}
		if member != '' && is_type_name(name) {
			// `Color.red`, `Color.first()`, `Point.origin()`
			if after.starts_with('(') {
				close := matching_delimiter(after, 0, `(`, `)`)
				if close < 0 {
					return '', text
				}
				return app.static_function_return_type(uri, content, name, member), after[close + 1..]
			}
			if app.type_declaration(uri, content, name).kind == 'enum' {
				return name, after
			}
			return '', text
		}
	}
	lines := content.split_into_lines()
	if narrowed := smart_cast_type(lines, position, name, app.position_encoding) {
		return narrowed, rest
	}
	return app.infer_binding_type_at_position(uri, content, name, position), rest
}

// typeof_operand reads `(x)` or `[T]()` after `typeof`.
fn typeof_operand(rest string) (string, string) {
	mut open := 0
	if rest.starts_with('[') {
		open = matching_delimiter(rest, 0, `[`, `]`) + 1
		if open <= 0 {
			return '', rest
		}
	}
	if open >= rest.len || rest[open] != `(` {
		return '', rest
	}
	close := matching_delimiter(rest, open, `(`, `)`)
	if close < 0 {
		return '', rest
	}
	return 'typeof', rest[close + 1..]
}

// array_operand_type reads an array literal: `[]T{...}` and `[N]T{...}` name their
// type, `[a, b]` takes it from its first element, and `[a, b]!` is fixed.
fn (mut app App) array_operand_type(uri string, content string, text string, position Position) (string, string) {
	close := matching_delimiter(text, 0, `[`, `]`)
	if close < 0 {
		return '', text
	}
	after := text[close + 1..]
	if after.len > 0 && (is_ident_start(after[0]) || after[0] in [`[`, `&`, `?`]) {
		brace := after.index('{') or { return '', text }
		end := matching_delimiter(after, brace, `{`, `}`)
		if end < 0 {
			return '', text
		}
		return (text[..close + 1] + after[..brace]).trim_space(), after[end + 1..]
	}
	elements := split_top_level_commas(text[1..close])
	if elements.len == 0 || elements[0].trim_space() == '' {
		return '', text
	}
	elem := app.expression_type(uri, content, elements[0], position)
	if elem == '' {
		return '', text
	}
	if after.starts_with('!') {
		return '[${elements.len}]${elem}', after[1..]
	}
	return '[]${elem}', after
}

// postfix_type applies the selector, call, index or unwrap that starts `text` to a
// value of type `typ`, and returns the resulting type and what follows.
fn (mut app App) postfix_type(uri string, content string, typ string, text string, position Position) (string, string) {
	rest := text.trim_left(' \t')
	if rest.starts_with('as ') {
		// `f as Point`
		target := rest[3..].trim_left(' ')
		mut end := 0
		for end < target.len && (is_ident_char(target[end]) || target[end] == `.`) {
			end++
		}
		if end == 0 {
			return '', text
		}
		return target[..end], target[end..]
	}
	if rest.starts_with('or ') || rest.starts_with('or{') {
		brace := rest.index('{') or { return '', text }
		end := matching_delimiter(rest, brace, `{`, `}`)
		if end < 0 {
			return '', text
		}
		return unwrap_option_type(typ), rest[end + 1..]
	}
	if rest.starts_with('!') || rest.starts_with('?') {
		return unwrap_option_type(typ), rest[1..]
	}
	if rest.starts_with('[') {
		close := matching_delimiter(rest, 0, `[`, `]`)
		if close < 0 {
			return '', text
		}
		after := rest[close + 1..]
		if top_level_slice_range(rest[1..close]) {
			return slice_result_type(typ), after
		}
		return index_expression_type(typ), after
	}
	if !rest.starts_with('.') {
		return '', text
	}
	mut end := 1
	for end < rest.len && is_ident_char(rest[end]) {
		end++
	}
	name := rest[1..end]
	after := rest[end..]
	if name == '' {
		return '', text
	}
	if !after.starts_with('(') {
		return app.member_type(uri, content, typ, name), after
	}
	close := matching_delimiter(after, 0, `(`, `)`)
	if close < 0 {
		return '', text
	}
	receiver := member_receiver_type(typ)
	elem, _, _ := composite_type_parts(receiver)
	if name == 'map' && receiver.starts_with('[') && elem != '' {
		// `map` returns an array of whatever its callback returns.
		result := app.callback_result_type(uri, content, elem, after[1..close], position)
		return if result == '' { '' } else { '[]${result}' }, after[close + 1..]
	}
	return app.member_type(uri, content, typ, name), after[close + 1..]
}

// callback_result_type returns what the callback `arg` of `arr.map(arg)` returns
// for elements of type `elem`: `it` and expressions on it, a function literal's
// return type, or the type of any other expression.
fn (mut app App) callback_result_type(uri string, content string, elem string, arg string, position Position) string {
	a := arg.trim_space()
	if a.starts_with('fn ') || a.starts_with('fn(') {
		return fn_literal_return_type(a)
	}
	if a == 'it' || a.starts_with('it.') || a.starts_with('it[') || a.starts_with('it ') {
		mut typ := elem
		mut rest := a[2..]
		for typ != '' && rest.trim_space() != '' {
			next, next_rest := app.postfix_type(uri, content, typ, rest, position)
			if next == '' {
				return binary_result_type(typ, rest)
			}
			typ, rest = next, next_rest
		}
		return typ
	}
	return app.expression_type(uri, content, a, position)
}

// binary_result_type returns the type of `left <operator> ...` for a left operand
// of type `left`: a comparison is a bool and arithmetic keeps the operand's type.
fn binary_result_type(left string, operator_and_rest string) string {
	op := operator_and_rest.trim_space()
	if op.starts_with('==') || op.starts_with('!=') || op.starts_with('<') || op.starts_with('>')
		|| op.starts_with('&&') || op.starts_with('||') || op.starts_with('in ')
		|| op.starts_with('!in ') {
		return 'bool'
	}
	if op.len > 0 && op[0] in [`+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`] {
		return left
	}
	return ''
}

// smart_cast_type returns the type `name` is narrowed to at `position`: `T` in the
// `T {` branch of `match name {`, or in the body of `if name is T {`.
fn smart_cast_type(lines []string, position Position, name string, enc PositionEncoding) ?string {
	if position.line < 0 || position.line >= lines.len {
		return none
	}
	mut depth := 0
	mut branch := ''
	for i := position.line; i >= 0; i-- {
		text := if i == position.line {
			lines[i][..encoded_col_to_byte(lines[i], position.char, enc)]
		} else {
			lines[i]
		}
		for j := text.len - 1; j >= 0; j-- {
			if text[j] == `}` {
				depth++
				continue
			}
			if text[j] != `{` {
				continue
			}
			if depth > 0 {
				depth--
				continue
			}
			header := text[..j].trim_space()
			if narrowed := is_check_type(header, name) {
				return narrowed
			}
			if branch != '' {
				if subject := match_header_subject(header) {
					if subject == name {
						return branch
					}
				}
			}
			branch = if is_type_name(header) && header.bytes().all(is_ident_char(it) || it == `.`) {
				header
			} else {
				''
			}
		}
	}
	return none
}

// is_check_type returns `T` when the condition in `header` checks `name is T`.
fn is_check_type(header string, name string) ?string {
	if !(header.starts_with('if ') || header.contains(' if ')) {
		return none
	}
	mut from := 0
	for {
		rel := header[from..].index(' is ') or { return none }
		idx := from + rel
		left := header[..idx].trim_space()
		mut start := left.len
		for start > 0 && (is_ident_char(left[start - 1]) || left[start - 1] == `.`) {
			start--
		}
		if left[start..] == name {
			right := header[idx + ' is '.len..].trim_space()
			mut end := 0
			for end < right.len && (is_ident_char(right[end]) || right[end] == `.`) {
				end++
			}
			if end > 0 {
				return right[..end]
			}
		}
		from = idx + ' is '.len
	}
	return none
}

// match_header_subject returns `x` for the header `match x` (or `match mut x`).
fn match_header_subject(header string) ?string {
	idx := header.index('match ') or { return none }
	if idx > 0 && is_ident_char(header[idx - 1]) {
		return none
	}
	subject := header[idx + 'match '.len..].trim_space().trim_string_left('mut ').trim_space()
	return if subject == '' { none } else { subject }
}
