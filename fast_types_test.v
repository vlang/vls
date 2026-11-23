module main

import os
import time

fn test_fast_type_uses_find_bare_arguments_without_guessing_at_bindings() {
	content := "module main\nfn f(value int) {\n\tf(value, missing, 'text', os.good, nested(call))\n}\n"
	uses := fast_type_uses(content, content.split('\n'), v_source_code_mask(content).bytestr().split('\n'))
	assert uses == [FastValueUse{ name: 'missing', line: 2, col: 10 }]
}

fn test_fast_return_types_only_checks_explicit_scalar_returns() {
	content := "module main\nfn number() int {\n\treturn 'wrong' // detail\n}\nfn pick() bool {\n\treturn true\n}\nfn compare() bool {\n\treturn 0x1==0x1\n}\nfn nested() int {\n\tf := fn () string {\n\t\treturn 'ok'\n\t}\n\treturn f().len\n}\n"
	errors := fast_return_types('/source.v', content.split('\n'),
		v_source_code_mask(content).bytestr().split('\n'))
	assert errors.len == 1
	assert errors[0].line_nr == 3
	assert errors[0].col == 9
	assert errors[0].len == 7
	assert errors[0].message == 'cannot return `string` from a function returning `int`'
}

fn test_fast_unknown_names_respect_disk_and_unsaved_module_sources() {
	dir := make_unique_temp_path('vls_fast_types', '/main.v')
	os.mkdir_all(dir) or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	uri := path_to_uri(os.join_path(dir, 'main.v'))
	os.write_file(os.join_path(dir, 'other.v'), 'module main\nconst disk_value = 1\n') or { panic(err) }
	content := 'module main\nfn main() {\n\taccept(disk_value, buffer_value, nonexistent_argument)\n}\n'
	app := &App{
		open_files: {
			uri:                                         content
			path_to_uri(os.join_path(dir, 'unsaved.v')): 'module main\nconst buffer_value = 1\n'
		}
	}
	mut scheduler := new_diagnostics_scheduler()
	// Hold the known builtin inputs so this test checks module scope independently.
	scheduler.fast_type_builtin = FastTypeBuiltin{
		dir:     os.join_path(find_v_dir(), 'vlib', 'builtin')
		read_at: time.now().unix_milli()
		names:   {
			'accept': true
		}
	}
	errors := app.fast_type_errors(uri, content, mut scheduler)
	assert errors.len == 1
	assert errors[0].message.contains('nonexistent_argument')
	assert app.fast_type_errors(uri, content.replace('fn main()', '$if linux {\nfn main()'),
		mut scheduler).len == 0
}

fn test_builtin_names_indexed_as_whole_identifiers() {
	mut names := map[string]bool{}
	record_fast_builtin_names('pub fn long_builtin(a1 string) {} // other', mut names)
	assert 'long_builtin' in names
	assert 'a1' in names
	assert 'other' in names
	assert 'builtin' !in names
}

fn test_scope_with_manifest_subdirs_defers_module_name_resolution() {
	dir := make_unique_temp_path('vls_fast_types_subdirs', '/main.v')
	os.mkdir_all(dir) or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	os.write_file(os.join_path(dir, 'v.mod'), "Module { name: 'test', subdirs: ['parts'] }") or {
		panic(err)
	}
	app := &App{}
	assert app.fast_type_sibling_sources(path_to_uri(os.join_path(dir, 'main.v'))) == none
}
