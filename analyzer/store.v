module analyzer

import os
import analyzer.depgraph
import tree_sitter
import tree_sitter_v as v

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
	ss.messages.report(msg)
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
pub fn (ss &Store) find_fn_symbol(module_name string, return_sym &Symbol, params []&Symbol) ?&Symbol {
	module_path := ss.get_module_path(module_name)
	for sym in ss.symbols[module_path] ? {
		mut final_sym := sym
		if sym.kind == .typedef && sym.parent_sym.kind == .function_type {
			final_sym = sym.parent_sym
		}

		if final_sym.kind == .function_type && final_sym.name.starts_with(analyzer.anon_fn_prefix)
			&& sym.generic_placeholder_len == 0 {
			if !compare_params_and_ret_type(params, return_sym, final_sym, true) {
				continue
			}

			// return the typedef'd function type or the anon fn type itself
			return sym
		}
	}
	return none
}

pub fn compare_params_and_ret_type(params []&Symbol, ret_type &Symbol, fn_to_compare &Symbol, include_param_name bool) bool {
	mut params_to_check := []int{cap: fn_to_compare.children_syms.len}
	// defer {
	// 	unsafe { params_to_check.free() }
	// }

	// get a list of indices that are parameters
	for i, child in fn_to_compare.children_syms {
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
		param_from_sym := fn_to_compare.children_syms[param_idx]
		param_to_compare := params[i]
		if param_from_sym.return_sym == param_to_compare.return_sym {
			if include_param_name && param_from_sym.name != param_to_compare.name {
				break
			}
			params_left--
			continue
		}
		break
	}
	if params_left != 0 || ret_type != fn_to_compare.return_sym {
		return false
	}
	return true
}

pub const container_symbol_kinds = [SymbolKind.chan_, .array_, .map_, .ref, .variadic, .optional,
	.multi_return]

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
				existing_sym.name = info.name
			}

			existing_sym.children_syms = info.children_syms
			existing_sym.parent_sym = info.parent_sym
			existing_sym.return_sym = info.return_sym
			existing_sym.language = info.language
			existing_sym.access = info.access
			existing_sym.kind = info.kind
			existing_sym.range = info.range
			existing_sym.generic_placeholder_len = info.generic_placeholder_len
			existing_sym.file_path = info.file_path
			existing_sym.file_version = info.file_version
			existing_sym.scope = info.scope
		}

		return existing_sym
	}

	ss.symbols[dir] << info
	if info.language != .v {
		ss.binded_symbol_locations << BindedSymbolLocation{
			for_sym_name: info.name
			language: info.language
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

	if node.type_name() == 'source_file' {
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
pub fn symbol_name_from_node(node C.TSNode, src_text []u8) (SymbolKind, string, string) {
	// if node.is_null() {
	// 	return SymbolKind.typedef, '', 'void'
	// }

	mut module_name := ''
	mut symbol_name := ''

	match node.type_name() {
		'qualified_type' {
			if module_node := node.child_by_field_name('module') {
				module_name = module_node.code(src_text)
			}

			if name_node := node.child_by_field_name('name') {
				symbol_name = name_node.code(src_text)
			}

			return SymbolKind.placeholder, module_name, symbol_name
		}
		'pointer_type' {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.ref, module_name, '&' + symbol_name
		}
		'array_type', 'fixed_array_type' {
			mut limit := ''
			if limit_field := node.child_by_field_name('limit') {
				limit = limit_field.code(src_text)
			}

			if el_node := node.child_by_field_name('element') {
				_, module_name, symbol_name = symbol_name_from_node(el_node, src_text)
			}
			return SymbolKind.array_, module_name, '[$limit]' + symbol_name
		}
		'map_type' {
			mut key_module_name := ''
			mut key_symbol_name := ''
			mut val_module_name := ''
			mut val_symbol_name := ''
			mut key_symbol_text := ''
			mut value_symbol_text := ''
			if key_node := node.child_by_field_name('key') {
				key_symbol_text = key_node.code(src_text)
				_, key_module_name, key_symbol_name = symbol_name_from_node(key_node,
					src_text)
			}

			if value_node := node.child_by_field_name('value') {
				value_symbol_text = value_node.code(src_text)
				_, val_module_name, val_symbol_name = symbol_name_from_node(value_node,
					src_text)
			}

			if (key_module_name.len != 0 && val_module_name.len == 0)
				|| (key_module_name == val_module_name) {
				// if key type uses a custom type, return the symbol in the key's origin module
				return SymbolKind.map_, key_module_name, 'map[$key_symbol_name]$value_symbol_text'
			} else if key_module_name.len == 0 && val_module_name.len != 0 {
				// if key is builtin type and key type is not, use the module from the value type
				return SymbolKind.map_, val_module_name, 'map[$key_symbol_text]$val_symbol_name'
			} else {
				module_name = ''
			}

			return SymbolKind.map_, '', node.code(src_text)
		}
		'generic_type' {
			if child_type_node := node.named_child(0) {
				return symbol_name_from_node(child_type_node, src_text)
			}
		}
		'channel_type' {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.chan_, module_name, 'chan ' + symbol_name
		}
		'option_type' {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			if symbol_name == 'void' {
				symbol_name = ''
			}
			return SymbolKind.optional, module_name, '?' + symbol_name
		}
		'function_type', 'fn_literal' {
			return SymbolKind.function_type, module_name, symbol_name
		}
		'variadic_type' {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.variadic, module_name, '...' + symbol_name
		}
		else {
			// type_identifier should go here
			return SymbolKind.placeholder, module_name, node.code(src_text)
		}
	}

	return SymbolKind.typedef, '', 'void'
}

// find_symbol_by_type_node returns a symbol based on the given type node
pub fn (mut store Store) find_symbol_by_type_node(node C.TSNode, src_text []u8) ?&Symbol {
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
		mut parameters := []&Symbol{}
		if param_node := node.child_by_field_name('parameters') {
			parameters << extract_parameter_list(param_node, mut store, src_text)
		}

		mut return_sym := void_sym
		if result_node := node.child_by_field_name('result') {
			return_sym = store.find_symbol_by_type_node(result_node, src_text) or { void_sym }
		}

		return store.find_fn_symbol(module_name, return_sym, parameters) or {
			mut new_sym := &Symbol{
				name: analyzer.anon_fn_prefix + store.anon_fn_counter.str()
				file_path: store.cur_file_path
				file_version: store.cur_version
				is_top_level: true
				kind: sym_kind
				return_sym: return_sym
			}

			for mut param in parameters {
				new_sym.add_child(mut *param) or { continue }
			}

			store.anon_fn_counter++
			return new_sym
		}
	}

	return store.find_symbol(module_name, symbol_name) or {
		mut new_sym := Symbol{
			name: symbol_name
			is_top_level: true
			file_path: os.join_path(store.get_module_path(module_name), 'placeholder.vv')
			file_version: 0
			kind: sym_kind
		}

		match sym_kind {
			.array_ {
				el_node := node.child_by_field_name('element') ?
				mut el_sym := store.find_symbol_by_type_node(el_node, src_text) ?
				new_sym.add_child(mut el_sym, false) or {}
			}
			.map_ {
				key_node := node.child_by_field_name('key') ?
				mut key_sym := store.find_symbol_by_type_node(key_node, src_text) ?
				new_sym.add_child(mut key_sym, false) or {}

				value_node := node.child_by_field_name('value') ?
				mut val_sym := store.find_symbol_by_type_node(value_node, src_text) ?
				new_sym.add_child(mut val_sym, false) or {}
			}
			.chan_, .ref, .optional {
				if symbol_name != '?' {
					child_type_node := node.named_child(0) ?
					mut ref_sym := store.find_symbol_by_type_node(child_type_node, src_text) ?
					if ref_sym.name.len != 0 {
						new_sym.parent_sym = ref_sym
					} else {
						// TODO:
						return error('empty ref sym')
					}
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
pub fn (mut ss Store) infer_symbol_from_node(node C.TSNode, src_text []u8) ?&Symbol {
	if node.is_null() {
		return none
	}

	mut module_name := ''
	mut type_name := ''

	match node.type_name() {
		'identifier', 'binded_identifier' {
			// Identifier symbol finding strategy
			// Find first in symbols
			// find the symbol in scopes
			// return void if none
			ident_text := node.code(src_text)
			return ss.opened_scopes[ss.cur_file_path].get_symbol_with_range(ident_text,
				node.range()) or { ss.find_symbol(module_name, ident_text) ? }
		}
		'mutable_identifier' {
			first_child := node.named_child(0) ?
			return ss.infer_symbol_from_node(first_child, src_text)
		}
		'field_identifier' {
			mut parent := node.parent() ?
			for parent.type_name() in ['keyed_element', 'literal_value'] {
				parent = parent.parent() ?
			}

			parent_sym := ss.infer_symbol_from_node(parent, src_text) or { void_sym }
			ident_text := node.code(src_text)
			if !parent_sym.is_void() {
				if parent.type_name() == 'struct_field_declaration' {
					return parent_sym
				} else if child_sym := parent_sym.children_syms.get(ident_text) {
					return child_sym
				}
			}

			return ss.find_symbol(module_name, ident_text) or {
				ss.opened_scopes[ss.cur_file_path].get_symbol_with_range(ident_text, node.range()) ?
			}
		}
		'type_selector_expression' {
			// TODO: assignment_declaration
			// if parent.type_name() != 'literal_value' {
			// 	parent = parent.parent()
			// }
			field_node := node.child_by_field_name('field_name') ?
			if type_node := node.child_by_field_name('type') {
				parent_sym := ss.infer_symbol_from_node(type_node, src_text) ?
				child_sym := parent_sym.children_syms.get(field_node.code(src_text)) ?
				return child_sym
			} else {
				// for shorhand enum
				enum_value := field_node.code(src_text)
				for sym in ss.symbols[ss.cur_dir] {
					if sym.kind != .enum_ {
						continue
					}
					enum_member := sym.children_syms.get(enum_value) or { continue }
					return enum_member
				}
			}
		}
		'type_initializer' {
			return ss.find_symbol_by_type_node(node.child_by_field_name('type') ?, src_text)
		}
		'type_identifier', 'array', 'array_type', 'map_type', 'pointer_type', 'variadic_type',
		'builtin_type', 'fn_literal' {
			return ss.find_symbol_by_type_node(node, src_text)
		}
		'const_spec' {
			return ss.find_symbol_by_type_node(node.child_by_field_name('name') ?, src_text)
		}
		'selector_expression' {
			operand := node.child_by_field_name('operand') ?
			mut root_sym := ss.infer_symbol_from_node(operand, src_text) or { void_sym }
			if !root_sym.is_void() {
				if root_sym.is_returnable() {
					root_sym = root_sym.return_sym
				}
				child_name := node.child_by_field_name('field') ?.code(src_text)
				return root_sym.children_syms.get(child_name) or {
					if root_sym.kind == .ref {
						root_sym = root_sym.parent_sym
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

					root_sym.children_syms.get(child_name) or { void_sym }
				}
			}

			if operand.type_name() != 'identifier' {
				return none
			}

			module_name = node.child_by_field_name('operand') ?.code(src_text)
			type_name = node.child_by_field_name('field') ?.code(src_text)
		}
		'keyed_element' {
			mut parent := node.parent() ?
			if parent.type_name() == 'literal_value' || parent.type_name() == 'map' {
				parent = parent.parent() ?
			}
			mut selected_node := node.child_by_field_name('name') ?
			if !selected_node.type_name().ends_with('identifier') {
				selected_node = node.child_by_field_name('value') ?
			}
			if parent.type_name() == 'literal_value' {
				parent_sym := ss.infer_symbol_from_node(parent, src_text) ?
				return parent_sym.children_syms.get(selected_node.code(src_text)) or {
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
			function_node := node.child_by_field_name('function') ?
			return ss.infer_symbol_from_node(function_node, src_text)
		}
		'parameter_declaration' {
			mut parent := node.parent() ?
			for parent.type_name() !in ['function_declaration', 'interface_spec'] {
				parent = parent.parent() ?
				if parent.is_null() {
					return none
				}
			}

			if parent.type_name() == 'function_declaration' {
				parent = parent.child_by_field_name('name') ?
			}

			parent_sym := ss.infer_symbol_from_node(parent, src_text) ?
			child_sym := parent_sym.children_syms.get(node.child_by_field_name('name') ?.code(src_text)) ?
			return child_sym
		}
		'struct_field_declaration', 'interface_spec' {
			mut parent := node.parent() or { return none }
			for parent.type_name() !in ['struct_declaration', 'interface_declaration'] {
				parent = parent.parent() or { return none }
			}

			// eprintln(parent.type_name())
			parent_sym := ss.infer_symbol_from_node(parent.child_by_field_name('name') ?,
				src_text) ?
			child_sym := parent_sym.children_syms.get(node.child_by_field_name('name') ?.code(src_text)) ?
			return child_sym
		}
		'function_declaration' {
			name_node := node.child_by_field_name('name') ?
			receiver_node := node.child_by_field_name('receiver') or {
				return ss.infer_symbol_from_node(name_node, src_text)
			}

			receiver_param_count := receiver_node.named_child_count()
			if receiver_param_count != 0 {
				receiver_param_node := receiver_node.named_child(0) ?
				parent_sym := ss.infer_symbol_from_node(receiver_param_node.child_by_field_name('type') ?,
					src_text) ?
				child_sym := parent_sym.children_syms.get(name_node.code(src_text)) ?
				return child_sym
			} else {
				return ss.infer_symbol_from_node(name_node, src_text)
			}
		}
		else {
			// eprintln(node_type)
			// eprintln(node.parent().type_name())
			// return analyzer.void_sym
		}
	}

	return ss.find_symbol(module_name, type_name)
}

// infer_value_type_from_node returns the symbol based on the given node
pub fn (mut ss Store) infer_value_type_from_node(node C.TSNode, src_text []u8) &Symbol {
	if node.is_null() {
		return void_sym
	}

	mut type_name := ''

	match node.type_name() {
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
			type_name = 'u8'
		}
		'interpreted_string_literal' {
			type_name = 'string'
		}
		'range' {
			// TODO: detect starting and ending types
			type_name = '[]int'
		}
		'array' {
			if child_type_node := node.child(1) {
				type_name = '[]' + ss.infer_value_type_from_node(child_type_node, src_text).name
			}
		}
		'binary_expression' {
			// TODO:
			left_node := node.child_by_field_name('left') or { return void_sym }
			// op_node := node.child_by_field_name('operator')
			// right_node := node.child_by_field_name('right')
			mut left_sym := ss.infer_value_type_from_node(left_node, src_text)
			if left_sym.is_returnable() {
				left_sym = left_sym.return_sym
			}
			// right_sym := ss.infer_value_type_from_node(right_node.code(src_text))
			return left_sym
		}
		'unary_expression' {
			operator_node := node.child_by_field_name('operator') or { return void_sym }
			operand_node := node.child_by_field_name('operand') or { return void_sym }
			mut op_sym := ss.infer_value_type_from_node(operand_node, src_text)
			if op_sym.is_returnable() {
				op_sym = op_sym.return_sym
			}

			operator_type_name := operator_node.type_name()
			if operator_type_name in ['+', '-', '~', '^', '*'] && op_sym.name !in numeric_types {
				return void_sym
			} else if operator_type_name == '!' && op_sym.name != 'bool' {
				return void_sym
			} else if operator_type_name == '*' && op_sym.kind != .ref {
				return void_sym
			} else if operator_type_name == '&' && op_sym.count_ptr() > 2 {
				return void_sym
			} else if operator_type_name == '<-' && op_sym.kind != .chan_ {
				return void_sym
			} else {
				return op_sym
			}
		}
		'identifier' {
			got_sym := ss.infer_symbol_from_node(node, src_text) or { void_sym }
			if got_sym.is_returnable() {
				return got_sym.return_sym
			}
			return got_sym
		}
		'call_expression' {
			got_sym := ss.infer_symbol_from_node(node, src_text) or { void_sym }
			node_count := node.named_child_count()
			if got_sym.is_returnable() {
				if last_node := node.named_child(node_count - 1) {
					if got_sym.return_sym.kind == .optional
						&& last_node.type_name() == 'option_propagator' {
						return got_sym.return_sym.final_sym()
					}
				}
				return got_sym.return_sym
			}
			return got_sym
		}
		'type_selector_expression' {
			if type_node := node.child_by_field_name('type') {
				if parent_sym := ss.infer_symbol_from_node(type_node, src_text) {
					return parent_sym
				}
			}
			return void_sym
		}
		// 'argument_list' {
		// 	return ss.infer_value_type_from_node(node.parent(), src_text)
		// }
		'unsafe_expression' {
			if block_node := node.named_child(0) {
				block_child_len := node.named_child_count()
				if block_child_len != u32(1) {
					return void_sym
				}

				if first_node := block_node.named_child(0) {
					return ss.infer_value_type_from_node(first_node, src_text)
				}
			}
		}
		else {
			return ss.infer_symbol_from_node(node, src_text) or { void_sym }
		}
	}

	return ss.find_symbol('', type_name) or {
		// ss.report_error(report_error('Invalid type $type_name', node.range()))
		return void_sym
	}
}

// delete_symbol_at_node removes a specific symbol from a specific portion of the node
pub fn (mut ss Store) delete_symbol_at_node(root_node C.TSNode, src []u8, at_range C.TSRange) bool {
	unsafe { ss.opened_scopes[ss.cur_file_path].free() }
	nodes := get_nodes_within_range(root_node, at_range) or { return false }
	for node in nodes {
		node_type_name := node.type_name()
		match node_type_name {
			'const_spec', 'global_var_spec', 'global_var_initializer', 'function_declaration',
			'interface_declaration', 'enum_declaration', 'type_declaration', 'struct_declaration' {
				name_node := node.child_by_field_name('name') or { continue }
				symbol_name := name_node.code(src)
				idx := ss.symbols[ss.cur_dir].index(symbol_name)
				if idx != -1 && idx < ss.symbols[ss.cur_dir].len {
					language := ss.symbols[ss.cur_dir][idx].language
					if language != .v {
						binded_location_idx := ss.binded_symbol_locations.index(symbol_name)
						if binded_location_idx != -1
							&& ss.binded_symbol_locations[binded_location_idx].module_path == ss.cur_dir {
							ss.binded_symbol_locations.delete(binded_location_idx)
						}
					}

					// unsafe { ss.symbols[ss.cur_dir].free() }
					ss.symbols[ss.cur_dir].delete(idx)
				}

				if node_type_name == 'function_declaration' {
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
				} else if node_type_name in ['const_spec', 'global_var_spec',
					'global_var_initializer'] {
					mut innermost := ss.opened_scopes[ss.cur_file_path].innermost(node.start_byte(),
						node.end_byte())
					innermost.remove(symbol_name)
				}
			}
			'short_var_declaration' {
				mut innermost := ss.opened_scopes[ss.cur_file_path].innermost(node.start_byte(),
					node.end_byte())
				left_side := node.child_by_field_name('left') or { continue }
				left_count := left_side.named_child_count()
				for i in u32(0) .. left_count {
					innermost.remove(left_side.named_child(i) or { continue }.code(src))
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

// register_auto_import registers the import as an auto-import. This
// is used for most important imports such as "builtin"
pub fn (mut ss Store) register_auto_import(imp Import, to_alias string) {
	ss.auto_imports[to_alias] = imp.path
}

// find_import_by_position locates the import of the current directory
// based on the given range
pub fn (mut ss Store) find_import_by_position(range C.TSRange) ?&Import {
	for mut imp in ss.imports[ss.cur_dir] {
		if ss.cur_file_path in imp.ranges
			&& imp.ranges[ss.cur_file_path].start_point.row == range.start_point.row {
			return unsafe { imp }
		}
	}

	return none
}

// inject_paths_of_new_imports resolves and injects the path to the Import instance
[manualfree]
fn (mut ss Store) inject_paths_of_new_imports(mut new_imports []&Import, lookup_paths ...string) {
	mut project := ss.dependency_tree.get_node(ss.cur_dir) or { ss.dependency_tree.add(ss.cur_dir) }

	// Custom iterator for looping over paths without
	// allocating a new array with concatenated items
	// Might be "smart" but I'm just testing my hypothesis
	// if it will be better for the memory consumption ~ Ned
	mut import_path_iter := ImportPathIterator{
		start_path: ss.cur_dir
		lookup_paths: lookup_paths
		fallback_lookup_paths: ss.default_import_paths
	}

	for mut new_import in new_imports {
		if new_import.resolved {
			continue
		}

		// module.submod -> ['module', 'submod']
		mod_name_arr := new_import.absolute_module_name.split('.')
		for path in import_path_iter {
			mod_dir := os.join_path(path, ...mod_name_arr)

			// if the directory is already present in the
			// dependency tree, inject it directly
			if ss.dependency_tree.has(mod_dir) {
				new_import.set_path(mod_dir)
				break
			}

			if !os.exists(mod_dir) {
				continue
			}

			mut has_v_files := false

			// files is just for checking so it
			// is not used by the code below it
			{
				mut files := os.ls(mod_dir) or { continue }

				// search for files end with v and free
				// the contents of the array at the same time
				for j := 0; files.len != 0; {
					if !has_v_files {
						file_ext := os.file_ext(files[j])
						if file_ext == v_ext {
							has_v_files = true
						}
					}
					files.delete(j)
				}
			}
			if has_v_files {
				new_import.set_path(mod_dir)
				ss.dependency_tree.add(mod_dir)
				break
			}
		}

		// report the unresolved import
		if !new_import.resolved {
			for file_path, range in new_import.ranges {
				ss.report(
					content: 'Module `$new_import.absolute_module_name` not found'
					file_path: file_path
					range: range
				)

				new_import.ranges.delete(file_path)
			}

			continue
		} else if new_import.path !in project.dependencies {
			// append the path if not yet added to the project dependency
			project.dependencies << new_import.path
		}

		import_path_iter.reset()
	}
}

// cleanup_imports removes the unused imports from the current directory.
// This should be used after executing `import_modules_from_tree` or `import_modules`.
pub fn (mut ss Store) cleanup_imports() int {
	mut deleted := 0
	for i := 0; i < ss.imports[ss.cur_dir].len; {
		mut imp_module := ss.imports[ss.cur_dir][i]
		if imp_module.ranges.len == 0 || (!imp_module.resolved || !imp_module.imported) {
			// delete in the dependency tree
			mut dep_node := ss.dependency_tree.get_node(ss.cur_dir) or {
				panic('Should not panic. Please file an issue to github.com/vlang/vls.')
				return deleted
			}

			// intentionally do not use the variables to the same scope
			dep_node.remove_dependency(imp_module.path)

			// delete dir if possible
			ss.delete(imp_module.path)
			// unsafe { imp_module.free() }

			if i < ss.imports[ss.cur_dir].len {
				ss.imports[ss.cur_dir].delete(i)
			}

			deleted++
			continue
		}

		i++
	}

	return deleted
}

fn (mut ss Store) scan_imports(tree &C.TSTree, src_text []u8) []&Import {
	root_node := tree.root_node()
	named_child_len := root_node.named_child_count()
	mut newly_imported_modules := []&Import{}

	for i in 0 .. named_child_len {
		node := root_node.named_child(i) or { continue }
		if node.type_name() != 'import_declaration' {
			continue
		}

		import_path_node := node.child_by_field_name('path') or { continue }

		if found_imp := ss.find_import_by_position(node.range()) {
			mut imp_module := found_imp
			mod_name := import_path_node.code(src_text)
			if imp_module.absolute_module_name == mod_name {
				continue
			}

			// if the current import node is not the same as before,
			// untrack and remove the import entry asap
			imp_module.untrack_file(ss.cur_file_path)
		}

		// resolve it later after
		mut imp_module, already_imported := ss.add_import(
			resolved: false
			absolute_module_name: import_path_node.code(src_text)
		)

		if import_alias_node := node.child_by_field_name('alias') {
			if ident_node := import_alias_node.named_child(0) {
				imp_module.set_alias(ss.cur_file_name, ident_node.code(src_text))
			}
		} else if import_symbols_node := node.child_by_field_name('symbols') {
			symbols_len := import_symbols_node.named_child_count()
			mut symbols := []string{len: int(symbols_len)}
			for j := u32(0); j < symbols_len; j++ {
				symbols[j] = import_symbols_node.named_child(j) or { continue }.code(src_text)
			}

			imp_module.set_symbols(ss.cur_file_name, ...symbols)
		}

		if !already_imported {
			newly_imported_modules << imp_module
		}

		imp_module.track_file(ss.cur_file_path, import_path_node.range())
	}

	return newly_imported_modules
}

// import_modules_from_tree scans and imports the modules based from the AST tree
pub fn (mut store Store) import_modules_from_tree(tree &C.TSTree, src []u8, lookup_paths ...string) {
	mut imports := store.scan_imports(tree, src)
	store.inject_paths_of_new_imports(mut imports, ...lookup_paths)
	if imports.len == 0 {
		return
	}

	store.import_modules(mut imports)
}

// import_modules imports the given Import array to the current directory.
// It also registers the symbols to the store.
pub fn (mut store Store) import_modules(mut imports []&Import) {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	// defer {
	// 	unsafe { parser.free() }
	// }

	old_version := store.cur_version
	old_active_path := store.cur_file_path
	old_active_dir := store.cur_dir
	modules_from_old_dir := os.join_path(old_active_dir, 'modules')

	for i, new_import in imports {
		// skip if import is not resolved or already imported
		if !new_import.resolved || new_import.imported {
			continue
		}

		file_paths := os.ls(new_import.path) or { continue }
		mut imported := 0
		for file_name in file_paths {
			if !should_analyze_file(file_name) {
				continue
			}

			full_path := os.join_path(new_import.path, file_name)
			content := os.read_bytes(full_path) or { continue }
			tree_from_import := parser.parse_bytes(content)

			// Set version to zero so that modules that are already opened
			// in the editor can register symbols with scopes without
			// getting "symbol exists" errors
			store.set_active_file_path(full_path, 0)

			// Import module but from different lookup oath other than the project
			modules_from_dir := os.join_path(store.cur_dir, 'modules')
			store.import_modules_from_tree(tree_from_import, content, modules_from_dir,
				old_active_dir, modules_from_old_dir)
			imported++
			store.register_symbols_from_tree(tree_from_import, content, true)
			parser.reset()
		}

		if imported > 0 {
			imports[i].imported = true
		}

		store.set_active_file_path(old_active_path, old_version)
		unsafe { file_paths.free() }
	}

	// unsafe {
	// 	modules_from_old_dir.free()
	// 	old_active_path.free()
	// 	old_active_dir.free()
	// }
}

pub fn (ss &Store) is_module(module_name string) bool {
	_ = ss.get_module_path_opt(module_name) or { return false }
	return true
}

pub fn (ss &Store) is_imported(path string) bool {
	if import_lists := ss.imports[ss.cur_dir] {
		for imp in import_lists {
			if imp.path != path {
				continue
			}

			if ss.cur_file_path in imp.ranges {
				return true
			}
		}
	}

	for _, imp_path in ss.auto_imports {
		if imp_path == path {
			return true
		}
	}

	return false
}
