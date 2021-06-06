module analyzer

import os

pub struct Store {
pub mut:
	cur_file_path string
	imports map[string][]Import
	imported_paths []string
	messages []Message
	symbols map[string]map[string]&Symbol
	opened_scopes map[string]&ScopeTree
}

pub fn (ss &Store) is_file_active(file_path string) bool {
	return ss.cur_file_path == file_path
}

pub fn (mut ss Store) set_active_file_path(file_path string) {
	if ss.is_file_active(file_path) {
		return
	}

	unsafe { ss.cur_file_path.free() }
	ss.cur_file_path = file_path
}

pub fn (mut ss Store) get_module_path(module_name string) string {
	dir := os.dir(ss.cur_file_path)
	import_lists := ss.imports[dir]
	for imp in import_lists {
		if imp.module_name == module_name || module_name in imp.aliases {
			unsafe { dir.free() } 
			return imp.path
		}
	}

	// empty names should return the dir instead
	return dir
}

pub fn (mut ss Store) find_symbol(module_name string, name string) &Symbol {
	if name.len == 0 {
		return analyzer.void_type
	}

	module_path := ss.get_module_path(module_name)
	defer { unsafe { module_path.free() } }

	typ := ss.symbols[module_path][name] or {
		ss.register_symbol(&Symbol{
			name: name.clone()
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

pub fn (mut ss Store) add_import(imp Import) {
	mut idx := -1

	dir := os.dir(ss.cur_file_path)
	defer { unsafe { dir.free() } }
	if dir in ss.imports {
		// check if import has already imported
		for i, stored_imp in ss.imports[dir] {
			if stored_imp.module_name == imp.module_name && stored_imp.path == imp.path {
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

		if imp.path !in ss.imported_paths {
			ss.imported_paths << new_import.path
		}
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