module analyzer

import os
import analyzer.depgraph

pub struct Store {
mut:
	anon_fn_counter int = 1
pub mut:
	// The current file used
	// e.g. /dir/foo.v
	cur_file_path string
	// The current directory of the file used
	// e.g. /dir
	cur_dir string
	// The file name of the current file
	// e.g. foo.v
	cur_file_name string
	// Current version of the file
	cur_version int
	// List of imports per directory
	// map goes: map[<full dir path>][]Import
	imports map[string][]Import
	// Hack-free way for auto-injected dependencies
	// to get referenced. This uses module name instead of
	// full path since the most common autoinjected modules
	// are on the vlib path.
	// map goes: map[<module name>]<aliased path>
	auto_imports map[string]string
	// Dependency tree. Used for tracking dependencies
	// as basis for removing symbols/scopes/imports
	// tree goes: tree[<full dir path>][]<full dir path>
	dependency_tree depgraph.Tree
	// Used for diagnostics
	messages []Message
	// Symbol table
	// map goes: map[<full dir path>]map[]&Symbol
	symbols map[string][]&Symbol
	// Scope data for different opened files
	// map goes: map[<full file path>]&ScopeTree
	opened_scopes map[string]&ScopeTree
	// paths to be imported aside from the ones
	// specified from lookup paths specified from
	// import_modules_from_tree
	default_import_paths []string
	// Another hack-free way to get symbol information
	// from base symbols for specific container kinds.
	// (e.g. []string should not be looked up only inside
	// []string but also in builtin's array type as well)
	base_symbol_locations []BaseSymbolLocation
	// Locations to the registered binded symbols (a.k.a C.Foo or JS.document)
	binded_symbol_locations []BindedSymbolLocation
}

// clear_messages clears the stored messages
pub fn (mut ss Store) clear_messages() {
	for i := 0; ss.messages.len != 0; {
		// msg := ss.messages[i]
		// unsafe {
		// 	msg.content.free()
		// }

		ss.messages.delete(i)
	}
}

// report inserts the message to the messages array
pub fn (mut ss Store) report(msg Message) {
	if ss.messages.has_range(msg.file_path, msg.range) {
		return
	}
	ss.messages << msg
}

// is_file_active returns a boolean that checks if the given
// file_path is the same as the current file path stored in the store
pub fn (ss &Store) is_file_active(file_path string) bool {
	return ss.cur_file_path == file_path
}

// set_active_file_path sets the current path and current version of the file
// to the store. The `cur_file_path` and its related fields are oftenly used
// in symbol registration, import location, and etc.
pub fn (mut ss Store) set_active_file_path(file_path string, version int) {
	ss.cur_version = version

	if ss.is_file_active(file_path) {
		return
	}

	// $if !macos {
	// 	unsafe {
	// 		if !isnil(ss.cur_file_path) {
	// 			ss.cur_file_path.free()
	// 		}

	// 		if !isnil(ss.cur_file_name) {
	// 			ss.cur_file_name.free()
	// 		}

	// 		if !isnil(ss.cur_dir) {
	// 			ss.cur_dir.free()
	// 		}
	// 	}
	// }

	ss.cur_file_path = file_path
	ss.cur_dir = os.dir(file_path)
	ss.cur_file_name = os.base(file_path)
}

// get_module_path_opt is a variant of `get_module_path` that returns
// an optional if not found
pub fn (ss &Store) get_module_path_opt(module_name string) ?string {
	import_lists := ss.imports[ss.cur_dir]
	for imp in import_lists {
		if imp.module_name == module_name {
			return imp.path
		}

		if ss.cur_file_name in imp.aliases && imp.aliases[ss.cur_file_name] == module_name {
			return imp.path
		}
	}

	return error('Not found')
}

// get_module_path returns the path of the import/module based
// on the given module name. If nothing found, it will return
// the current directory instead.
pub fn (ss &Store) get_module_path(module_name string) string {
	// empty names should return the current selected dir instead
	return ss.get_module_path_opt(module_name) or { ss.cur_dir }
}

// find_symbol retrieves the symbol based on the given module name and symbol name
pub fn (ss &Store) find_symbol(module_name string, name string) ?&Symbol {
	if name.len == 0 {
		return error('Name is empty.')
	}

	module_path := ss.get_module_path(module_name)
	idx := ss.symbols[module_path].index(name)
	if idx != -1 {
		return ss.symbols[module_path][idx]
	}

	if aliased_path := ss.auto_imports[module_name] {
		idx_from_alias := ss.symbols[aliased_path].index(name)
		if idx_from_alias != -1 {
			return ss.symbols[aliased_path][idx_from_alias]
		}
	}

	// Find C.Foo or JS.Foo
	if binded_module_path := ss.binded_symbol_locations.get_path(name) {
		idx_from_binded := ss.symbols[binded_module_path].index(name)
		if idx_from_binded != -1 {
			return ss.symbols[binded_module_path][idx_from_binded]
		}
	}

	return error('Symbol `$name` not found.')
}

const anon_fn_prefix = '#anon_'

// find_fn_symbol finds the function symbol with the appropriate parameters and return type
pub fn (ss &Store) find_fn_symbol(module_name string, return_type &Symbol, params []&Symbol) ?&Symbol {
	module_path := ss.get_module_path(module_name)
	for sym in ss.symbols[module_path] ? {
		if sym.kind == .function_type && sym.name.starts_with(analyzer.anon_fn_prefix)
			&& sym.generic_placeholder_len == 0 {
			if !compare_params_and_ret_type(params, return_type, sym, true) {
				continue
			}
			return sym
		}
	}
	return none
}

pub fn compare_params_and_ret_type(params []&Symbol, ret_type &Symbol, fn_to_compare &Symbol, include_param_name bool) bool {
	mut params_to_check := []int{cap: fn_to_compare.children.len}
	// defer {
	// 	unsafe { params_to_check.free() }
	// }

	// get a list of indices that are parameters
	for i, child in fn_to_compare.children {
		if child.kind != .variable {
			continue
		}
		params_to_check << i
	}
	if params.len != params_to_check.len {
		return false
	}
	mut params_left := params_to_check.len
	for i, param_idx in params_to_check {
		param_from_sym := fn_to_compare.children[param_idx]
		param_to_compare := params[i]
		if param_from_sym.return_type == param_to_compare.return_type {
			if include_param_name && param_from_sym.name != param_to_compare.name {
				break
			}
			params_left--
			continue
		}
		break
	}
	if params_left != 0 || ret_type != fn_to_compare.return_type {
		return false
	}
	return true
}

pub const container_symbol_kinds = [SymbolKind.chan_, .array_, .map_, .ref, .variadic, .optional,
	.multi_return,
]

// register_symbol registers the given symbol
pub fn (mut ss Store) register_symbol(mut info Symbol) ?&Symbol {
	dir := os.dir(info.file_path)
	// defer {
	// 	unsafe { dir.free() }
	// }
	mut existing_idx := ss.symbols[dir].index(info.name)
	if existing_idx == -1 && info.kind != .placeholder
		&& info.kind !in analyzer.container_symbol_kinds {
		// find by row
		existing_idx = ss.symbols[dir].index_by_row(info.file_path, info.range.start_point.row)
	}

	// Replace symbol if symbol already exists
	// the info.kind condition is used for typedefs with anon fn types
	if existing_idx != -1
		&& (info.kind != .typedef && ss.symbols[dir][existing_idx].kind != .function_type) {
		mut existing_sym := ss.symbols[dir][existing_idx]
		if existing_sym.file_version == info.file_version && existing_sym.name == info.name
			&& existing_sym.range.eq(info.range) && existing_sym.kind == info.kind {
			return existing_sym
		}

		// Remove this?
		if existing_sym.kind !in analyzer.container_symbol_kinds {
			if (existing_sym.kind != .placeholder && existing_sym.kind == info.kind)
				&& (existing_sym.file_path == info.file_path
				&& existing_sym.file_version >= info.file_version) {
				return report_error('Symbol already exists. (idx=$existing_idx) (name="$existing_sym.name")',
					info.range)
			}

			if existing_sym.name != info.name {
				// unsafe { existing_sym.name.free() }
				existing_sym.name = info.name.clone()
			}

			if existing_sym.children.len != 0 {
				// Add children to existing symbol's children
				// if not empty.

				// unsafe { existing_sym.children.free() }
				existing_sym.children << info.children
				// unsafe { info.children.free() }
			} else {
				// Replace the content if it is.
				existing_sym.children = info.children
			}

			existing_sym.parent = info.parent
			existing_sym.return_type = info.return_type
			existing_sym.language = info.language
			existing_sym.access = info.access
			existing_sym.kind = info.kind
			existing_sym.range = info.range
			existing_sym.generic_placeholder_len = info.generic_placeholder_len
			existing_sym.file_path = info.file_path
			existing_sym.file_version = info.file_version
		}

		return existing_sym
	}

	ss.symbols[dir] << info
	if info.language != .v {
		ss.binded_symbol_locations << BindedSymbolLocation{
			for_sym_name: info.name,
			module_path: os.dir(info.file_path)
		}
	}

	return unsafe { info }
}

// add_imports adds/registers the import. it returns a boolean
// to indicate if the import already exist in the array.
pub fn (mut ss Store) add_import(imp Import) (&Import, bool) {
	dir := ss.cur_dir
	mut idx := -1
	if dir in ss.imports {
		// check if import has already imported
		for i, stored_imp in ss.imports[dir] {
			if imp.absolute_module_name == stored_imp.absolute_module_name {
				idx = i
				break
			}
		}
	} else {
		ss.imports[dir] = []Import{}
	}

	if idx == -1 {
		ss.imports[dir] << Import{
			...imp
			module_name: imp.absolute_module_name.all_after_last('.')
			resolved: imp.resolved || imp.path.len != 0
		}

		last_idx := ss.imports[dir].len - 1
		return &ss.imports[dir][last_idx], false
	} else {
		// unsafe { imp.free() }
		return &ss.imports[dir][idx], true
	}
}

// get_symbols_by_file_path retrieves the symbols based on the given file path
pub fn (ss &Store) get_symbols_by_file_path(file_path string) []&Symbol {
	dir := os.dir(file_path)
	// defer {
	// 	unsafe { dir.free() }
	// }

	if dir in ss.symbols {
		return ss.symbols[dir].filter_by_file_path(file_path)
	}

	return []
}

// has_file_path checks if the data of a specific file_path already exists
pub fn (ss &Store) has_file_path(file_path string) bool {
	dir := os.dir(file_path)
	// defer {
	// 	unsafe { dir.free() }
	// }
	if dir in ss.symbols {
		for _, mut sym in ss.symbols[dir] {
			if sym.file_path == file_path {
				return true
			}
		}
	}
	return false
}

// delete removes the given path of a workspace/project if possible.
// The directory is only deleted if there are no projects dependent on it.
// It also removes the dependencies with the same condition
pub fn (mut ss Store) delete(dir string, excluded_dir ...string) {
	// do not delete data if dir is an auto import!
	for _, path in ss.auto_imports {
		if path == dir {
			// return immediately if found
			return
		}
	}

	is_used := ss.dependency_tree.has_dependents(dir, ...excluded_dir)
	if is_used {
		return
	}

	if dep_node := ss.dependency_tree.get_node(dir) {
		// get all dependencies
		all_dependencies := dep_node.get_all_dependencies()

		// delete all dependencies if possible
		for dep in all_dependencies {
			ss.delete(dep, dir)
		}

		// delete dir in dependency tree
		ss.dependency_tree.delete(dir)
	}

	// delete all imports from unused dir
	if !is_used {
		unsafe {
			// delete symbols and imports
			// for _, sym in ss.symbols[dir] {
			// 	sym.free()
			// }

			// ss.symbols[dir].free()
		}
		ss.symbols.delete(dir)
		for i := 0; ss.imports[dir].len != 0; {
			// unsafe { ss.imports[dir][i].free() }
			ss.imports[dir].delete(i)
		}
	}
}

// get_scope_from_node returns a scope based on the given node
pub fn (mut ss Store) get_scope_from_node(node C.TSNode) ?&ScopeTree {
	if node.is_null() {
		return error('unable to create scope')
	}

	if node.get_type() == 'source_file' {
		if ss.cur_file_path !in ss.opened_scopes {
			ss.opened_scopes[ss.cur_file_path] = &ScopeTree{
				start_byte: node.start_byte()
				end_byte: node.end_byte()
			}
		}

		return ss.opened_scopes[ss.cur_file_path]
	} else {
		return ss.opened_scopes[ss.cur_file_path].new_child(node.start_byte(), node.end_byte())
	}
}

// symbol_name_from_node extracts the symbol's kind, name, and module name from the given node
pub fn symbol_name_from_node(node C.TSNode, src_text []byte) (SymbolKind, string, string) {
	if node.is_null() {
		return SymbolKind.typedef, '', 'void'
	}

	mut module_name := ''
	mut symbol_name := ''
	// unsafe {
	// 	module_name.free()
	// 	symbol_name.free()
	// }
	match node.get_type() {
		'qualified_type' {
			module_name = node.child_by_field_name('module').get_text(src_text)
			symbol_name = node.child_by_field_name('name').get_text(src_text)
			return SymbolKind.placeholder, module_name, symbol_name
		}
		'pointer_type' {
			_, module_name, symbol_name = symbol_name_from_node(node.named_child(0), src_text)
			return SymbolKind.ref, module_name, '&' + symbol_name
		}
		'array_type', 'fixed_array_type' {
			mut limit := ''
			limit_field := node.child_by_field_name('limit')
			if !limit_field.is_null() {
				limit = node.get_text(src_text)
			}

			_, module_name, symbol_name = symbol_name_from_node(node.child_by_field_name('element'),
				src_text)
			return SymbolKind.array_, module_name, '[$limit]' + symbol_name
		}
		'map_type' {
			_, key_module_name, key_symbol_name := symbol_name_from_node(node.child_by_field_name('key'),
				src_text)
			_, val_module_name, val_symbol_name := symbol_name_from_node(node.child_by_field_name('value'),
				src_text)
			if (key_module_name.len != 0 && val_module_name.len == 0)
				|| (key_module_name == val_module_name) {
				// unsafe {
				// 	val_module_name.free()
				// 	val_symbol_name.free()
				// }
				// if key type uses a custom type, return the symbol in the key's origin module
				return SymbolKind.map_, key_module_name, 'map[$key_symbol_name]' +
					node.child_by_field_name('value').get_text(src_text)
				// if key is builtin type and key type is not, use the module from the value type
			} else if key_module_name.len == 0 && val_module_name.len != 0 {
				// unsafe {
				// 	key_module_name.free()
				// 	key_symbol_name.free()
				// }
				return SymbolKind.map_, val_module_name, 'map[' +
					node.child_by_field_name('key').get_text(src_text) + ']$val_symbol_name'
			} else {
				module_name = ''
			}

			return SymbolKind.map_, '', node.get_text(src_text)
		}
		'generic_type' {
			return symbol_name_from_node(node.named_child(0), src_text)
		}
		'channel_type' {
			_, module_name, symbol_name = symbol_name_from_node(node.named_child(0), src_text)
			return SymbolKind.chan_, module_name, 'chan ' + symbol_name
		}
		'option_type' {
			_, module_name, symbol_name = symbol_name_from_node(node.named_child(0), src_text)
			if symbol_name == 'void' {
				return SymbolKind.optional, module_name, '?'
			}
			return SymbolKind.optional, module_name, '?' + symbol_name
		}
		'function_type' {
			return SymbolKind.function_type, module_name, symbol_name
		}
		'variadic_type' {
			_, module_name, symbol_name = symbol_name_from_node(node.named_child(0), src_text)
			return SymbolKind.variadic, module_name, '...' + symbol_name
		}
		else {
			// unsafe { symbol_name.free() }
			// type_identifier should go here
			return SymbolKind.placeholder, module_name, node.get_text(src_text)
		}
	}

	return SymbolKind.typedef, '', 'void'
}

// find_symbol_by_type_node returns a symbol based on the given type node
pub fn (mut store Store) find_symbol_by_type_node(node C.TSNode, src_text []byte) ?&Symbol {
	if node.is_null() || src_text.len == 0 {
		return none
	}

	sym_kind, module_name, symbol_name := symbol_name_from_node(node, src_text)
	// defer {
	// 	unsafe {
	// 		module_name.free()
	// 		symbol_name.free()
	// 	}
	// }

	if sym_kind == .function_type {
		mut parameters := extract_parameter_list(node.child_by_field_name('parameters'), mut
			store, src_text)
		return_type := store.find_symbol_by_type_node(node.child_by_field_name('result'),
			src_text) or { analyzer.void_type }
		return store.find_fn_symbol(module_name, return_type, parameters) or {
			mut new_sym := Symbol{
				name: analyzer.anon_fn_prefix + store.anon_fn_counter.str()
				file_path: store.cur_file_path.clone()
				file_version: store.cur_version
				is_top_level: true
				kind: sym_kind
				return_type: return_type
			}

			for mut param in parameters {
				new_sym.add_child(mut *param) or { continue }
			}

			store.anon_fn_counter++
			store.register_symbol(mut new_sym) or { analyzer.void_type }
		}
	}

	return store.find_symbol(module_name, symbol_name) or {
		mut new_sym := Symbol{
			name: symbol_name.clone()
			is_top_level: true
			file_path: os.join_path(store.get_module_path(module_name), 'placeholder.vv')
			file_version: 0
			kind: sym_kind
		}

		match sym_kind {
			.array_, .variadic {
				mut el_sym := store.find_symbol_by_type_node(node.child_by_field_name('element'),
					src_text) ?
				new_sym.add_child(mut el_sym, false) or {}
			}
			.map_ {
				mut key_sym := store.find_symbol_by_type_node(node.child_by_field_name('key'),
					src_text) ?
				new_sym.add_child(mut key_sym, false) or {}
				mut val_sym := store.find_symbol_by_type_node(node.child_by_field_name('value'),
					src_text) ?
				new_sym.add_child(mut val_sym, false) or {}
			}
			.chan_, .ref, .optional {
				if symbol_name != '?' {
					mut ref_sym := store.find_symbol_by_type_node(node.named_child(0), src_text) ?
					new_sym.parent = ref_sym
				}
			}
			else {}
		}

		store.register_symbol(mut new_sym) ?
	}
}

// infer_symbol_from_node returns the specified symbol based on the given node.
// This is different from infer_value_type_from_node as this returns the symbol
// instead of symbol's return type or parent for example
pub fn (mut ss Store) infer_symbol_from_node(node C.TSNode, src_text []byte) ?&Symbol {
	if node.is_null() {
		return none
	}

	node_type := node.get_type()
	mut module_name := ''
	mut type_name := ''

	// defer {
	// 	unsafe {
	// 		// node_type.free()
	// 		module_name.free()
	// 		type_name.free()
	// 	}
	// }

	match node_type {
		'identifier', 'binded_identifier' {
			// Identifier symbol finding strategy
			// Find first in symbols
			// find the symbol in scopes
			// return void if none
			ident_text := node.get_text(src_text)
			return ss.opened_scopes[ss.cur_file_path].get_symbol_with_range(ident_text,
				node.range()) or { ss.find_symbol(module_name, ident_text) ? }
		}
		'field_identifier' {
			mut parent := node.parent()
			for parent.get_type() in ['keyed_element', 'literal_value'] {
				parent = parent.parent()
			}

			parent_sym := ss.infer_symbol_from_node(parent, src_text) or { analyzer.void_type }
			ident_text := node.get_text(src_text)
			if !parent_sym.is_void() {
				if parent.get_type() == 'struct_field_declaration' {
					return parent_sym
				} else if child_sym := parent_sym.children.get(ident_text) {
					return child_sym
				}
			}

			return ss.find_symbol(module_name, ident_text) or {
				ss.opened_scopes[ss.cur_file_path].get_symbol_with_range(ident_text, node.range()) ?
			}
		}
		'type_selector_expression' {
			// TODO: assignment_declaration
			// if parent.get_type() != 'literal_value' {
			// 	parent = parent.parent()
			// }
			type_node := node.child_by_field_name('type')
			field_node := node.child_by_field_name('field_name')

			if !type_node.is_null() {
				parent_sym := ss.infer_symbol_from_node(type_node, src_text) ?
				child_sym := parent_sym.children.get(field_node.get_text(src_text)) ?

				return child_sym
			} else {
				// for shorhand enum
				enum_value := field_node.get_text(src_text)
				for sym in ss.symbols[ss.cur_dir] {
					if sym.kind != .enum_ {
						continue
					}
					enum_member := sym.children.get(enum_value) or { continue }
					return enum_member
				}
			}
		}
		'type_initializer' {
			return ss.find_symbol_by_type_node(node.child_by_field_name('type'), src_text)
		}
		'type_identifier', 'array_type', 'map_type', 'pointer_type', 'variadic_type',
		'builtin_type' {
			return ss.find_symbol_by_type_node(node, src_text)
		}
		'selector_expression' {
			operand := node.child_by_field_name('operand')
			mut root_sym := ss.infer_symbol_from_node(operand, src_text) or { analyzer.void_type }
			if !root_sym.is_void() {
				if root_sym.is_returnable() {
					root_sym = root_sym.return_type
				}
				child_name := node.child_by_field_name('field').get_text(src_text)
				return root_sym.children.get(child_name) or {
					if root_sym.kind == .ref {
						root_sym = root_sym.parent
					} else {
						for base_sym_loc in ss.base_symbol_locations {
							if base_sym_loc.for_kind == root_sym.kind {
								root_sym = ss.find_symbol(base_sym_loc.module_name, base_sym_loc.symbol_name) or {
									continue
								}
								break
							}
						}
					}

					root_sym.children.get(child_name) or { analyzer.void_type }
				}
			}

			if operand.get_type() != 'identifier' {
				return none
			}

			module_name = node.child_by_field_name('operand').get_text(src_text)
			type_name = node.child_by_field_name('field').get_text(src_text)
		}
		'keyed_element' {
			mut parent := node.parent()
			if parent.get_type() == 'literal_value' || parent.get_type() == 'map' {
				parent = parent.parent()
			}
			mut selected_node := node.child_by_field_name('name')
			if !selected_node.get_type().ends_with('identifier') {
				selected_node = node.child_by_field_name('value')
			}
			if parent.get_type() == 'literal_value' {
				parent_sym := ss.infer_symbol_from_node(parent, src_text) ?
				return parent_sym.children.get(selected_node.get_text(src_text)) or {
					if parent_sym.name == 'map' || parent_sym.name == 'array' {
						return ss.infer_symbol_from_node(selected_node, src_text)
					}
					return err
				}
			} else {
				return ss.infer_symbol_from_node(selected_node, src_text)
			}
		}
		'call_expression' {
			return ss.infer_symbol_from_node(node.child_by_field_name('function'), src_text)
		}
		'parameter_declaration' {
			mut parent := node.parent()
			for parent.get_type() !in ['function_declaration', 'interface_spec'] {
				parent = parent.parent()
				if parent.is_null() {
					return none
				}
			}

			if parent.get_type() == 'function_declaration' {
				parent = parent.child_by_field_name('name')
			}

			parent_sym := ss.infer_symbol_from_node(parent, src_text) ?
			child_sym := parent_sym.children.get(node.child_by_field_name('name').get_text(src_text)) ?
			return child_sym
		}
		'struct_field_declaration', 'interface_spec' {
			mut parent := node.parent()
			for parent.get_type() !in ['struct_declaration', 'interface_declaration'] {
				parent = parent.parent()
				if parent.is_null() {
					return none
				}
			}

			// eprintln(parent.get_type())
			parent_sym := ss.infer_symbol_from_node(parent.child_by_field_name('name'),
				src_text) ?
			child_sym := parent_sym.children.get(node.child_by_field_name('name').get_text(src_text)) ?
			return child_sym
		}
		'function_declaration' {
			receiver_node := node.child_by_field_name('receiver')
			name_node := node.child_by_field_name('name')
			mut receiver_param_count := u32(0)
			if !receiver_node.is_null() {
				receiver_param_count = receiver_node.named_child_count()
			}

			if receiver_param_count != 0 {
				receiver_param_node := receiver_node.named_child(0)
				parent_sym := ss.infer_symbol_from_node(receiver_param_node.child_by_field_name('type'),
					src_text) ?
				child_sym := parent_sym.children.get(name_node.get_text(src_text)) ?
				return child_sym
			} else {
				return ss.infer_symbol_from_node(name_node, src_text)
			}
		}
		else {
			// eprintln(node_type)
			// eprintln(node.parent().get_type())
			// return analyzer.void_type
		}
	}

	return ss.find_symbol(module_name, type_name)
}

// infer_value_type_from_node returns the symbol based on the given node
pub fn (mut ss Store) infer_value_type_from_node(node C.TSNode, src_text []byte) &Symbol {
	if node.is_null() {
		return analyzer.void_type
	}

	mut type_name := ''
	// defer {
	// 	unsafe { type_name.free() }
	// }
	node_type := node.get_type()
	match node_type {
		'true', 'false' {
			type_name = 'bool'
		}
		'int_literal' {
			type_name = 'int'
		}
		'float_literal' {
			type_name = 'f32'
		}
		'rune_literal' {
			type_name = 'byte'
		}
		'interpreted_string_literal' {
			type_name = 'string'
		}
		'range' {
			// TODO: detect starting and ending types
			type_name = '[]int'
		}
		'binary_expression' {
			// TODO:
			left_node := node.child_by_field_name('left')
			// op_node := node.child_by_field_name('operator')
			// right_node := node.child_by_field_name('right')
			mut left_sym := ss.infer_value_type_from_node(left_node, src_text)
			if left_sym.is_returnable() {
				left_sym = left_sym.return_type
			}
			// right_sym := ss.infer_value_type_from_node(right_node.get_text(src_text))
			return left_sym
		}
		'unary_expression' {
			operator_node := node.child_by_field_name('operator')
			operand_node := node.child_by_field_name('operand')
			mut op_sym := ss.infer_value_type_from_node(operand_node, src_text)
			if op_sym.is_returnable() {
				op_sym = op_sym.return_type
			}

			operator_type := operator_node.get_type()
			if operator_type in ['+', '-', '~', '^', '*'] && op_sym.name !in analyzer.numeric_types {
				return analyzer.void_type
			} else if operator_type == '!' && op_sym.name != 'bool' {
				return analyzer.void_type
			} else if operator_type == '*' && op_sym.kind != .ref {
				return analyzer.void_type
			} else if operator_type == '&' && op_sym.count_ptr() > 2 {
				return analyzer.void_type
			} else if operator_type == '<-' && op_sym.kind != .chan_ {
				return analyzer.void_type
			} else {
				return op_sym
			}
		}
		'identifier', 'call_expression' {
			got_sym := ss.infer_symbol_from_node(node, src_text) or { analyzer.void_type }
			if got_sym.is_returnable() {
				return got_sym.return_type
			}
			return got_sym
		}
		// 'call_expression' {
		// 	sym := ss.infer_value_type_from_node(node.child_by_field_name('function'), src_text)
		// 	return sym.return_type
		// }
		// 'argument_list' {
		// 	return ss.infer_value_type_from_node(node.parent(), src_text)
		// }
		'unsafe_expression' {
			block_node := node.named_child(0)
			block_child_len := node.named_child_count()
			if block_child_len != u32(1) {
				return analyzer.void_type
			}
			return ss.infer_value_type_from_node(block_node.named_child(0), src_text)
		}
		else {
			return ss.infer_symbol_from_node(node, src_text) or { analyzer.void_type }
		}
	}

	return ss.find_symbol('', type_name) or {
		ss.report_error(report_error('Invalid type $type_name', node.range()))
		return analyzer.void_type
	}
}

// delete_symbol_at_node removes a specific symbol from a specific portion of the node
pub fn (mut ss Store) delete_symbol_at_node(root_node C.TSNode, src []byte, at_range C.TSRange) bool {
	unsafe { ss.opened_scopes[ss.cur_file_path].free() }
	nodes := get_nodes_within_range(root_node, at_range) or { return false }
	for node in nodes {
		node_type := node.get_type()
		match node_type {
			'const_spec', 'global_var_spec', 'global_var_initializer', 'function_declaration',
			'interface_declaration', 'enum_declaration', 'type_declaration', 'struct_declaration' {
				name_node := node.child_by_field_name('name')
				if name_node.is_null() {
					// || ss.messages.has_range(ss.cur_file_path, name_node.range())
					continue
				}

				symbol_name := name_node.get_text(src)
				idx := ss.symbols[ss.cur_dir].index(symbol_name)
				language := ss.symbols[ss.cur_dir][idx].language
				if idx != -1 && idx < ss.symbols[ss.cur_dir].len {
					if language != .v {
						binded_location_idx := ss.binded_symbol_locations.index(symbol_name)
						if binded_location_idx != -1 && ss.binded_symbol_locations[binded_location_idx].module_path == ss.cur_dir {
							ss.binded_symbol_locations.delete(binded_location_idx)
						}
					}

					// unsafe { ss.symbols[ss.cur_dir].free() }
					ss.symbols[ss.cur_dir].delete(idx)
				}

				if node_type == 'function_declaration' {
					// TODO: find a way to remove scopes and update the position
					// of adjacent ones

					// params_list_node := node.child_by_field_name('parameters')
					// body_node := node.child_by_field_name('body')

					// mut start_byte := body_node.start_byte()
					// end_byte := body_node.end_byte()

					// param_count := params_list_node.named_child_count()
					// if param_count != 0 {
					// 	start_byte = params_list_node.named_child(0).start_byte()
					// }
				} else if node_type in ['const_spec', 'global_var_spec', 'global_var_initializer'] {
					mut innermost := ss.opened_scopes[ss.cur_file_path].innermost(node.start_byte(),
						node.end_byte())
					innermost.remove(symbol_name)
				}
			}
			'short_var_declaration' {
				mut innermost := ss.opened_scopes[ss.cur_file_path].innermost(node.start_byte(),
					node.end_byte())
				left_side := node.child_by_field_name('left')
				left_count := left_side.named_child_count()
				for i in u32(0) .. left_count {
					innermost.remove(left_side.named_child(i).get_text(src))
				}
			}
			'import_declaration' {
				mut imp_module := ss.find_import_by_position(node.range()) or { continue }

				// if the current import node is not the same as before,
				// untrack and remove the import entry asap
				imp_module.untrack_file(ss.cur_file_path)

				// let cleanup_imports do the job
			}
			'block' {
				ss.opened_scopes[ss.cur_file_path].remove_child(node.start_byte(), node.end_byte())
			}
			else {}
		}
	}

	return false
}
