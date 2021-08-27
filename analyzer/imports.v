module analyzer

import os
import tree_sitter
import tree_sitter_v as v

pub struct Import {
mut:
	// resolved indicates that an import's path has been resolved.
	resolved bool
	// imported indicates that the files of the modules are already imported.
	imported bool
pub mut:
	// absolute_module_name is the name that was declared when imported.
	absolute_module_name string
	// module_name is the name to be used for symbol lookups
	module_name string
	// path is the path where the module was located.
	path string
	// track the location of the import statements
	// this one uses the full path instead of the usual file name
	// for error reporting (just in case)
	ranges map[string]C.TSRange
	// original module_names are not recorded as aliases
	// e.g {'file.v': 'foo', 'file1.v': 'bar'}
	aliases map[string]string
	// e.g {'file.v': ['Any', 'decode', 'encode'], 'file2.v': ['foo']}
	symbols map[string][]string
}

// set_alias records/changes the alias of the import from the file
pub fn (mut imp Import) set_alias(file_name string, alias string) {
	if alias == imp.module_name {
		return
	}

	if imp.aliases.len == 0 {
		unsafe { imp.aliases[file_name].free() }
	}

	imp.aliases[file_name] = alias.clone()
}

// track_file records the location of the import declaration of a file
pub fn (mut imp Import) track_file(file_name string, range C.TSRange) {
	if file_name in imp.ranges && range.eq(imp.ranges[file_name]) {
		return
	}

	imp.ranges[file_name] = range
}

// untrack_file removes the location of the import declaration of a file
pub fn (mut imp Import) untrack_file(file_name string) {
	if file_name in imp.ranges {
		imp.ranges.delete(file_name)
	}
}

// set_symbols records/changes the imported symbols on a specific file
pub fn (mut imp Import) set_symbols(file_name string, symbols ...string) {
	if file_name in imp.symbols {
		for i := 0; imp.symbols[file_name].len != 0; {
			unsafe { imp.symbols[file_name][i].free() }
			imp.symbols[file_name].delete(i)
		}
		unsafe { imp.symbols[file_name].free() }
	}

	imp.symbols[file_name] = symbols
}

// set_path changes the path of a given import
pub fn (mut imp Import) set_path(path string) {
	if path.len == 0 {
		return
	}

	imp.resolved = true
	imp.path = path.clone()
}

[unsafe]
pub fn (imp &Import) free() {
	unsafe {
		imp.absolute_module_name.free()
		imp.module_name.free()
		imp.path.free()
		imp.ranges.free()
		imp.aliases.free()
		imp.symbols.free()
	}
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
		if ss.cur_file_path in imp.ranges && imp.ranges[ss.cur_file_path].start_point.row == range.start_point.row {
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
				unsafe { mod_dir.free() }
				continue
			}

			mut has_v_files := false

			// files is just for checking so it
			// is not used by the code below it
			{
				mut files := os.ls(mod_dir) or {
					unsafe { mod_dir.free() }
					continue
				}

				// search for files end with v and free
				// the contents of the array at the same time
				for j := 0; files.len != 0; {
					if !has_v_files {
						file_ext := os.file_ext(files[j])
						if file_ext == v_ext {
							has_v_files = true
						}

						unsafe { file_ext.free() }
					}

					unsafe { files[j].free() }
					files.delete(j)
				}

				unsafe { files.free() }
			}
			if has_v_files {
				new_import.set_path(mod_dir)
				ss.dependency_tree.add(mod_dir)
				break
			}

			unsafe { mod_dir.free() }
		}

		// report the unresolved import
		if !new_import.resolved {
			for file_path, range in new_import.ranges {
				ss.report(
					content: 'Module `$new_import.absolute_module_name` not found'
					file_path: file_path.clone()
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
		unsafe { mod_name_arr.free() }
	}
}

// cleanup_imports removes the unused imports from the current directory.
// This should be used after executing `import_modules_from_tree` or `import_modules`.
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

			if i < ss.imports[ss.cur_dir].len {
				ss.imports[ss.cur_dir].delete(i)
			}
			
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
		if node.is_null() || node.get_type() != 'import_declaration' {
			continue
		}

		import_path_node := node.child_by_field_name('path')
		if found_imp := ss.find_import_by_position(node.range()) {
			mut imp_module := found_imp
			mod_name := import_path_node.get_text(src_text)
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
			absolute_module_name: import_path_node.get_text(src_text)
		)

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

		imp_module.track_file(ss.cur_file_path, import_path_node.range())
	}

	return newly_imported_modules
}

// import_modules_from_tree scans and imports the modules based from the AST tree
pub fn (mut store Store) import_modules_from_tree(tree &C.TSTree, src []byte, lookup_paths ...string) {
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
	defer {
		unsafe { parser.free() }
	}

	old_version := store.cur_version
	old_active_path := store.cur_file_path.clone()
	old_active_dir := store.cur_dir.clone()
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
			tree_from_import := parser.parse_string(content.bytestr())

			// Set version to zero so that modules who are already opened
			// in the editors can register symbols with scopes without
			// getting "symbol exists" errors
			store.set_active_file_path(full_path, 0)

			// Import module but from different lookup oath other than the project
			modules_from_dir := os.join_path(store.cur_dir, 'modules')
			store.import_modules_from_tree(tree_from_import, content, modules_from_dir,
				old_active_dir, modules_from_old_dir)
			imported++

			{
				root_node := tree_from_import.root_node()
				child_len := int(root_node.child_count())

				mut sr := SymbolRegistration{
					store: unsafe { store }
					src_text: content
					is_import: true
					cursor: TreeCursor{
						child_count: u32(child_len), 
						cursor: root_node.tree_cursor()
					}
				}

				sr.get_scope(sr.cursor.current_node()) or {}
				sr.cursor.to_first_child()

				for _ in 0 .. child_len {
					sr.top_level_decl() or {
						sr.store.report_error(err)
						continue
					}
				}

				unsafe { sr.cursor.free() }
			}

			parser.reset()
			unsafe {
				// modules_from_dir.free()
				content.free()
				tree_from_import.free()
			}
		}

		if imported > 0 {
			imports[i].imported = true
		}

		store.set_active_file_path(old_active_path, old_version)
		unsafe { file_paths.free() }
	}

	unsafe {
		// modules_from_old_dir.free()
		// old_active_path.free()
		// old_active_dir.free()
	}
}

pub fn (ss &Store) is_module(module_name string) bool {
	_ = ss.get_module_path_opt(module_name) or {
		return false
	}
	return true
}
