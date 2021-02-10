module vls

import json
import lsp
import v.parser
import v.table
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

// did_open opens the received file from the client.
fn (mut ls Vls) did_open(_ int, params string) {
	did_open_params := json.decode(lsp.DidOpenTextDocumentParams, params) or { panic(err) }
	source := did_open_params.text_document.text
	uri := did_open_params.text_document.uri
	ls.process_file(source, uri)
}

// did_change receives and processes the changes of the given file.
fn (mut ls Vls) did_change(_ int, params string) {
	did_change_params := json.decode(lsp.DidChangeTextDocumentParams, params) or { panic(err) }
	source := did_change_params.content_changes[0].text
	uri := did_change_params.text_document.uri
	unsafe { ls.sources[uri.str()].free() }
	ls.process_file(source, uri)
}

// did_close deletes the mentioned file and the parent folder's table data if
// none of the files in the said folder are currently opened by the client/editor.
fn (mut ls Vls) did_close(_ int, params string) {
	did_close_params := json.decode(lsp.DidCloseTextDocumentParams, params) or { panic(err) }
	uri := did_close_params.text_document.uri
	file_dir := os.dir(uri)
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
		ls.tables.delete(file_dir)
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

// process_file processes the received source and document URI from the client.
//
// TODO: edits must use []lsp.TextEdit instead of string
fn (mut ls Vls) process_file(source string, uri lsp.DocumentUri) {
	ls.sources[uri.str()] = source.bytes()
	file_path := uri.path()
	target_dir := os.dir(file_path)
	target_dir_uri := os.dir(uri)
	// ls.log_message(target_dir, .info)
	scope, mut pref := new_scope_and_pref(target_dir, os.dir(target_dir), os.join_path(target_dir,
		'modules'), ls.root_uri.path())
	if uri.ends_with('_test.v') {
		pref.is_test = true
	}
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

// parse_imports parses the ast.File's imports and imports the modules.
//
// NOTE: once builder.find_module_path is extracted, simplify parse_imports
fn (mut ls Vls) parse_imports(parsed_files []ast.File, table &table.Table, pref &pref.Preferences, scope &ast.Scope) ([]ast.File, []errors.Error) {
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
				newly_parsed_files << parser.parse_files(files, table, pref, scope)
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
