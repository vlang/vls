module analyzer

// import tree_sitter

pub struct Import {
mut:
	resolved bool
pub mut:
	module_name string
	path string

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

// fn get_import_dir_and_files(mod string, paths ...string) ?(string, []string) {
// 	for path in prefs.lookup_path {
// 		mod_dir := os.join_path(path, mod.split('.').join(os.path_separator))

// 		// if directory does not exist, proceed to another lookup path
// 		if !os.exists(mod_dir) {
// 			continue
// 		}
		
// 		mut files := os.ls(mod_dir) or { 
// 			// break loop if files is empty
// 			break
// 		}

// 		filtered_files := prefs.should_compile_filtered_files(mod_dir, files)
// 		unsafe { files.free() }

// 		// return error if given directory is empty
// 		if filtered_files.len == 0 {
// 			unsafe { filtered_files.free() }
// 			return error('module `$mod` is empty')
// 		}
		
// 		return mod_dir, filtered_files
// 	}

// 	return error('cannot find module `$mod`')
// }

// fn (mut ss Store) resolve_module_path(module_name string, alias string) string {
// 	dir := os.dir(ss.cur_file_path)
// 	file_name := os.base(ss.cur_file_path)
// 	defer { 
// 		unsafe { 
// 			dir.free() 
// 			file_name.free()
// 		} 
// 	}

// 	// check if module_name has already imported
// 	if imports := ss.imports[dir] {
// 		for imp in imports {
// 			if imp.resolved && (imp.module_name == module_name || (file_name in imp.aliases && alias in imp.aliases[file_name])) {
// 				return imp.path
// 			}
// 		}
// 	}

// 	return false
// }

// NOTE: once builder.find_module_path is extracted, simplify parse_imports
// [manualfree]
// fn (mut ss Store) parse_imports(import_ []C.TSTree) {
// 	// NB: b.parsed_files is appended in the loop,
// 	// so we can not use the shorter `for in` form.
// 	for i := 0; i < parsed_files.len; i++ {
// 		// TODO: use URI
		
// 		mut invalid_imports := []string{}
// 		for _, imp in file.imports {
// 			if imp.mod in done_imports {
// 				continue
// 			}
// 			mut found := false
// 			mut import_err_msg := "cannot find module '$imp.mod'"
// 			for path in pref.lookup_path {
// 				mod_dir := os.join_path(path, imp.mod.split('.').join(os.path_separator))
// 				if !os.exists(mod_dir) {
// 					continue
// 				}
// 				mut files := os.ls(mod_dir) or { []string{} }
// 				files = pref.should_compile_filtered_files(mod_dir, files)
// 				if files.len == 0 {
// 					import_err_msg = "module '$imp.mod' is empty"
// 					break
// 				}
// 				found = true
// 				mut tmp_new_parsed_files := parser.parse_files(files, table, pref, scope)
// 				tmp_new_parsed_files = tmp_new_parsed_files.filter(it.mod.name !in done_imports)
// 				mut clean_new_files_names := []string{}
// 				for index, new_file in tmp_new_parsed_files {
// 					if new_file.mod.name !in clean_new_files_names {
// 						newly_parsed_files << tmp_new_parsed_files[index]
// 						clean_new_files_names << new_file.mod.name
// 					}
// 				}
// 				newly_parsed_files2, errs2 := ls.parse_imports(newly_parsed_files, table,
// 					pref, scope)
// 				errs << errs2
// 				newly_parsed_files << newly_parsed_files2
// 				done_imports << imp.mod
// 				unsafe {
// 					newly_parsed_files2.free()
// 					errs2.free()
// 				}
// 				break
// 			}
// 			if !found {
// 				errs << errors.Error{
// 					message: import_err_msg
// 					file_path: file.path
// 					pos: imp.pos
// 					reporter: .checker
// 				}
// 				if imp.mod !in invalid_imports {
// 					invalid_imports << imp.mod
// 				}
// 				continue
// 			}
// 		}
// 		ls.invalid_imports[file_uri] = invalid_imports.clone()
// 		unsafe {
// 			invalid_imports.free()
// 			file_uri.free()
// 		}
// 	}
// 	unsafe { done_imports.free() }
// 	return newly_parsed_files, errs
// }
