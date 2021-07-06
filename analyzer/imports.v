module analyzer

import os
import tree_sitter
import tree_sitter_v.bindings.v

pub struct Import {
mut:
	// resolved indicates that an import's path has been resolved.
	resolved bool

	// imported indicates that the files of the modules are already imported.
	imported bool
pub mut:
	module_name string
	path string

	// track who imported the file
	ranges map[string]C.TSRange

	// original module_names are not recorded as aliases
	// e.g {'file.v': 'foo', 'file1.v': 'bar'}
	aliases map[string]string

	// e.g {'file.v': ['Any', 'decode', 'encode'], 'file2.v': ['foo']}
	symbols map[string][]string
}

pub fn (mut imp Import) set_alias(file_name string, alias string) {
	if alias == imp.module_name {
		return
	}

	imp.aliases[file_name] = alias
}

pub fn (mut imp Import) track_file(file_name string, range C.TSRange) {
	if file_name in imp.ranges && range.eq(imp.ranges[file_name]) {
		return
	}

	imp.ranges[file_name] = range
}

pub fn (mut imp Import) untrack_file(file_name string) {
	if file_name in imp.ranges {
		imp.ranges.delete(file_name)
	}
}

pub fn (mut imp Import) add_symbols(file_name string, symbols ...string) {
	if file_name !in imp.symbols {
		imp.symbols[file_name] = []string{}
	}

	// to avoid duplicate symbols
	for sym_name in symbols {
		mut existing_idx := -1

		for j, existing_sym_name in imp.symbols[file_name] {
			if existing_sym_name == sym_name {
				existing_idx = j
				break
			}
		}

		if existing_idx == -1 {
			imp.symbols[file_name] << sym_name
		} else {
			continue
		}
	}
}

pub fn (mut imp Import) set_symbols(file_name string, symbols ...string) {
	if file_name in imp.symbols {
		mut syms := imp.symbols[file_name]
		for i := 0; i < syms.len; i++ {
			unsafe {
				syms[i].free()
			}

			syms.delete(i)
		}

		unsafe {
			syms.free()
		}
	}

	imp.symbols[file_name] = symbols
}

pub fn (mut imp Import) set_path(path string) {
	if path.len != 0 {
		imp.resolved = true
	}

	imp.path = path
}

[unsafe]
pub fn (imp &Import) free() {
	unsafe {
		imp.module_name.free()
		imp.path.free()
		imp.ranges.free()
		imp.aliases.free()
		imp.symbols.free()
	}
}

pub fn (mut ss Store) register_auto_import(imp Import, to_alias string) {
	ss.auto_imports[to_alias] = imp.path
}

pub fn (mut ss Store) find_import_by_position(range C.TSRange) ?&Import {
	for mut imp in ss.imports[ss.cur_dir] {
		if ss.cur_file_name in imp.ranges && imp.ranges[ss.cur_file_name].start_point.row == range.start_point.row {
			return unsafe { imp }
		}
	}

	return none
}

[manualfree]
fn (mut ss Store) inject_paths_of_new_imports(mut new_imports []&Import, lookup_paths []string) {
	mut project := ss.dependency_tree.get_node(ss.cur_dir) or {
		// TODO: inject builtin directly
		ss.dependency_tree.add({ id: ss.cur_dir })
	}

	for i, new_import in new_imports {
		if new_import.resolved {
			continue
		}

		mod_name_arr := new_import.module_name.split('.')
		for path in lookup_paths {
			mod_dir := os.join_path(path, ...mod_name_arr)
			if ss.dependency_tree.has(mod_dir) {
				new_imports[i].set_path(mod_dir)
				break
			}

			if !os.exists(mod_dir) {
				unsafe { mod_dir.free() }
				continue
			}

			mut files := os.ls(mod_dir) or { 
				unsafe { mod_dir.free() }
				continue
			}

			mut has_v_files := false
			for file in files {
				file_ext := os.file_ext(file)
				if file_ext == v_ext {
					has_v_files = true
					unsafe { 
						file_ext.free()
						file.free()
					}
					break
				}

				unsafe { 
					file_ext.free()
					file.free()
				}
			}

			if !has_v_files {
				unsafe { mod_dir.free() }
				continue
			}

			new_imports[i].set_path(mod_dir)
			ss.dependency_tree.add({ id: mod_dir })
			break
		}

		if new_import.path !in project.dependencies && new_import.path.len != 0 {
			project.dependencies << new_import.path
		}

		if !new_import.resolved {
			ss.report({
				content: 'Module `${new_import.module_name}` not found'
				file_path: ss.cur_file_path.clone()
				range: new_import.ranges[ss.cur_file_name]
			})
			continue
		}

		unsafe { mod_name_arr.free() }
	}
}

pub fn (mut ss Store) cleanup_imports() int {
	mut deleted := 0
	orig_len := ss.imports[ss.cur_dir].len
	for i := 0; i < ss.imports[ss.cur_dir].len; {
		mut imp_module := ss.imports[ss.cur_dir][i]
		if imp_module.ranges.len == 0 || (!imp_module.resolved || !imp_module.imported) {
			// delete in the dependency tree
			mut dep_node := ss.dependency_tree.get_node(ss.cur_dir) or {
				panic('Should not panic. Please file an issue to github.com/vlang/vls.')
				return deleted
			}			

			{
				// intentionally do not use the variables to the same scope
				deleted_idx := dep_node.remove_dependency(imp_module.path)
				assert deleted_idx != -2
			}

			// delete dir if possible
			ss.delete(imp_module.path)
			unsafe { imp_module.free() }

			ss.imports[ss.cur_dir].delete(i)
			deleted++
			continue
		}

		i++
	}

	assert ss.imports[ss.cur_dir].len == orig_len - deleted
	return deleted
}

fn (mut ss Store) scan_imports(tree &C.TSTree, src_text []byte) []&Import {
	root_node := tree.root_node()
	named_child_len := root_node.named_child_count()
	mut newly_imported_modules := []&Import{}

	for i in 0 .. named_child_len {
		node := root_node.named_child(i)
		if node.get_type() != 'import_declaration' {
			continue
		}

		import_path_node := node.child_by_field_name('path')
		if found_imp := ss.find_import_by_position(node.range()) {
			mut imp_module := found_imp
			if imp_module.module_name == import_path_node.get_text(src_text) {
				continue
			}

			// if the current import node is not the same as before,
			// untrack and remove the import entry asap
			imp_module.untrack_file(ss.cur_file_name)
		}

		// resolve it later after 
		mut imp_module, already_imported := ss.add_import({
			resolved: false
			module_name: import_path_node.get_text(src_text)
		})

		import_alias_node := node.child_by_field_name('alias')
		import_symbols_node := node.child_by_field_name('symbols')
		if !import_alias_node.is_null() && import_symbols_node.is_null() {
			imp_module.set_alias(ss.cur_file_name, import_alias_node.named_child(0).get_text(src_text))
		} else if import_alias_node.is_null() && !import_symbols_node.is_null() {
			symbols_len := import_symbols_node.named_child_count()
			mut symbols := []string{len: int(symbols_len)}
			for j := u32(0); j < symbols_len; j++ {
				symbols[j] = import_symbols_node.named_child(j).get_text(src_text)
			}

			imp_module.set_symbols(ss.cur_file_name, ...symbols)
		}
		
		if !already_imported {
			newly_imported_modules << imp_module
		}

		imp_module.track_file(ss.cur_file_name, import_path_node.range())
	}

	return newly_imported_modules
}

pub fn (mut store Store) import_modules_from_tree(tree &C.TSTree, src []byte, lookup_paths []string) {
	mut imports := store.scan_imports(tree, src)
	store.inject_paths_of_new_imports(mut imports, lookup_paths)
	if imports.len == 0 {
		return
	}

	store.import_modules(mut imports, lookup_paths)
}

pub fn (mut store Store) import_modules(mut imports []&Import, lookup_paths []string) {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	defer { unsafe { parser.free() } }

	old_active_path := store.cur_file_path.clone()
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
			tree_from_import := parser.parse_string(content.bytestr())
			store.set_active_file_path(full_path)
			store.import_modules_from_tree(tree_from_import, content, lookup_paths)
			imported++

			mut analyzer := analyzer.Analyzer{ is_import: true }
			analyzer.analyze(tree_from_import.root_node(), content, mut store)

			unsafe {
				content.free()
				tree_from_import.free()
			}
		}

		if imported > 0 {
			imports[i].imported = true
		}

		store.set_active_file_path(old_active_path)
		unsafe { file_paths.free() }
	}
}