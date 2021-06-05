module analyzer

// import tree_sitter

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
