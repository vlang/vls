module analyzer

import os
import analyzer.depgraph

pub struct Store {
mut:
	anon_fn_counter  int = 1
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
}

// clear_messages clears the stored messages
pub fn (mut ss Store) clear_messages() {
	for i := 0; ss.messages.len != 0; {
		msg := ss.messages[i]
		unsafe {
			msg.content.free()
		}

		ss.messages.delete(i)
	}
}

// report inserts the message to the messages array
pub fn (mut ss Store) report(msg Message) {
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

	unsafe {
		ss.cur_file_path.free()
		ss.cur_dir.free()
		ss.cur_file_name.free()
	}
	ss.cur_file_path = file_path
	ss.cur_dir = os.dir(file_path)
	ss.cur_file_name = os.base(file_path)
}

// get_module_path_opt is a variant of `get_module_path` that returns
// an optional if not found
pub fn (ss &Store) get_module_path_opt(module_name string) ?string {
	import_lists := ss.imports[ss.cur_dir]
	for imp in import_lists {
		if imp.module_name == module_name || module_name in imp.aliases {
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
		idx_from_alias := ss.symbols[aliased_path]?.index(name)
		if idx_from_alias != -1 {
			return ss.symbols[aliased_path][idx_from_alias]
		}
	}

	return error('Symbol `$name` not found.')
}

const anon_fn_prefix = '#anon_'

// find_fn_symbol finds the function symbol with the appropriate parameters and return type
pub fn (ss &Store) find_fn_symbol(module_name string, return_type &Symbol, params []&Symbol) ?&Symbol {
	module_path := ss.get_module_path(module_name)
	for sym in ss.symbols[module_path]? {
		if sym.kind == .function_type && sym.name.starts_with(analyzer.anon_fn_prefix) && sym.generic_placeholder_len == 0 {
			mut params_to_check := params.len
			for i, child in sym.children {
				if child.kind == .variable {
					if child.name == params[i].name && child.return_type.name == params[i].return_type.name {
						params_to_check--
						continue
					}
					break
				}
			}
			if params_to_check != 0 || sym.return_type.name != return_type.name {
				continue
			}
			return sym
		}
	}
	return none
}

const kinds_to_be_returned = [SymbolKind.chan_, .array_, .map_, .ref]

// register_symbol registers the given symbol
pub fn (mut ss Store) register_symbol(mut info Symbol) ?&Symbol {
	dir := os.dir(info.file_path)
	defer {
		unsafe { dir.free() }
	}
	mut existing_idx := ss.symbols[dir].index(info.name)
	if existing_idx == -1 {
		// find by row
		existing_idx = ss.symbols[dir].index_by_row(info.file_path, info.range.start_point.row)
	}

	// Replace symbol if symbol already exists
	// the info.kind condition is used for typedefs with anon fn types
	if existing_idx != -1 && (info.kind != .typedef && ss.symbols[dir][existing_idx].kind != .function_type) {
		mut existing_sym := ss.symbols[dir][existing_idx]

		// Remove this?
		if existing_sym.kind !in kinds_to_be_returned {
			if existing_sym.kind != .placeholder && existing_sym.file_version >= info.file_version {
				return report_error('Symbol already exists. (idx=${existing_idx}) (name="$existing_sym.name")', info.range)
			}

			if existing_sym.name != info.name {
				// unsafe { existing_sym.name.free() }
				existing_sym.name = info.name.clone()
			}

			if existing_sym.children.len != 0 {
				// unsafe { existing_sym.children.free() }
				existing_sym.children = info.children.clone()
				// unsafe { info.children.free() }
			}

			existing_sym.parent = info.parent
			existing_sym.return_type = info.return_type
			existing_sym.language = info.language
			existing_sym.access = info.access
			existing_sym.kind = info.kind
			existing_sym.range = info.range
			existing_sym.generic_placeholder_len = info.generic_placeholder_len
			existing_sym.file_version = info.file_version
		}

		return existing_sym
	}

	ss.symbols[dir] << info
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
			if imp.module_name == stored_imp.module_name {
				idx = i
				break
			}
		}
	} else {
		ss.imports[dir] = []Import{}
	}

	if idx == -1 {
		mut new_import := Import{
			...imp
		}
		if new_import.path.len != 0 && !new_import.resolved {
			new_import.resolved = true
		}

		ss.imports[dir] << new_import
		last_idx := ss.imports[dir].len - 1
		return &ss.imports[dir][last_idx], false
	} else {
		unsafe { imp.free() }
		return &ss.imports[dir][idx], true
	}
}

// get_symbols_by_file_path retrieves the symbols based on the given file path
pub fn (ss &Store) get_symbols_by_file_path(file_path string) []&Symbol {
	dir := os.dir(file_path)
	defer {
		unsafe { dir.free() }
	}

	mut fetched_symbols := []&Symbol{}
	if dir in ss.symbols {
		for name, mut sym in ss.symbols[dir] {
			if sym.file_path == file_path {
				fetched_symbols << ss.symbols[dir][name]
			}
		}
	}

	return fetched_symbols
}

// delete removes the given path of a workspace/project if possible.
// The directory is only deleted if there are no projects dependent on it.
// It also removes the dependencies with the same condition
pub fn (mut ss Store) delete(dir string, excluded_dir ...string) {
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

			ss.symbols[dir].free()
		}
		ss.symbols.delete(dir)
		for i := 0; ss.imports[dir].len != 0; {
			unsafe { ss.imports[dir][i].free() }
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
		ss.opened_scopes[ss.cur_file_path].children << &ScopeTree{
			start_byte: node.start_byte()
			end_byte: node.end_byte()
			parent: ss.opened_scopes[ss.cur_file_path]
		}

		return ss.opened_scopes[ss.cur_file_path].children.last()
	}
}

// symbol_name_from_node extracts the symbol's kind, name, and module name from the given node
pub fn symbol_name_from_node(node C.TSNode, src_text []byte) (SymbolKind, string, string) {
	if node.is_null() {
		return SymbolKind.typedef, '', 'void'
	}

	mut module_name := ''
	mut symbol_name := ''
	unsafe {
		module_name.free()
		symbol_name.free()
	}
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
				unsafe {
					val_module_name.free()
					val_symbol_name.free()
				}
				// if key type uses a custom type, return the symbol in the key's origin module
				return SymbolKind.map_, key_module_name, 'map[$key_symbol_name]' +
					node.child_by_field_name('value').get_text(src_text)
				// if key is builtin type and key type is not, use the module from the value type
			} else if key_module_name.len == 0 && val_module_name.len != 0 {
				unsafe {
					key_module_name.free()
					key_symbol_name.free()
				}
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
			return SymbolKind.optional, module_name, '?' + symbol_name
		}
		'function_type' {
			return SymbolKind.function_type, module_name, symbol_name
		}
		else {
			unsafe { symbol_name.free() }
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
	defer {
		unsafe {
			module_name.free()
			symbol_name.free()
		}
	}

	if sym_kind == .function_type {
		mut parameters := extract_parameter_list(node.child_by_field_name('parameters'), mut store, src_text)
		return_type := store.find_symbol_by_type_node(node.child_by_field_name('result'), src_text) or { analyzer.void_type }
		return store.find_fn_symbol(module_name, return_type, parameters) or {
			mut new_sym := Symbol{
				name: analyzer.anon_fn_prefix + store.anon_fn_counter.str()
				file_path: store.cur_file_path
				file_version: store.cur_version
				kind: sym_kind
				return_type: return_type
			}

			for mut param in parameters {
				new_sym.add_child(mut *param) or {
					continue
				}
			} 

			store.anon_fn_counter++
			store.register_symbol(mut new_sym) or { analyzer.void_type }
		}
	}

	return store.find_symbol(module_name, symbol_name) or {
		mut new_sym := Symbol{
			name: symbol_name.clone()
			file_path: os.join_path(store.get_module_path(module_name), 'placeholder.vv')
			kind: sym_kind
		}

		match sym_kind {
			.array_ {
				mut el_sym := store.find_symbol_by_type_node(node.child_by_field_name('element'), src_text) ?
				new_sym.add_child(mut el_sym) or {}
			}
			.map_ {
				mut key_sym := store.find_symbol_by_type_node(node.child_by_field_name('key'), src_text) ?
				new_sym.add_child(mut key_sym) or {}
				mut val_sym := store.find_symbol_by_type_node(node.child_by_field_name('value'), src_text) ?
				new_sym.add_child(mut val_sym) or {}
			}
			.chan_, .ref, .optional {
				mut ref_sym := store.find_symbol_by_type_node(node.named_child(0), src_text) ?
				new_sym.add_child(mut ref_sym) or {}
			}
			else {}
		}

		// eprintln(new_sym)
		store.register_symbol(mut new_sym) or { analyzer.void_type }
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
	// eprintln(node_type)

	// TODO
	mut module_name := ''
	mut type_name := ''

	defer {
		unsafe {
			// node_type.free()
			module_name.free()
			type_name.free()
		}
	}

	match node_type {
		'identifier' {
			// Identifier symbol finding strategy
			// Find first in symbols
			// find the symbol in scopes
			// return void if none
			ident_text := node.get_text(src_text)
			return ss.find_symbol(module_name, ident_text) or {
				selected_scope := ss.opened_scopes[ss.cur_file_path]?.innermost(node.start_byte(), node.end_byte())
				selected_scope.get_symbol(ident_text) ?
			}
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
				selected_scope := ss.opened_scopes[ss.cur_file_path].innermost(node.start_byte(), node.end_byte())
				selected_scope.get_symbol(ident_text) ?
			}
		}
		'enum_identifier' {
			mut parent := node.parent()
			// TODO: assignment_declaration
			// if parent.get_type() != 'literal_value' {
			// 	parent = parent.parent()
			// }
			parent_sym := ss.infer_symbol_from_node(parent, src_text) ?
			child_sym := parent_sym.children.get(node.named_child(0).get_text(src_text)) ?
			return child_sym
		}
		'type_initializer' {
			return ss.find_symbol_by_type_node(node.child_by_field_name('type'), src_text)
		}
		'type_identifier' {
			// eprintln(node.get_text(src_text))
			return ss.find_symbol_by_type_node(node, src_text)
		}
		'selector_expression' {
			root_sym := ss.infer_value_type_from_node(node.child_by_field_name('operand'), src_text)
			if !root_sym.is_void() {
				child_sym := root_sym.children.get(node.child_by_field_name('field').get_text(src_text)) or { 
					return analyzer.void_type 
				}
				return child_sym
			}

			module_name = node.child_by_field_name('operand').get_text(src_text)
			type_name = node.child_by_field_name('field').get_text(src_text)
		}
		'keyed_element' {
			mut parent := node.parent()
			if parent.get_type() == 'literal_value' {
				parent = parent.parent()
			}
			parent_sym := ss.infer_symbol_from_node(parent, src_text) ?	
			child_sym := parent_sym.children.get(node.child_by_field_name('key').get_text(src_text)) ?
			return child_sym.return_type
		}
		'call_expression' {
			return ss.infer_symbol_from_node(node.child_by_field_name('function'), src_text)
		}
		'parameter_declaration' {
			mut parent := node.parent()
			for parent.get_type() != 'function_declaration' {
				parent = parent.parent()
			}

			// eprintln(parent.get_type())
			parent_sym := ss.infer_symbol_from_node(parent.child_by_field_name('name'), src_text) ?	
			child_sym := parent_sym.children.get(node.child_by_field_name('name').get_text(src_text)) ?
			return child_sym			
		}
		'struct_field_declaration' {
			mut parent := node.parent()
			for parent.get_type() != 'struct_declaration' {
				parent = parent.parent()
			}

			// eprintln(parent.get_type())
			parent_sym := ss.infer_symbol_from_node(parent.child_by_field_name('name'), src_text) ?	
			child_sym := parent_sym.children.get(node.child_by_field_name('name').get_text(src_text)) ?
			return child_sym
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
		return void_type
	}

	node_type := node.get_type()

	// TODO
	mut module_name := ''
	mut type_name := ''

	defer {
		unsafe {
			module_name.free()
			type_name.free()
		}
	}

	match node_type {
		'identifier' {
			// Identifier symbol finding strategy
			// Find first in symbols
			// find the symbol in scopes
			// return void if none
			ident_text := node.get_text(src_text)
			got_sym := ss.find_symbol(module_name, ident_text) or {
				selected_scope := ss.opened_scopes[ss.cur_file_path].innermost(node.start_byte(), node.end_byte())
				selected_scope.symbols.get(ident_text) or { 
					analyzer.void_type
				}
			}

			if got_sym.kind == .variable {
				return got_sym.return_type
			}

			return got_sym
		}
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
		'type_initializer' {
			return ss.find_symbol_by_type_node(node.child_by_field_name('type'), src_text) or {
				return analyzer.void_type
			}
		}
		'type_identifier' {
			return ss.find_symbol_by_type_node(node, src_text) or { analyzer.void_type }
		}
		'selector_expression' {
			root_sym := ss.infer_value_type_from_node(node.child_by_field_name('operand'), src_text)
			if root_sym.is_void() {
				child_sym := root_sym.children.get(node.child_by_field_name('field').get_text(src_text)) or { 
					return analyzer.void_type 
				}

				return child_sym
			}

			module_name = node.child_by_field_name('operand').get_text(src_text)
			type_name = node.child_by_field_name('field').get_text(src_text)
		}
		else {
			// eprintln(node_type)
			// return analyzer.void_type
		}
	}

	return ss.find_symbol(module_name, type_name) or {
		name := if module_name.len != 0 { module_name + '.' + type_name } else { type_name }
		ss.report_error(report_error('Invalid type $name', node.range()))
		return analyzer.void_type
	}
}

fn within_range(node C.TSNode, range C.TSRange) bool {
	if node.is_null() {
		return false
	}

	return (node.start_byte() >= range.start_byte && node.start_byte() <= range.end_byte)
		|| (node.end_byte() >= range.start_byte && node.end_byte() <= range.end_byte)
}

fn search_node(node C.TSNode, range C.TSRange) ?C.TSNode {
	if within_range(node, range) {
		return node
	}

	return search_node_in_children(node, range)
}

fn search_node_in_children(node C.TSNode, range C.TSRange) ?C.TSNode {
	child_count := node.named_child_count()
	for i in u32(0) .. child_count {
		child := node.named_child(i)
		return search_node(child, range) or { continue }
	}

	return none
}

// delete_symbol_at_node removes a specific symbol from a specific portion of the node
pub fn (mut ss Store) delete_symbol_at_node(root_node C.TSNode, src []byte, at_range C.TSRange) bool {
	node := search_node(root_node, at_range) or { return false }
	node_type := node.get_type()
	// TODO: parameters, variables, anyhing within the child
	// eprintln(node_type)
	if node_type == 'short_var_declaration' {
		// left_expr_lists := node.child_by_field_name('left')
		// left_child_count := left_expr_lists.named_child_count()
		// eprintln(left_child_count)

		// root_scope := ss.opened_scopes[ss.cur_file_path] or {
		// 	return false
		// }

		// mut scope := root_scope.innermost(at_range.start_byte)
		// for i in u32(0) .. left_child_count {
		// 	child_node := node.named_child(i)
		// 	eprintln('deleting ${child_node.get_text(src)}')
		// 	scope.remove(child_node.get_text(src))
		// }
		// return true
		return false
	}

	match node_type {
		'const_spec', 'function_declaration', 'type_declaration', 'struct_declaration',
		'interface_declaration', 'enum_declaration' {
			name_node := node.child_by_field_name('name')
			symbol_name := name_node.get_text(src)
			if name_node.is_null() || ss.messages.has_range(ss.cur_file_path, name_node.range()) {
				// eprintln('ignored')
				return false
			}

			idx := ss.symbols[ss.cur_dir].index(symbol_name)
			if idx != -1 {
				unsafe { ss.symbols[ss.cur_dir].free() }
				ss.symbols[ss.cur_dir].delete(idx)
				// eprintln('deleted $symbol_name at $idx')
				// eprintln(ss.symbols[ss.cur_dir])
				return true
			}
		}
		'import_declaration' {
			mut imp := ss.find_import_by_position(node.range()) or { return false }
			imp.untrack_file(ss.cur_file_path)
			// let cleanup_imports do the job
		}
		'source_file' {
			child_node := search_node_in_children(node, at_range) or { return false }

			return ss.delete_symbol_at_node(child_node, src, child_node.range())
		}
		'identifier' {
			return ss.delete_symbol_at_node(node.parent(), src, node.parent().range())
		}
		else {}
	}

	return false
}
