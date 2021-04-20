module vls

import json
import lsp
import v.parser
import v.pref
import v.ast
import v.errors
import v.checker
import os

const (
	vroot         = os.dir(@VEXE)
	vlib_path     = os.join_path(vroot, 'vlib')
	vmodules_path = os.join_path(os.home_dir(), '.vmodules')
	builtin_path  = os.join_path(vlib_path, 'builtin')
)

fn (mut ls Vls) did_open(_ int, params string) {
	did_open_params := json.decode(lsp.DidOpenTextDocumentParams, params) or { 
		ls.panic(err.msg)
		return
	}
	source := did_open_params.text_document.text
	uri := did_open_params.text_document.uri
	ls.process_file(source, uri)
}

[manualfree]
fn (mut ls Vls) did_change(_ int, params string) {
	did_change_params := json.decode(lsp.DidChangeTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}
	source := did_change_params.content_changes[0].text
	uri := did_change_params.text_document.uri
	unsafe { ls.sources[uri.str()].free() }
	ls.process_file(source, uri)
}

fn (mut ls Vls) did_close(_ int, params string) {
	did_close_params := json.decode(lsp.DidCloseTextDocumentParams, params) or { 
		ls.panic(err.msg) 
		return
	}
	uri := did_close_params.text_document.uri
	file_dir := uri.dir()
	mut no_active_files := true
	ls.sources.delete(uri.str())
	ls.files.delete(uri.str())
	for f_uri, _ in ls.files {
		if f_uri.starts_with(file_dir) {
			no_active_files = false
			break
		}
	}
	if no_active_files {
		ls.free_table(file_dir, did_close_params.text_document.uri)
	}
	// NB: The diagnostics will be cleared if:
	// - TODO: If a workspace has opened multiple programs with main() function and one of them is closed.
	// - If a file opened is outside the root path or workspace.
	// - If there are no remaining files opened on a specific folder.
	if no_active_files || !uri.starts_with(ls.root_uri) {
		// clear diagnostics
		ls.publish_diagnostics(uri, []lsp.Diagnostic{})
	}
}

// TODO: edits must use []lsp.TextEdit instead of string
[manualfree]
fn (mut ls Vls) process_file(source string, uri lsp.DocumentUri) {
	ls.sources[uri.str()] = source.bytes()
	file_path := uri.path()
	target_dir := os.dir(file_path)
	target_dir_uri := uri.dir()
	// ls.log_message(target_dir, .info)
	scope, mut pref := new_scope_and_pref(target_dir, os.dir(target_dir), os.join_path(target_dir,
		'modules'), ls.root_uri.path())
	pref.is_test = file_path.ends_with('_test.v') || file_path.ends_with('_test.vv')
		|| file_path.all_before_last('.v').all_before_last('.').ends_with('_test')
	pref.is_vsh = file_path.ends_with('.vsh')
	pref.is_script = pref.is_vsh || file_path.ends_with('.v') || file_path.ends_with('.vv')

	ls.free_table(target_dir_uri, file_path)
	table := ls.new_table()
	mut parsed_files := []ast.File{}
	mut checker := checker.new_checker(table, pref)
	mod_dir := os.dir(file_path)
	cur_mod_files := os.ls(mod_dir) or { [] }
	other_files := pref.should_compile_filtered_files(mod_dir, cur_mod_files).filter(it != file_path)
	parsed_files << parser.parse_files(other_files, table, pref, scope)
	parsed_files << parser.parse_text(source, file_path, table, .skip_comments, pref,
		scope)
	imported_files, import_errors := ls.parse_imports(parsed_files, table, pref, scope)
	checker.check_files(parsed_files)
	ls.tables[target_dir_uri] = table
	ls.insert_files(parsed_files)
	for err in import_errors {
		err_file_uri := lsp.document_uri_from_path(err.file_path).str()
		ls.files[err_file_uri].errors << err
		unsafe { err_file_uri.free() }
	}
	ls.show_diagnostics(uri)
	unsafe {
		imported_files.free()
		import_errors.free()
		parsed_files.free()
		source.free()
	}
}

// NOTE: once builder.find_module_path is extracted, simplify parse_imports
[manualfree]
fn (mut ls Vls) parse_imports(parsed_files []ast.File, table &ast.Table, pref &pref.Preferences, scope &ast.Scope) ([]ast.File, []errors.Error) {
	mut newly_parsed_files := []ast.File{}
	mut errs := []errors.Error{}
	mut done_imports := parsed_files.map(it.mod.name)
	// NB: b.parsed_files is appended in the loop,
	// so we can not use the shorter `for in` form.
	for i := 0; i < parsed_files.len; i++ {
		file := parsed_files[i]
		file_uri := lsp.document_uri_from_path(file.path).str()
		if file_uri in ls.invalid_imports {
			unsafe { ls.invalid_imports[file_uri].free() }
		}
		mut invalid_imports := []string{}
		for _, imp in file.imports {
			if imp.mod in done_imports {
				continue
			}
			mut found := false
			mut import_err_msg := "cannot find module '$imp.mod'"
			for path in pref.lookup_path {
				mod_dir := os.join_path(path, imp.mod.split('.').join(os.path_separator))
				if !os.exists(mod_dir) {
					continue
				}
				mut files := os.ls(mod_dir) or { []string{} }
				files = pref.should_compile_filtered_files(mod_dir, files)
				if files.len == 0 {
					import_err_msg = "module '$imp.mod' is empty"
					break
				}
				found = true
				mut tmp_new_parsed_files := parser.parse_files(files, table, pref, scope)
				tmp_new_parsed_files = tmp_new_parsed_files.filter(it.mod.name !in done_imports)
				mut clean_new_files_names := []string{}
				for index, new_file in tmp_new_parsed_files {
					if new_file.mod.name !in clean_new_files_names {
						newly_parsed_files << tmp_new_parsed_files[index]
						clean_new_files_names << new_file.mod.name
					}
				}
				newly_parsed_files2, errs2 := ls.parse_imports(newly_parsed_files, table,
					pref, scope)
				errs << errs2
				newly_parsed_files << newly_parsed_files2
				done_imports << imp.mod
				unsafe {
					newly_parsed_files2.free()
					errs2.free()
				}
				break
			}
			if !found {
				errs << errors.Error{
					message: import_err_msg
					file_path: file.path
					pos: imp.pos
					reporter: .checker
				}
				if imp.mod !in invalid_imports {
					invalid_imports << imp.mod
				}
				continue
			}
		}
		ls.invalid_imports[file_uri] = invalid_imports.clone()
		unsafe {
			invalid_imports.free()
			file_uri.free()
		}
	}
	unsafe { done_imports.free() }
	return newly_parsed_files, errs
}
