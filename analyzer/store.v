module analyzer

import os
import structures.depgraph
import tree_sitter
import ast

pub struct Store {
mut:
	anon_fn_counter int = 1
pub mut:
	// Default reporter to be used
	// Used for diagnostics
	reporter Reporter
	// Current version of the file
	cur_version int
	// List of imports per directory
	// map goes: map[<full dir path>][]Import
	imports ImportsMap
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

pub fn (mut ss Store) with(params AnalyzerContextParams) AnalyzerContext {
	return new_context(AnalyzerContextParams{
		...params
		store: unsafe { ss }
	})
}

pub fn (mut ss Store) default_context() AnalyzerContext {
	return ss.with(file_path: '')
}

// report inserts the report to the reporter
pub fn (mut ss Store) report(report Report) {
	ss.reporter.report(report)
}

[if trace ?]
pub fn (mut ss Store) trace_report(report Report) {
	ss.reporter.report(report)
}

// get_module_path_opt is a variant of `get_module_path` that returns
// an optional if not found
pub fn (ss &Store) get_module_path_opt(file_path string, module_name string) ?string {
	file_name := os.base(file_path)
	file_dir := os.dir(file_path)
	import_lists := ss.imports[file_dir]
	for imp in import_lists {
		if imp.module_name == module_name {
			return imp.path
		}

		if file_name in imp.aliases && imp.aliases[file_name] == module_name {
			return imp.path
		}
	}

	return none
}

pub fn (ss &Store) get_module_path_from_sym(file_path string, symbol_name string) ?string {
	file_name := os.base(file_path)
	if import_lists := ss.imports[os.dir(file_path)] {
		for imp in import_lists {
			if file_name !in imp.symbols || symbol_name !in imp.symbols[file_name] {
				continue
			}

			return imp.path
		}
	}

	return none
}

// get_module_path returns the path of the import/module based
// on the given module name. If nothing found, it will return
// the current directory instead.
pub fn (ss &Store) get_module_path(file_path string, module_name string) string {
	// empty names should return the current selected dir instead
	return ss.get_module_path_opt(file_path, module_name) or { os.dir(file_path) }
}

// find_symbol retrieves the symbol based on the given module name and symbol name
pub fn (ss &Store) find_symbol(file_path string, module_name string, name string) !&Symbol {
	if name.len == 0 {
		return error('Name is empty.')
	}

	module_path := ss.get_module_path(file_path, module_name)
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

	// Find symbol if it selectively imported from module
	if mod_path := ss.get_module_path_from_sym(file_path, name) {
		idx_from_selective := ss.symbols[mod_path].index(name)
		if idx_from_selective != -1 {
			return ss.symbols[mod_path][idx_from_selective]
		}
	}

	return error('Symbol `${name}` not found.')
}

const anon_fn_prefix = '#anon_'

// find_fn_symbol finds the function symbol with the appropriate parameters and return type
pub fn (ss &Store) find_fn_symbol(file_path string, module_name string, return_sym &Symbol, params []&Symbol) ?&Symbol {
	module_path := ss.get_module_path(file_path, module_name)
	symbols := ss.symbols[module_path] or { return none }
	for sym in symbols {
		mut final_sym := unsafe { sym }
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
	.result, .multi_return]

// register_symbol registers the given symbol
pub fn (mut ss Store) register_symbol(mut info Symbol) !&Symbol {
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
			if existing_sym.kind != .placeholder
				&& (info.range.start_point.row > existing_sym.range.start_point.row
				|| (existing_sym.kind == info.kind && (existing_sym.file_path == info.file_path
				&& existing_sym.file_version >= info.file_version))) {
				return report_error('Symbol already exists. (idx=${existing_idx}) (name="${existing_sym.name}")',
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
pub fn (mut ss Store) get_scope_from_node(file_path string, node ast.Node) !&ScopeTree {
	if node.is_null() {
		return error('unable to create scope')
	}

	if node.type_name == .source_file {
		if file_path !in ss.opened_scopes {
			ss.opened_scopes[file_path] = &ScopeTree{
				start_byte: node.start_byte()
				end_byte: node.end_byte()
			}
		}

		return unsafe { ss.opened_scopes[file_path] }
	} else {
		return unsafe {
			ss.opened_scopes[file_path].new_child(node.start_byte(), node.end_byte()) or {
				error('')
			}
		}
	}
}

// symbol_name_from_node extracts the symbol's kind, name, and module name from the given node
pub fn symbol_name_from_node(node ast.Node, src_text tree_sitter.SourceText) (SymbolKind, string, string) {
	// if node.is_null() {
	// 	return SymbolKind.typedef, '', 'void'
	// }

	mut module_name := ''
	mut symbol_name := ''

	match node.type_name {
		.qualified_type {
			if module_node := node.child_by_field_name('module') {
				module_name = module_node.text(src_text)
			}

			if name_node := node.child_by_field_name('name') {
				symbol_name = name_node.text(src_text)
			}

			return SymbolKind.placeholder, module_name, symbol_name
		}
		.pointer_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.ref, module_name, '&' + symbol_name
		}
		.array_type, .fixed_array_type {
			mut limit := ''
			if limit_field := node.child_by_field_name('limit') {
				limit = limit_field.text(src_text)
			}

			if el_node := node.child_by_field_name('element') {
				_, module_name, symbol_name = symbol_name_from_node(el_node, src_text)
			}
			return SymbolKind.array_, module_name, '[${limit}]' + symbol_name
		}
		.map_type {
			mut key_module_name := ''
			mut key_symbol_name := ''
			mut val_module_name := ''
			mut val_symbol_name := ''
			mut key_symbol_text := ''
			mut value_symbol_text := ''
			if key_node := node.child_by_field_name('key') {
				key_symbol_text = key_node.text(src_text)
				_, key_module_name, key_symbol_name = symbol_name_from_node(key_node,
					src_text)
			}

			if value_node := node.child_by_field_name('value') {
				value_symbol_text = value_node.text(src_text)
				_, val_module_name, val_symbol_name = symbol_name_from_node(value_node,
					src_text)
			}

			if (key_module_name.len != 0 && val_module_name.len == 0)
				|| (key_module_name == val_module_name) {
				// if key type uses a custom type, return the symbol in the key's origin module
				return SymbolKind.map_, key_module_name, 'map[${key_symbol_name}]${value_symbol_text}'
			} else if key_module_name.len == 0 && val_module_name.len != 0 {
				// if key is builtin type and key type is not, use the module from the value type
				return SymbolKind.map_, val_module_name, 'map[${key_symbol_text}]${val_symbol_name}'
			} else {
				module_name = ''
			}

			return SymbolKind.map_, '', node.text(src_text)
		}
		.generic_type {
			if child_type_node := node.named_child(0) {
				return symbol_name_from_node(child_type_node, src_text)
			}
		}
		.channel_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.chan_, module_name, 'chan ' + symbol_name
		}
		.option_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			if symbol_name == 'void' {
				symbol_name = ''
			}
			return SymbolKind.optional, module_name, '?' + symbol_name
		}
		.result_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			if symbol_name == 'void' {
				symbol_name = ''
			}
			return SymbolKind.result, module_name, '!' + symbol_name
		}
		.function_type, .fn_literal {
			return SymbolKind.function_type, module_name, symbol_name
		}
		.variadic_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.variadic, module_name, '...' + symbol_name
		}
		.multi_return_type {
			return SymbolKind.multi_return, '', node.text(src_text)
		}
		else {
			// type_identifier should go here
			return SymbolKind.placeholder, module_name, node.text(src_text)
		}
	}

	return SymbolKind.typedef, '', 'void'
}

// find_symbol_by_type_node returns a symbol based on the given type node
pub fn (mut store Store) find_symbol_by_type_node(file_path string, node ast.Node, src_text tree_sitter.SourceText) !&Symbol {
	if node.is_null() || src_text.len() == 0 {
		return error('null node or empty source text')
	}

	sym_kind, module_name, symbol_name := symbol_name_from_node(node, src_text)
	if sym_kind == .function_type {
		mut parameters := []&Symbol{}
		if param_node := node.child_by_field_name('parameters') {
			mut ctx := new_context(store: store, file_path: file_path, text: src_text)
			parameters << extract_parameter_list(mut ctx, param_node)
		}

		mut return_sym := unsafe { void_sym }
		if result_node := node.child_by_field_name('result') {
			return_sym = store.find_symbol_by_type_node(file_path, result_node, src_text) or {
				void_sym
			}
		}

		return store.find_fn_symbol(file_path, module_name, return_sym, parameters) or {
			mut new_sym := &Symbol{
				name: analyzer.anon_fn_prefix + store.anon_fn_counter.str()
				file_path: file_path
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

	return store.find_symbol(file_path, module_name, symbol_name) or {
		mut new_sym := Symbol{
			name: symbol_name
			is_top_level: true
			file_path: os.join_path(store.get_module_path(file_path, module_name), 'placeholder.vv')
			file_version: 0
			kind: sym_kind
		}

		match sym_kind {
			.array_ {
				el_node := node.child_by_field_name('element') or { return error('') }
				mut el_sym := store.find_symbol_by_type_node(file_path, el_node, src_text)!
				new_sym.add_child(mut el_sym, false) or {}
			}
			.map_ {
				key_node := node.child_by_field_name('key') or { return error('') }
				mut key_sym := store.find_symbol_by_type_node(file_path, key_node, src_text)!
				new_sym.add_child_allow_duplicated(mut key_sym, false)

				value_node := node.child_by_field_name('value') or { return error('') }
				mut val_sym := store.find_symbol_by_type_node(file_path, value_node, src_text)!
				new_sym.add_child_allow_duplicated(mut val_sym, false)
			}
			.chan_, .ref, .optional, .result {
				if symbol_name !in ['?', '!'] {
					child_type_node := node.named_child(0) or { return error('') }
					mut ref_sym := store.find_symbol_by_type_node(file_path, child_type_node,
						src_text)!
					if ref_sym.name.len != 0 {
						new_sym.parent_sym = ref_sym
					} else {
						// TODO:
						return error('empty ref sym')
					}
				}
			}
			.multi_return, .variadic {
				types_len := node.named_child_count()
				new_sym.children_syms = []&Symbol{cap: int(types_len)}
				for i in u32(0) .. types_len {
					type_node := node.named_child(i) or { continue }
					mut type_sym := store.find_symbol_by_type_node(file_path, type_node,
						src_text) or { continue }
					if !type_sym.is_void() {
						new_sym.children_syms << type_sym
					}
				}
			}
			else {}
		}

		store.register_symbol(mut new_sym)!
	}
}

// infer_symbol_from_node returns the specified symbol based on the given node.
// This is different from infer_value_type_from_node as this returns the symbol
// instead of symbol's return type or parent for example
pub fn (mut ss Store) infer_symbol_from_node(file_path string, node ast.Node, src_text tree_sitter.SourceText) !&Symbol {
	if node.is_null() {
		return error('null node')
	}

	mut module_name := ''
	mut type_name := ''

	match node.type_name {
		.interpreted_string_literal {
			type_name = 'string'
		}
		.identifier, .binded_identifier {
			// Identifier symbol finding strategy
			// Find first in symbols
			// find the symbol in scopes
			// return void if none
			ident_text := node.text(src_text)
			return unsafe {
				ss.opened_scopes[file_path].get_symbol_with_range(ident_text, node.range()) or {
					ss.find_symbol(file_path, module_name, ident_text)!
				}
			}
		}
		.mutable_identifier, .mutable_expression {
			first_child := node.named_child(0) or { return error('empty node') }
			return ss.infer_symbol_from_node(file_path, first_child, src_text)
		}
		.field_identifier {
			mut parent := node.parent() or { return error('no parent found') }
			for parent.type_name in [.keyed_element, .literal_value] {
				parent = parent.parent() or { return error('no parent found') }
			}

			parent_sym := ss.infer_symbol_from_node(file_path, parent, src_text) or { void_sym }
			ident_text := node.text(src_text)
			if !parent_sym.is_void() {
				if parent.type_name == .struct_field_declaration {
					return parent_sym
				} else if child_sym := parent_sym.children_syms.get(ident_text) {
					return child_sym
				}
			}

			return ss.find_symbol(file_path, module_name, ident_text) or {
				unsafe {
					ss.opened_scopes[file_path].get_symbol_with_range(ident_text, node.range())!
				}
			}
		}
		.type_selector_expression {
			// TODO: assignment_declaration
			// if parent.type_name() != 'literal_value' {
			// 	parent = parent.parent()
			// }
			field_node := node.child_by_field_name('field_name') or {
				return error('no field node found')
			}
			if type_node := node.child_by_field_name('type') {
				parent_sym := ss.infer_symbol_from_node(file_path, type_node, src_text)!
				child_sym := parent_sym.children_syms.get(field_node.text(src_text)) or {
					return error('symbol not found')
				}
				return child_sym
			} else {
				// for shorhand enum
				enum_value := field_node.text(src_text)
				for sym in ss.symbols[os.dir(file_path)] {
					if sym.kind != .enum_ {
						continue
					}
					enum_member := sym.children_syms.get(enum_value) or { continue }
					return enum_member
				}
			}
		}
		.type_initializer {
			type_node := node.child_by_field_name('type') or { return error('no type node found') }
			return ss.find_symbol_by_type_node(file_path, type_node, src_text) or {
				return error('not found')
			}
		}
		.type_identifier, .array, .array_type, .map_type, .pointer_type, .variadic_type,
		.builtin_type, .channel_type, .fn_literal {
			return ss.find_symbol_by_type_node(file_path, node, src_text) or {
				return error('not found')
			}
		}
		.const_spec {
			name_node := node.child_by_field_name('name') or { return error('no name node found') }
			return ss.find_symbol_by_type_node(file_path, name_node, src_text) or {
				error('not found')
			}
		}
		.selector_expression {
			operand := node.child_by_field_name('operand') or {
				return error('no operande node found')
			}
			mut root_sym := ss.infer_symbol_from_node(file_path, operand, src_text) or { void_sym }
			if !root_sym.is_void() {
				if root_sym.is_returnable() {
					root_sym = root_sym.return_sym
				}
				field_node := node.child_by_field_name('field') or {
					return error('no field node found')
				}
				child_name := field_node.text(src_text)
				return root_sym.children_syms.get(child_name) or {
					if root_sym.kind == .ref {
						root_sym = root_sym.parent_sym
					} else {
						for base_sym_loc in ss.base_symbol_locations {
							if base_sym_loc.for_kind == root_sym.kind {
								root_sym = ss.find_symbol(file_path, base_sym_loc.module_name,
									base_sym_loc.symbol_name) or { continue }
								break
							}
						}
					}

					root_sym.children_syms.get(child_name) or { void_sym }
				}
			}

			if operand.type_name != .identifier {
				return error('')
			}

			module_name = operand.text(src_text)
			field_node := node.child_by_field_name('field') or {
				return error('no field node found')
			}
			type_name = field_node.text(src_text)
		}
		.keyed_element {
			mut parent := node.parent() or { return error('failed to get parent') }
			if parent.type_name == .literal_value || parent.type_name == .map_ {
				parent = parent.parent() or { return error('failed to get parent') }
			}
			mut selected_node := node.child_by_field_name('name') or {
				return error('no name node found')
			}
			if !selected_node.type_name.is_identifier() {
				selected_node = node.child_by_field_name('value') or {
					return error('no value node found')
				}
			}
			if parent.type_name == .literal_value || parent.type_name == .type_initializer {
				mut parent_sym := ss.infer_symbol_from_node(file_path, parent, src_text)!
				if parent_sym.kind == .ref {
					parent_sym = parent_sym.parent_sym
				}

				return parent_sym.children_syms.get(selected_node.text(src_text)) or {
					if parent_sym.name == 'map' || parent_sym.name == 'array' {
						return ss.infer_symbol_from_node(file_path, selected_node, src_text)
					}
					return err
				}
			} else {
				return ss.infer_symbol_from_node(file_path, selected_node, src_text)
			}
		}
		.call_expression {
			function_node := node.child_by_field_name('function') or {
				return error('no function node found')
			}
			return ss.infer_symbol_from_node(file_path, function_node, src_text)
		}
		.parameter_declaration {
			mut parent := node.parent() or { return error('failed to get parent') }
			for parent.type_name !in [.function_declaration, .interface_spec] {
				parent = parent.parent() or { return error('failed to get parent') }
				if parent.is_null() {
					return error('null node')
				}
			}

			if parent.type_name == .function_declaration {
				parent = parent.child_by_field_name('name') or {
					return error('no name node found')
				}
			}

			parent_sym := ss.infer_symbol_from_node(file_path, parent, src_text)!
			name_node := node.child_by_field_name('name') or { return error('no name node found') }
			return parent_sym.children_syms.get(name_node.text(src_text)) or {
				error('no symbol found')
			}
		}
		.struct_field_declaration, .interface_spec {
			mut parent := node.parent() or { return error('failed to get parent') }
			for parent.type_name !in [.struct_declaration, .interface_declaration] {
				parent = parent.parent() or { return error('failed to get parent') }
			}

			// eprintln(parent.type_name())
			parent_name_node := parent.child_by_field_name('name') or {
				return error('no name node found')
			}
			parent_sym := ss.infer_symbol_from_node(file_path, parent_name_node, src_text)!
			child_name_node := node.child_by_field_name('name') or {
				return error('no name node found')
			}
			return parent_sym.children_syms.get(child_name_node.text(src_text)) or {
				error('no symbol found')
			}
		}
		.function_declaration {
			name_node := node.child_by_field_name('name') or { return error('no name node found') }
			receiver_node := node.child_by_field_name('receiver') or {
				return ss.infer_symbol_from_node(file_path, name_node, src_text)
			}

			receiver_param_count := receiver_node.named_child_count()
			if receiver_param_count != 0 {
				receiver_param_node := receiver_node.named_child(0) or {
					return error('empty node')
				}
				type_node := receiver_param_node.child_by_field_name('type') or {
					return error('no type node found')
				}
				parent_sym := ss.infer_symbol_from_node(file_path, type_node, src_text)!
				return parent_sym.children_syms.get(name_node.text(src_text)) or {
					error('no symbol found')
				}
			} else {
				return ss.infer_symbol_from_node(file_path, name_node, src_text)
			}
		}
		else {
			// eprintln(node_type)
			// eprintln(node.parent().type_name())
			// return analyzer.void_sym
		}
	}

	return ss.find_symbol(file_path, module_name, type_name)
}

// infer_value_type_from_node returns the symbol based on the given node
pub fn (mut ss Store) infer_value_type_from_node(file_path string, node ast.Node, src_text tree_sitter.SourceText) &Symbol {
	if node.is_null() {
		return void_sym
	}

	mut type_name := ''

	match node.type_name {
		.none_ {
			// TODO: None is already registered in builtin.v but
			// haven't done interface checking yet
			// type_name = 'none'
			type_name = 'IError'
		}
		.true_, .false_ {
			type_name = 'bool'
		}
		.int_literal {
			type_name = 'int'
		}
		.float_literal {
			type_name = 'f32'
		}
		.rune_literal {
			type_name = 'u8'
		}
		.interpreted_string_literal {
			type_name = 'string'
		}
		.range {
			// TODO: detect starting and ending types
			type_name = '[]int'
		}
		.array {
			if child_type_node := node.named_child(0) {
				inferred_value_sym := ss.infer_value_type_from_node(file_path, child_type_node,
					src_text)
				type_name = '[]' + inferred_value_sym.name
				return ss.find_symbol(file_path, '', type_name) or {
					mut new_array_sym := &Symbol{
						name: type_name
						is_top_level: true
						file_path: os.join_path(ss.get_module_path(file_path, ''), 'placeholder.vv')
						file_version: 0
						kind: .array_
						children_syms: [inferred_value_sym]
					}

					ss.register_symbol(mut new_array_sym) or { return void_sym }

					return new_array_sym
				}
			}
		}
		.binary_expression {
			// TODO:
			left_node := node.child_by_field_name('left') or { return void_sym }
			// op_node := node.child_by_field_name('operator')
			// right_node := node.child_by_field_name('right')
			mut left_sym := ss.infer_value_type_from_node(file_path, left_node, src_text)
			if left_sym.is_returnable() {
				left_sym = left_sym.return_sym
			}
			// right_sym := ss.infer_value_type_from_node(right_node.text(src_text))
			return left_sym
		}
		.unary_expression {
			operator_node := node.child_by_field_name('operator') or { return void_sym }
			operand_node := node.child_by_field_name('operand') or { return void_sym }
			mut op_sym := ss.infer_value_type_from_node(file_path, operand_node, src_text)
			if op_sym.is_returnable() {
				op_sym = op_sym.return_sym
			}

			operator_type_name := operator_node.raw_node.type_name()
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
		.identifier {
			got_sym := ss.infer_symbol_from_node(file_path, node, src_text) or { void_sym }
			if got_sym.is_returnable() {
				return got_sym.return_sym
			}
			return got_sym
		}
		.call_expression {
			got_sym := ss.infer_symbol_from_node(file_path, node, src_text) or { void_sym }
			node_count := node.named_child_count()
			if got_sym.is_returnable() {
				if last_node := node.named_child(node_count - 1) {
					if got_sym.return_sym.kind in [.optional, .result]
						&& last_node.type_name == .option_propagator {
						return got_sym.return_sym.final_sym()
					}
				}
				return got_sym.return_sym
			}
			return got_sym
		}
		.type_selector_expression, .type_cast_expression {
			if type_node := node.child_by_field_name('type') {
				if parent_sym := ss.infer_symbol_from_node(file_path, type_node, src_text) {
					return parent_sym
				}
			}
			return void_sym
		}
		// 'argument_list' {
		// 	return ss.infer_value_type_from_node(node.parent(), src_text)
		// }
		.unsafe_expression {
			if block_node := node.named_child(0) {
				block_child_len := node.named_child_count()
				if block_child_len != u32(1) {
					return void_sym
				}

				if first_node := block_node.named_child(0) {
					return ss.infer_value_type_from_node(file_path, first_node, src_text)
				}
			}

			return void_sym
		}
		.slice_expression {
			// TODO: transfer this to semantic analyzer
			if operand_node := node.child_by_field_name('operand') {
				operand_sym := ss.infer_value_type_from_node(file_path, operand_node,
					src_text)
				if operand_sym.is_void()
					|| (operand_sym.name != 'string' && operand_sym.kind != .array_) {
					return void_sym
				}

				if start_node := node.child_by_field_name('start') {
					start_sym := ss.infer_value_type_from_node(file_path, start_node,
						src_text)
					if start_sym.name != 'int' {
						return void_sym
					}

					if end_node := node.child_by_field_name('end') {
						end_sym := ss.infer_value_type_from_node(file_path, end_node,
							src_text)
						if end_sym.name != 'int' {
							return void_sym
						}

						return operand_sym
					}
				}
			}

			return void_sym
		}
		.index_expression {
			// TODO: transfer this to semantic analyzer
			if operand_node := node.child_by_field_name('operand') {
				operand_sym := ss.infer_value_type_from_node(file_path, operand_node,
					src_text)
				if operand_sym.is_void() {
					return void_sym
				}

				if index_node := node.child_by_field_name('index') {
					index_sym := ss.infer_value_type_from_node(file_path, index_node,
						src_text)
					if index_sym.name != 'int' {
						return void_sym
					}

					return operand_sym.children_syms[0] or { void_sym }
				}
			}

			return void_sym
		}
		else {
			return ss.infer_symbol_from_node(file_path, node, src_text) or { void_sym }
		}
	}

	return ss.find_symbol(file_path, '', type_name) or {
		// ss.report_error(report_error('Invalid type $type_name', node.range()))
		return void_sym
	}
}

// delete_symbol_at_node removes a specific symbol from a specific portion of the node
pub fn (mut ss Store) delete_symbol_at_node(file_path string, root_node ast.Node, src tree_sitter.SourceText, start_line u32, end_line u32) bool {
	// remove by scope
	unsafe {
		ss.opened_scopes[file_path].remove_symbols_by_line(start_line, end_line)
	}

	// remove by node
	mut cursor := new_tree_cursor(root_node, start_line_nr: start_line)

	dir := os.dir(file_path)

	for node in cursor {
		if !within_range(node.range(), start_line, end_line) {
			break
		}

		match node.type_name {
			.const_spec, .global_var_spec, .global_var_declaration, .function_declaration,
			.interface_declaration, .enum_declaration, .type_declaration, .struct_declaration {
				name_node := node.child_by_field_name('name') or { continue }
				idx := ss.symbols[dir].index_by_row(file_path, node.start_point().row)
				if idx != -1 && idx < ss.symbols[dir].len {
					language := ss.symbols[dir][idx].language
					if language != .v {
						symbol_name := name_node.text(src)
						binded_location_idx := ss.binded_symbol_locations.index(symbol_name)
						if binded_location_idx != -1
							&& ss.binded_symbol_locations[binded_location_idx].module_path == dir {
							ss.binded_symbol_locations.delete(binded_location_idx)
						}
					}
					if node.type_name == .function_declaration {
						ss.symbols[dir][idx].scope.remove_symbols_by_line(start_line,
							end_line)
					}
					ss.symbols[dir].delete(idx)
				} else if node.type_name == .function_declaration {
					// for methods
					fn_sym := ss.infer_symbol_from_node(file_path, node, src) or { void_sym }

					// delete the method if and only if method is not void (nor null)
					if !fn_sym.is_void() && !fn_sym.parent_sym.is_void() {
						mut parent_sym := unsafe { fn_sym.parent_sym }
						child_idx := parent_sym.children_syms.index_by_row(file_path,
							node.start_point().row)
						if child_idx != -1 {
							parent_sym.children_syms.delete(child_idx)
						}
					}
				}
			}
			.import_declaration {
				mut imp_module := ss.imports.find_by_position(file_path, node.range()) or {
					continue
				}
				// if the current import node is not the same as before,
				// untrack and remove the import entry asap
				imp_module.untrack_file(file_path)

				// let cleanup_imports do the job
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

pub fn (ss &Store) is_module(file_path string, module_name string) bool {
	_ = ss.get_module_path_opt(file_path, module_name) or { return false }
	return true
}

pub fn (ss &Store) is_imported(importer_file_path string, path string) bool {
	if import_lists := ss.imports[os.dir(importer_file_path)] {
		for imp in import_lists {
			if imp.path != path {
				continue
			}

			if importer_file_path in imp.ranges {
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
