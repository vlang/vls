// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os

// Tests for the "Move declaration to a new file" quick fix. Every `_test.v`
// file of this project shares module main, so the helpers here carry the etf_
// prefix.

// EtfRefactor is everything the refactor produces for one selection: the edits
// written into the original file, the file it creates, the text written to it,
// and the document the original file ends up as.
struct EtfRefactor {
	edits    []TextEdit
	new_uri  string
	new_text string
	applied  string
}

// etf_dir returns the project directory a `tag` writes its files in.
fn etf_dir(tag string) string {
	return os.join_path(os.temp_dir(), 'vls_etf_${tag}_${os.getpid()}')
}

// etf_mkdir creates `path` afresh, so a test that runs again does not see the
// files the last run left in it.
fn etf_mkdir(path string) {
	os.rmdir_all(path) or {}
	os.mkdir_all(path) or {
		assert false, 'etf: mkdir failed for ${path}: ${err}'
		return
	}
}

// etf_write writes `content` to `path`.
fn etf_write(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'etf: write failed for ${path}: ${err}'
		return
	}
}

// etf_uri converts a path to the uri a client opens it by.
fn etf_uri(path string) string {
	return path_to_uri(path)
}

// etf_app opens `content` as `service.v` in a project directory of its own —
// a `v.mod` beside it, which is what makes that directory part of one — and
// returns the App an editor has on it with the file's uri.
fn etf_app(tag string, content string) (&App, string) {
	dir := etf_dir(tag)
	etf_mkdir(dir)
	etf_write(os.join_path(dir, 'v.mod'), 'Module: app\n')
	path := os.join_path(dir, 'service.v')
	etf_write(path, content)
	uri := etf_uri(path)
	return &App{
		open_files: {
			uri: content
		}
		temp_dir:   dir
	}, uri
}

// etf_app_plain opens `content` in a directory with no `v.mod` above it, which
// is a file outside any project.
fn etf_app_plain(tag string, content string) (&App, string) {
	dir := etf_dir(tag)
	etf_mkdir(dir)
	path := os.join_path(dir, 'service.v')
	etf_write(path, content)
	uri := etf_uri(path)
	return &App{
		open_files: {
			uri: content
		}
		temp_dir:   dir
	}, uri
}

// etf_extra writes a file beside the one under test, which the collision tests
// fill the module's file name with. It runs after etf_app, so it does not
// recreate the directory.
fn etf_extra(tag string, name string, content string) {
	etf_write(os.join_path(etf_dir(tag), name), content)
}

// etf_range returns the range covering the whole lines [from, to], what an
// editor reports for a selection dragged over them.
fn etf_range(content string, from int, to int) LSPRange {
	lines := content.split_into_lines()
	mut last := 0
	for idx in 0 .. to + 1 {
		if idx < lines.len {
			last = lines[idx].len
		}
	}
	return LSPRange{
		start: Position{
			line: from
			char: 0
		}
		end:   Position{
			line: to
			char: last
		}
	}
}

// etf_original returns the edits the refactor writes into the original file.
fn etf_original(action CodeAction, uri string) []TextEdit {
	edit := action.edit or {
		assert false, 'etf: the action must carry a WorkspaceEdit'
		return []TextEdit{}
	}
	return edit.changes[uri] or {
		assert false, 'etf: the action must edit the original file'
		return []TextEdit{}
	}
}

// etf_created returns the uri and the text of the file the refactor creates.
fn etf_created(action CodeAction) (string, string) {
	edit := action.edit or {
		assert false, 'etf: the action must carry a WorkspaceEdit'
		return '', ''
	}
	changes := edit.document_changes or {
		assert false, 'etf: the new file must be created through documentChanges'
		return '', ''
	}
	assert changes.len == 1, 'etf: exactly one file is created, not ${changes.len}'
	assert changes[0].edits.len == 1, 'etf: one edit writes the whole new file, not ${changes[0].edits.len}'
	assert changes[0].edits[0].range.start == changes[0].edits[0].range.end, 'etf: the whole file is inserted at its start'
	return changes[0].text_document.uri, changes[0].edits[0].new_text
}

// etf_offset maps a position back to a byte offset in `content`.
fn etf_offset(content string, pos Position) int {
	return position_to_byte_offset(content, line_start_offsets(content), pos.line, pos.char,
		PositionEncoding.utf16)
}

// etf_apply applies `edits` to `content`, from the last back, and returns what
// the document holds once a client has taken the quick fix.
fn etf_apply(content string, edits []TextEdit) string {
	mut spans := []EtfSpan{}
	for one in edits {
		spans << EtfSpan{
			start: etf_offset(content, one.range.start)
			end:   etf_offset(content, one.range.end)
			text:  one.new_text
		}
	}
	spans.sort(a.start < b.start)
	mut out := content
	for idx := spans.len - 1; idx >= 0; idx-- {
		span := spans[idx]
		out = out[..span.start] + span.text + out[span.end..]
	}
	return out
}

// EtfSpan is one edit resolved to the byte range it replaces.
struct EtfSpan {
	start int
	end   int
	text  string
}

// etf_refactor returns what the refactor produces for the whole lines [from,
// to] of `content`.
fn etf_refactor(tag string, content string, from int, to int) EtfRefactor {
	mut app, uri := etf_app(tag, content)
	action := app.build_extract_to_file_action(uri, content, etf_range(content, from, to)) or {
		assert false, 'etf: a whole declaration must be offered the refactor'
		return EtfRefactor{}
	}
	edits := etf_original(action, uri)
	etf_created(action)
	new_uri, new_text := etf_created(action)
	return EtfRefactor{
		edits:    edits
		new_uri:  new_uri
		new_text: new_text
		applied:  etf_apply(content, edits)
	}
}

// etf_refused reports whether the refactor is refused for the whole lines
// [from, to] of `content`.
fn etf_refused(tag string, content string, from int, to int) bool {
	mut app, uri := etf_app(tag, content)
	return app.build_extract_to_file_action(uri, content, etf_range(content, from, to)) == none
}

const etf_function_file = "module app\n\nimport os\n\nfn parse_headers(raw string) []string {\n\theaders := raw.split(',')\n\tprintln(headers.len)\n\treturn headers\n}\n\nfn keep() {\n\tparse_headers('')\n}\n"

const etf_struct_file = "module app\n\n@[json: 'id']\nstruct UserService {\n\tname string\n\tport int\n}\n\nfn keep() {\n\tu := UserService{\n\t\tname: 'a'\n\t}\n\tprintln(u.name)\n}\n"

const etf_enum_file = 'module app\n\nenum Colour {\n\tred\n\tgreen\n}\n\nfn keep() {\n\tprintln(Colour.red)\n}\n'

const etf_const_file = "module app\n\nconst (\n\tdefault_port = 8080\n\tdefault_host = 'localhost'\n)\n\nfn keep() {\n\tprintln(default_port)\n}\n"

const etf_type_file = "module app\n\ntype Handler = fn (int) bool\n\nfn keep() {\n\tprintln('x')\n}\n"

const etf_program_file = "module app\n\nfn main() {\n\tprintln('hi')\n}\n"

const etf_module_main_file = 'module main\n\nstruct Point {\n\tx int\n}\n\nfn keep() {\n\tprintln(Point{})\n}\n'

const etf_c_file = 'module app\n\nfn C.print(text &char) {}\n\nfn keep() {}\n'

const etf_flag_file = 'module app\n\n#flag linux -lm\n\nfn keep() {}\n'

const etf_module_named_file = 'module parse_headers\n\nfn parse_headers(raw string) []string {\n\tprintln(raw)\n}\n'

fn test_etf_moves_a_function_into_a_module_of_its_own() {
	content := etf_function_file
	result := etf_refactor('fn_move', content, 4, 8)
	assert result.edits.len == 2, 'etf: two edits rewrite the original file: the delete and the import'
	assert result.edits[0].range == LSPRange{
		start: Position{
			line: 4
			char: 0
		}
		end:   Position{
			line: 9
			char: 0
		}
	}, 'etf: the deleted range runs from the start of the signature line to the start of the line after the closing brace, got ${result.edits[0].range}'
	assert result.edits[0].new_text == '', 'etf: the declaration is deleted, not replaced'
	assert result.edits[1].range == LSPRange{
		start: Position{
			line: 3
			char: 0
		}
		end:   Position{
			line: 3
			char: 0
		}
	}, 'etf: the import goes on the line after the last import, got ${result.edits[1].range}'
	assert result.edits[1].new_text == 'import parse_headers\n', 'etf: the import names the new module, got ${result.edits[1].new_text}'
	assert result.new_uri == etf_uri(os.join_path(etf_dir('fn_move'), 'parse_headers.v')), 'etf: the new file is named after the module, got ${result.new_uri}'
	expected := "module parse_headers\n\nfn parse_headers(raw string) []string {\n\theaders := raw.split(',')\n\tprintln(headers.len)\n\treturn headers\n}\n"
	assert result.new_text == expected, 'etf: the new file carries the module line and the declaration, got ${result.new_text}'
	assert result.applied == "module app\n\nimport os\nimport parse_headers\n\n\nfn keep() {\n\tparse_headers('')\n}\n", 'etf: the original file keeps the rest of its declarations and imports the new module, got ${result.applied}'
}

fn test_etf_moves_a_struct_with_its_attribute_into_a_module_of_its_own() {
	content := etf_struct_file
	result := etf_refactor('struct_move', content, 3, 6)
	assert result.edits[0].range == LSPRange{
		start: Position{
			line: 2
			char: 0
		}
		end:   Position{
			line: 7
			char: 0
		}
	}, 'etf: the attribute above the struct is deleted with it, got ${result.edits[0].range}'
	assert result.new_uri == etf_uri(os.join_path(etf_dir('struct_move'), 'user_service.v')), 'etf: UserService becomes user_service, got ${result.new_uri}'
	expected := "module user_service\n\n@[json: 'id']\nstruct UserService {\n\tname string\n\tport int\n}\n"
	assert result.new_text == expected, 'etf: the attribute moves with the declaration it qualifies, got ${result.new_text}'
	assert result.edits[1].new_text == '\nimport user_service\n', 'etf: the import takes the spot after the module line, got ${result.edits[1].new_text}'
	assert result.applied == "module app\n\nimport user_service\n\n\nfn keep() {\n\tu := UserService{\n\t\tname: 'a'\n\t}\n\tprintln(u.name)\n}\n", 'etf: the original file keeps everything below the declaration, got ${result.applied}'
}

fn test_etf_moves_an_enum_into_a_module_of_its_own() {
	content := etf_enum_file
	result := etf_refactor('enum_move', content, 2, 5)
	assert result.new_uri == etf_uri(os.join_path(etf_dir('enum_move'), 'colour.v')), 'etf: Colour becomes colour, got ${result.new_uri}'
	assert result.new_text == 'module colour\n\nenum Colour {\n\tred\n\tgreen\n}\n', result.new_text
}

fn test_etf_moves_a_const_block_into_a_module_of_its_own() {
	content := etf_const_file
	result := etf_refactor('const_move', content, 2, 5)
	assert result.new_uri == etf_uri(os.join_path(etf_dir('const_move'), 'default_port.v')), 'etf: the block is named after the first name it assigns, got ${result.new_uri}'
	assert result.new_text == "module default_port\n\nconst (\n\tdefault_port = 8080\n\tdefault_host = 'localhost'\n)\n", result.new_text
}

fn test_etf_moves_a_type_alias_into_a_module_of_its_own() {
	content := etf_type_file
	result := etf_refactor('type_move', content, 2, 2)
	assert result.new_uri == etf_uri(os.join_path(etf_dir('type_move'), 'handler.v')), 'etf: Handler becomes handler, got ${result.new_uri}'
	assert result.new_text == 'module handler\n\ntype Handler = fn (int) bool\n', result.new_text
}

fn test_etf_writes_the_new_file_beside_the_name_it_already_has_taken() {
	mut app, uri := etf_app('collision', etf_struct_file)
	etf_extra('collision', 'user_service.v', 'module other\n')
	action := app.build_extract_to_file_action(uri, etf_struct_file, etf_range(etf_struct_file,
		3, 6)) or {
		assert false, 'etf: a taken module name is renamed, not refused'
		return
	}
	new_uri, _ := etf_created(action)
	assert new_uri == etf_uri(os.join_path(etf_dir('collision'), 'user_service_ext.v')), 'etf: the declaration lands in user_service_ext.v, got ${new_uri}'
	assert os.exists(os.join_path(etf_dir('collision'), 'user_service.v')), 'etf: the file that was already there is left alone'
}

fn test_etf_refuses_when_both_module_names_are_taken() {
	mut app, uri := etf_app('taken', etf_struct_file)
	etf_extra('taken', 'user_service.v', 'module other\n')
	etf_extra('taken', 'user_service_ext.v', 'module other\n')
	assert app.build_extract_to_file_action(uri, etf_struct_file, etf_range(etf_struct_file,
		3, 6)) == none, 'etf: no file may be overwritten to make room for the declaration'
}

fn test_etf_refuses_a_selection_that_stops_short_of_the_closing_brace() {
	// The signature line alone: the selection does not reach the body.
	assert etf_refused('short', etf_function_file, 4, 4), 'etf: the declaration is not covered'
}

fn test_etf_refuses_a_selection_that_begins_inside_the_declaration() {
	// A selection starting after the first byte of the signature line covers
	// part of the line the declaration is on.
	mid := LSPRange{
		start: Position{
			line: 4
			char: 2
		}
		end:   Position{
			line: 8
			char: 1
		}
	}
	mut app, uri := etf_app('mid', etf_function_file)
	assert app.build_extract_to_file_action(uri, etf_function_file, mid) == none, 'etf: a declaration covered in part is not a whole one'
}

fn test_etf_refuses_a_selection_of_two_declarations() {
	assert etf_refused('two', etf_function_file, 4, 12), 'etf: two declarations cannot be moved as one'
}

fn test_etf_refuses_an_empty_selection() {
	empty := LSPRange{
		start: Position{
			line: 4
			char: 0
		}
		end:   Position{
			line: 4
			char: 0
		}
	}
	mut app, uri := etf_app('empty', etf_function_file)
	assert app.build_extract_to_file_action(uri, etf_function_file, empty) == none, 'etf: a cursor selects no declaration'
}

fn test_etf_refuses_a_statement_inside_a_body() {
	// The lines of `keep` below its own declaration: a statement is not a
	// declaration, and the one the indentation belongs to is not covered.
	assert etf_refused('body', etf_function_file, 11, 11), 'etf: a statement inside a function is not a top-level declaration'
}

fn test_etf_refuses_fn_main() {
	assert etf_refused('main_fn', etf_program_file, 2, 4), 'etf: the start of a program is not moved out of it'
}

fn test_etf_refuses_a_file_of_module_main() {
	assert etf_refused('main_module', etf_module_main_file, 2, 4), 'etf: a program file holds no module to move a declaration into'
}

fn test_etf_refuses_a_declaration_written_in_c() {
	assert etf_refused('c_block', etf_c_file, 2, 2), 'etf: a C declaration belongs to the file that declares it'
}

fn test_etf_refuses_a_flag_line() {
	assert etf_refused('flag', etf_flag_file, 2, 2), 'etf: a compiler flag is not a declaration'
}

fn test_etf_refuses_a_file_outside_a_project() {
	mut app, uri := etf_app_plain('loose', etf_function_file)
	assert find_project_root(etf_dir('loose')) == '', 'etf: this fixture must sit outside a project, or it tests nothing'
	assert app.build_extract_to_file_action(uri, etf_function_file, etf_range(etf_function_file,
		4, 8)) == none, 'etf: a file with no v.mod above it is not part of a project'
}

fn test_etf_refuses_a_name_that_is_the_module_the_file_is() {
	assert etf_refused('named', etf_module_named_file, 2, 4), 'etf: the new module must not be the module the file already is'
}
