module vls

import json
import lsp
import v.parser
import v.table
import v.pref
import v.ast
import v.checker
import os

const (
	vroot = os.dir(@VEXE)
	vlib_path = os.join_path(vroot, 'vlib')
	vmodules_path = os.join_path(os.home_dir(), '.vmodules')
	builtin_path = os.join_path(vlib_path, 'builtin')
)

fn (mut ls Vls) did_open(id int, params string) {
	did_open_params := json.decode(lsp.DidOpenTextDocumentParams, params) or { panic(err) }
	source := did_open_params.text_document.text
	ls.show_diagnostics(source, did_open_params.text_document.uri)
}

fn (mut ls Vls) did_change(id int, params string) {
	did_change_params := json.decode(lsp.DidChangeTextDocumentParams, params) or { panic(err) }
	source := did_change_params.content_changes[0].text
	ls.show_diagnostics(source, did_change_params.text_document.uri)
}

fn (mut ls Vls) show_diagnostics(source string, uri lsp.DocumentUri) {
	file_path := uri.path()
	target_dir := os.dir(file_path)
	// ls.log_message(target_dir, .info)
	scope := ast.Scope{
		parent: 0
	}
	pref := pref.Preferences{
		output_mode: .silent
		backend: .c
		os: ._auto
		lookup_path: [
			target_dir,
			os.dir(target_dir), //parent hack
			os.join_path(target_dir, 'modules'),
			vlib_path,
			vmodules_path
		]
	}
	table := ls.new_table()

	if file_path in ls.sources {
		ls.sources.delete(file_path)
	}

	if file_path in ls.files {
		ls.files.delete(file_path)
	}	

	if target_dir in ls.tables {
		ls.tables.delete(target_dir)
	}	

	mut parsed_file := parser.parse_text(source, file_path, table, .skip_comments, &pref, &scope)
	if parsed_file.errors.len == 0 {
		mut checker := checker.new_checker(table, &pref)
		checker.check(parsed_file)
		ls.extract_symbols([parsed_file], table)
		ls.parse_imports([parsed_file], table, &pref, &scope)
	}

	mut diagnostics := []lsp.Diagnostic{}
	for _, error in parsed_file.errors {
		diagnostics << lsp.Diagnostic{
			range: position_to_lsp_range(source, error.pos)
			severity: .error
			message: error.message
		}
	}

	for _, warning in parsed_file.warnings {
		diagnostics << lsp.Diagnostic{
			range: position_to_lsp_range(source, warning.pos)
			severity: .warning
			message: warning.message
		}
	}

	ls.sources[file_path] = source
	ls.files[parsed_file.path] = parsed_file
	ls.tables[target_dir] = table
	ls.publish_diagnostics(uri, diagnostics)

	unsafe {
		parsed_file.stmts.free()
		parsed_file.errors.free()
		parsed_file.warnings.free()
		diagnostics.free()
		source.free()
	}
}

fn (mut ls Vls) extract_symbols(parsed_files []ast.File, table &table.Table) {
	for file in parsed_files {
		for stmt in file.stmts {
			mut name := ''
			match stmt {
				ast.InterfaceDecl,
				ast.StructDecl,
				ast.EnumDecl {
					name = stmt.name
				}
				ast.FnDecl {
					name = stmt.name
					
					if stmt.is_method {
						rec_name := table.type_to_str(stmt.receiver.typ)
						name = rec_name + '.' + name
					}
				}
				else { continue }
			}
			ls.symbols[name] = &stmt
		}
	}
}

fn (mut ls Vls) insert_files(files []ast.File) int {
	mut inserted := 0
	for file in files {
		ls.files[file.path] = file
		inserted++
	}
	return inserted
}

fn (mut ls Vls) parse_imports(parsed_files []ast.File, table &table.Table, pref &pref.Preferences, scope &ast.Scope) {
	mut done_imports := parsed_files.map(it.mod.name)

	// NB: b.parsed_files is appended in the loop,
	// so we can not use the shorter `for in` form.
	for i := 0; i < parsed_files.len; i++ {
		file := parsed_files[i]
		for _, imp in file.imports {
			if imp.mod in done_imports {
				continue
			}
			mut found := false
			for path in pref.lookup_path {
				mod_dir := os.join_path(path, imp.mod.split('.').join(os.path_separator))
				if !os.exists(mod_dir) {
					continue
				}
				mut files := os.ls(mod_dir) or { []string{} }
				files = pref.should_compile_filtered_files(mod_dir, files)
				newly_parsed_files := parser.parse_files(files, table, pref, scope)
				ls.insert_files(newly_parsed_files)
				ls.parse_imports(newly_parsed_files, table, pref, scope)
				done_imports << imp.mod
				found = true
				unsafe { newly_parsed_files.free() }
				break
			}
			if !found {
				panic('cannot find module $imp.mod')
			}
		}
	}
	unsafe {
		done_imports.free()
	}
}

fn (ls Vls) new_table() &table.Table {
	mut tbl := table.new_table()
	tbl.types = ls.base_table.types.clone()
	tbl.type_idxs = ls.base_table.type_idxs.clone()
	tbl.fns = ls.base_table.fns.clone()
	tbl.imports = ls.base_table.imports.clone()
	tbl.modules = ls.base_table.modules.clone()
	tbl.cflags = ls.base_table.cflags.clone()
	tbl.redefined_fns = ls.base_table.redefined_fns.clone()
	tbl.fn_gen_types = ls.base_table.fn_gen_types.clone()
	tbl.cmod_prefix = ls.base_table.cmod_prefix
	tbl.is_fmt = ls.base_table.is_fmt
	return tbl
}
