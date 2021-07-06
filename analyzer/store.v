module analyzer

import os
import depgraph

pub struct Store {
pub mut:
	cur_file_path string
	cur_dir string
	cur_file_name string
	imports map[string][]Import
	dependency_tree depgraph.Tree
	messages []Message
	symbols map[string]map[string]&Symbol
	opened_scopes map[string]&ScopeTree
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

pub fn (mut ss Store) set_active_file_path(file_path string) {
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

pub fn (mut ss Store) get_module_path(module_name string) string {
	import_lists := ss.imports[ss.cur_dir]
	for imp in import_lists {
		if imp.module_name == module_name || module_name in imp.aliases {
			return imp.path
		}
	}

	// empty names should return the dir instead
	return ss.cur_dir
}

pub fn (mut ss Store) find_symbol(module_name string, name string) &Symbol {
	if name.len == 0 {
		return analyzer.void_type
	}

	module_path := ss.get_module_path(module_name)
	// defer { unsafe { module_path.free() } }

	typ := ss.symbols[module_path][name] or {
		ss.register_symbol(&Symbol{
			name: name.clone()
			file_path: module_path.clone()
			kind: .placeholder
		}) or { 
			analyzer.void_type
		}
	}

	return typ
}

pub fn (mut ss Store) register_symbol(info &Symbol) ?&Symbol {
	dir := os.dir(info.file_path)
	defer {
		unsafe { dir.free() }
	}

	if info.name in ss.symbols[dir] {
		return report_error('Symbol already exists. (name="${info.name}")', info.range)
	}

	ss.symbols[dir][info.name] = info
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
		mut new_import := Import{ ...imp }
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
	defer { unsafe { dir.free() } }

	mut fetched_symbols := []&Symbol{}
	if syms := ss.symbols[dir] {
		for _, sym in syms {
			if sym.file_path == file_path {
				fetched_symbols << sym
			}
		}
	}
	
	return fetched_symbols
}

pub fn (mut ss Store) delete(dir string, excluded_dir ...string) {
	mut is_used := ss.dependency_tree.has_dependents(dir, ...excluded_dir)
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