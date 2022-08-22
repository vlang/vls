module analyzer

import os
import ast

pub type ImportsMap = map[string][]Import

pub struct Importer {
mut:
	context AnalyzerContext
}

pub fn (mut imp Importer) imports() ImportsMap {
	return imp.context.store.imports
}

pub fn (mut imp Importer) scan_imports(tree &ast.Tree) []&Import {
	root_node := tree.root_node()
	named_child_len := root_node.named_child_count()
	mut newly_imported_modules := []&Import{}

	for i in 0 .. named_child_len {
		node := root_node.named_child(i) or { continue }
		if node.type_name != .import_declaration {
			continue
		}

		import_path_node := node.child_by_field_name('path') or { continue }

		if found_imp := imp.imports().find_by_position(imp.context.file_path, node.range()) {
			mut imp_module := unsafe { found_imp }
			mod_name := import_path_node.text(imp.context.text)
			if imp_module.absolute_module_name == mod_name {
				continue
			}

			// if the current import node is not the same as before,
			// untrack and remove the import entry asap
			imp_module.untrack_file(imp.context.file_path)
		}

		// resolve it later after
		mut imp_module, already_imported := imp.context.store.add_import(
			imp.context.file_dir,
			resolved: false
			absolute_module_name: import_path_node.text(imp.context.text)
		)

		if import_alias_node := node.child_by_field_name('alias') {
			if ident_node := import_alias_node.named_child(0) {
				imp_module.set_alias(imp.context.file_name, ident_node.text(imp.context.text))
			}
		} else if import_symbols_node := node.child_by_field_name('symbols') {
			symbols_len := import_symbols_node.named_child_count()
			mut symbols := []string{len: int(symbols_len)}
			for j := u32(0); j < symbols_len; j++ {
				symbols[j] = import_symbols_node.named_child(j) or { continue }.text(imp.context.text)
			}

			imp_module.set_symbols(imp.context.file_name, ...symbols)
		}

		if !already_imported {
			newly_imported_modules << imp_module
		}

		imp_module.track_file(imp.context.file_path, import_path_node.range())
	}

	return newly_imported_modules
}

// inject_paths_of_new_imports resolves and injects the path to the Import instance
pub fn (mut imp Importer) inject_paths_of_new_imports(mut new_imports []&Import, lookup_paths ...string) {
	dir := imp.context.file_dir
	mut project := imp.context.store.dependency_tree.get_node(dir) or { imp.context.store.dependency_tree.add(dir) }

	// Custom iterator for looping over paths without
	// allocating a new array with concatenated items
	// Might be "smart" but I'm just testing my hypothesis
	// if it will be better for the memory consumption ~ Ned
	mut import_path_iter := ImportPathIterator{
		start_path: imp.context.file_dir
		lookup_paths: lookup_paths
		fallback_lookup_paths: imp.context.store.default_import_paths
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
			if imp.context.store.dependency_tree.has(mod_dir) {
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
				imp.context.store.dependency_tree.add(mod_dir)
				break
			}
		}

		// report the unresolved import
		if !new_import.resolved {
			for file_path, range in new_import.ranges {
				imp.context.store.report(
					message: 'Module `$new_import.absolute_module_name` not found'
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

// import_modules imports the given Import array to the current directory.
// It also registers the symbols to the store.
pub fn (mut imp Importer) import_modules(mut imports []&Import) {
	mut parser := ast.new_parser()
	modules_from_old_dir := os.join_path(imp.context.file_dir, 'modules')

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
			content_str := os.read_file(full_path) or { continue }
			tree_from_import := parser.parse_string(source: content_str)
			context := imp.context.store.with(file_path: full_path, text: Runes(content_str.runes()))

			// Import module but from different lookup oath other than the project
			modules_from_dir := os.join_path(context.file_dir, 'modules')
			import_modules_from_tree(context, tree_from_import, modules_from_dir,
				imp.context.file_dir, modules_from_old_dir)
			imported++

			// Set version to zero so that modules that are already opened
			// in the editor can register symbols with scopes without
			// getting "symbol exists" errors
			imp.context.store.register_symbols_from_tree(context, tree_from_import, true)
			parser.reset()
		}

		if imported > 0 {
			imports[i].imported = true
		}

		unsafe { file_paths.free() }
	}
}

// add_imports adds/registers the import. it returns a boolean
// to indicate if the import already exist in the array.
pub fn (mut ss Store) add_import(to_dir string, imp Import) (&Import, bool) {
	mut idx := -1
	if to_dir in ss.imports {
		// check if import has already imported
		for i, stored_imp in ss.imports[to_dir] {
			if imp.absolute_module_name == stored_imp.absolute_module_name {
				idx = i
				break
			}
		}
	} else {
		ss.imports[to_dir] = []Import{}
	}

	if idx == -1 {
		ss.imports[to_dir] << Import{
			...imp
			module_name: imp.absolute_module_name.all_after_last('.')
			resolved: imp.resolved || imp.path.len != 0
		}

		last_idx := ss.imports[to_dir].len - 1
		return &ss.imports[to_dir][last_idx], false
	} else {
		// unsafe { imp.free() }
		return &ss.imports[to_dir][idx], true
	}
}

// import_modules_from_tree scans and imports the modules based from the AST tree
pub fn import_modules_from_tree(context AnalyzerContext, tree &ast.Tree, lookup_paths ...string) {
	mut importer := Importer{
		context: context
	}

	mut imports := importer.scan_imports(tree)
	importer.inject_paths_of_new_imports(mut imports, ...lookup_paths)
	if imports.len == 0 {
		return
	}

	importer.import_modules(mut imports)
}

// cleanup_imports removes the unused imports from the current directory.
// This should be used after executing `import_modules_from_tree` or `import_modules`.
pub fn (mut ss Store) cleanup_imports(from_dir string) int {
	mut deleted := 0
	for i := 0; i < ss.imports[from_dir].len; {
		mut imp_module := ss.imports[from_dir][i]
		if imp_module.ranges.len == 0 || (!imp_module.resolved || !imp_module.imported) {
			// delete in the dependency tree
			mut dep_node := ss.dependency_tree.get_node(from_dir) or {
				panic('Should not panic. Please file an issue to github.com/vlang/vls.')
				return deleted
			}

			// intentionally do not use the variables to the same scope
			dep_node.remove_dependency(imp_module.path)

			// delete dir if possible
			ss.delete(imp_module.path)
			// unsafe { imp_module.free() }

			if i < ss.imports[from_dir].len {
				ss.imports[from_dir].delete(i)
			}

			deleted++
			continue
		}

		i++
	}

	return deleted
}

pub struct Import {
pub mut:
	// resolved indicates that an import's path has been resolved.
	resolved bool
	// imported indicates that the files of the modules are already imported.
	imported bool
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

	// if imp.aliases.len == 0 {
	// 	unsafe { imp.aliases[file_name].free() }
	// }

	imp.aliases[file_name] = alias
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
			// unsafe { imp.symbols[file_name][i].free() }
			imp.symbols[file_name].delete(i)
		}
		// unsafe { imp.symbols[file_name].free() }
	}

	imp.symbols[file_name] = symbols
}

// set_path changes the path of a given import
pub fn (mut imp Import) set_path(path string) {
	if path.len == 0 {
		return
	}

	imp.resolved = true
	imp.path = path
}

[unsafe]
pub fn (imp &Import) free() {
	unsafe {
		// imp.absolute_module_name.free()
		// imp.module_name.free()
		// imp.path.free()
		imp.ranges.free()
		imp.aliases.free()
		imp.symbols.free()
	}
}

// find_by_position locates the import of the current directory
// based on the given range
pub fn (imports ImportsMap) find_by_position(file_path string, range C.TSRange) ?&Import {
	dir := os.dir(file_path)
	for mut imp in imports[dir] {
		if file_path !in imp.ranges {
			continue
		} else if imp.ranges[file_path].start_point.row == range.start_point.row {
			return unsafe { imp }
		}
	}
	return none
}
