module analyzer

import os
import analyzer.depgraph

pub struct Store {
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

pub fn (mut ss Store) clear_messages() {
	for i := 0; ss.messages.len != 0; {
		msg := ss.messages[i]
		unsafe {
			msg.content.free()
		}

		ss.messages.delete(i)
	}
}

pub fn (mut ss Store) report(msg Message) {
	ss.messages << msg
}

pub fn (ss &Store) is_file_active(file_path string) bool {
	return ss.cur_file_path == file_path
}

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

pub fn (ss &Store) get_module_path_opt(module_name string) ?string {
	import_lists := ss.imports[ss.cur_dir]
	for imp in import_lists {
		if imp.module_name == module_name || module_name in imp.aliases {
			return imp.path
		}
	}

	return error('Not found')
}

pub fn (ss &Store) get_module_path(module_name string) string {
	// empty names should return the dir instead
	return ss.get_module_path_opt(module_name) or { ss.cur_dir }
}

pub fn (ss &Store) find_symbol(module_name string, name string) ?&Symbol {
	if name.len == 0 {
		return none
	}

	module_path := ss.get_module_path(module_name)
	idx := ss.symbols[module_path].index(name)
	if idx != -1 {
		return ss.symbols[module_path][idx]
	}

	if aliased_path := ss.auto_imports[module_name] {
		typ := ss.symbols[aliased_path].get(name) ?
		return typ
	}

	// This shouldn't happen
	return none
}

const kinds_to_be_returned = [SymbolKind.chan_, .array_, .map_, .ref]

pub fn (mut ss Store) register_symbol(mut info Symbol) ?&Symbol {
	dir := os.dir(info.file_path)
	defer {
		unsafe { dir.free() }
	}
	mut existing_idx := ss.symbols[dir].index(info.name)
	if existing_idx == -1 {
		// find by row
		existing_idx = ss.symbols[dir].index_by_row(info.range.start_point.row)
	}

	// Replace symbol if symbol already exists
	if existing_idx != -1 {
		mut existing_sym := ss.symbols[dir][existing_idx]

		// Remove this?
		if existing_sym.kind in kinds_to_be_returned {
			// unsafe { info.free() }
			return existing_sym
		}

		if existing_sym.kind != .placeholder && existing_sym.file_version >= info.file_version {
			// unsafe { info.free() }
			return report_error('Symbol already exists. (name="$info.name")', info.range)
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
		existing_sym.return_type = info.parent
		existing_sym.language = info.language
		existing_sym.access = info.access
		existing_sym.kind = info.kind
		existing_sym.range = info.range
		existing_sym.generic_placeholder_len = info.generic_placeholder_len
		existing_sym.file_version = info.file_version
		return existing_sym
	}

	ss.symbols[dir] << info
	return info
}

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
		else {
			unsafe { symbol_name.free() }
			// type_identifier should go here
			symbol_name = node.get_text(src_text)
			return SymbolKind.placeholder, '', symbol_name
		}
	}

	return SymbolKind.typedef, '', 'void'
}

pub fn (store &Store) find_symbol_by_node(node C.TSNode, src_text []byte) ?&Symbol {
	if node.is_null() || src_text.len == 0 {
		return none
	}

	_, module_name, symbol_name := symbol_name_from_node(node, src_text)
	defer {
		unsafe {
			module_name.free()
			symbol_name.free()
		}
	}

	return store.find_symbol(module_name, symbol_name)
}

pub fn (ss &Store) infer_value_type_from_node(node C.TSNode, src_text []byte) &Symbol {
	if node.is_null() {
		return void_type
	}

	node_type := node.get_type()

	// TODO
	mut module_name := ''
	mut type_name := ''

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
		'type_initializer' {
			_, module_name, type_name = symbol_name_from_node(node.child_by_field_name('type'),
				src_text)
		}
		else {}
	}

	got_typ := ss.find_symbol(module_name, type_name) or {
		// name := if module_name.len != 0 { module_name + '.' + type_name } else { type_name }
		// ss.report_error(report_error('Invalid type $name', node.range()))
		return void_type
	}

	return got_typ
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

pub fn (mut ss Store) delete_symbol_at_node(root_node C.TSNode, src []byte, at_range C.TSRange) bool {
	node := search_node(root_node, at_range) or { return false }

	node_type := node.get_type()
	// TODO: parameters, variables, anyhing within the child
	if node_type == 'short_var_declaration' {
		// TODO:
		return false
	}

	match node_type {
		'const_spec', 'function_declaration', 'type_declaration', 'struct_declaration',
		'interface_declaration', 'enum_declaration' {
			name_node := node.child_by_field_name('name')
			symbol_name := name_node.get_text(src)
			if name_node.is_null() || ss.messages.has_range(name_node.range()) {
				// eprintln('ignored')
				return false
			}

			idx := ss.symbols[ss.cur_dir].index(symbol_name)
			if idx != -1 {
				// eprintln('deleted $symbol_name')
				unsafe { ss.symbols[ss.cur_dir].free() }
				ss.symbols[ss.cur_dir].delete(idx)
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
