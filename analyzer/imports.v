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

const v_ext = '.v'

[manualfree]
fn (mut ss Store) inject_paths_of_new_imports(mut new_imports []&Import, lookup_paths []string) {
	dir := os.dir(ss.cur_file_path)
	defer {
		unsafe { dir.free() }
	}

	mut project := ss.dependency_tree.get_node(dir) or {
		// TODO: inject builtin directly
		ss.dependency_tree.add({ id: dir })
	}

	for i, new_import in new_imports {
		if new_import.resolved {
			continue
		}

		mod_name_arr := new_import.module_name.split('.')
		for path in lookup_paths {
			mod_dir := os.join_path(path, mod_name_arr.join(os.path_separator))		

			if ss.dependency_tree.has(mod_dir) {
				new_imports[i].set_path(mod_dir)
				break
			}

			if !os.exists(mod_dir) {
				unsafe { 
					mod_name_arr.free()
					mod_dir.free()
				}
				continue
			}

			mut files := os.ls(mod_dir) or { 
				unsafe { 
					mod_name_arr.free()
					mod_dir.free()
				}
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
				unsafe { 
					mod_dir.free()
				}
				continue
			}

			new_imports[i].set_path(mod_dir)
			ss.dependency_tree.add({ id: mod_dir })
			break
		}

		if new_import.path !in project.dependencies {
			project.dependencies << new_import.path
		}

		// unsafe { mod_name_arr.free() }
		if !new_import.resolved {
			ss.report({
				content: 'Module `${new_import.module_name}` not found'
				file_path: ss.cur_file_path
				range: new_import.ranges[os.base(ss.cur_file_path)]
			})
			continue
		}
	}
}

fn (mut store Store) scan_imports(tree &C.TSTree, src_text []byte) []&Import {
	root_node := tree.root_node()
	named_child_len := root_node.named_child_count()
	mut newly_imported_modules := []&Import{}

	for i in 0 .. named_child_len {
		node := root_node.named_child(i)
		if node.get_type() != 'import_declaration' {
			continue
		}

		import_path_node := node.child_by_field_name('path')

		// resolve it later after 
		mut imp_module, already_imported := store.add_import({
			resolved: false
			module_name: import_path_node.get_text(src_text)
		})

		import_alias_node := node.child_by_field_name('alias')
		import_symbols_node := node.child_by_field_name('symbols')

		file_name := os.base(store.cur_file_path)
		defer { 
			unsafe { file_name.free() } 
		}
		if !import_alias_node.is_null() && import_symbols_node.is_null() {
			imp_module.set_alias(file_name, import_alias_node.named_child(0).get_text(src_text))
		} else if import_alias_node.is_null() && !import_symbols_node.is_null() {
			symbols_len := import_symbols_node.named_child_count()
			mut symbols := []string{len: int(symbols_len)}
			for j := u32(0); j < symbols_len; j++ {
				symbols[j] = import_symbols_node.named_child(j).get_text(src_text)
			}

			imp_module.set_symbols(file_name, ...symbols)
		}
		
		if !already_imported {
			newly_imported_modules << imp_module
		}

		imp_module.track_file(file_name, node.range())
	}

	return newly_imported_modules
}

fn (mut store Store) import_modules(tree &C.TSTree, src []byte) {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)

	old_active_path := store.cur_file_path.clone()
	mut imports := store.scan_imports(tree, src)
	store.inject_paths_of_new_imports(mut imports, [
		os.join_path(vexe_path, 'vlib')
	])

	if imports.len == 0 {
		return
	}

	for i, new_import in imports {
		// skip if import is not resolved or already imported
		if !new_import.resolved || new_import.imported {
			continue
		}

		file_paths := os.ls(new_import.path) or { continue }
		mut imported := 0
		for file_name in file_paths {
			if !file_name.ends_with(v_ext) || file_name.ends_with('_test.v') {
				continue
			}

			full_path := os.join_path(new_import.path, file_name)
			content := os.read_bytes(full_path) or { continue }
			tree_from_import := parser.parse_string(content.bytestr())
			store.set_active_file_path(full_path)
			store.import_modules(tree_from_import, content)
			imported++

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

	unsafe { parser.free() }
}