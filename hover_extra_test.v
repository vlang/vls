// Copyright (c) 2025 Alexander Medvedev. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json2

// What a hover shows when the symbol index alone answers it: the members of a
// struct or an enum, the value a declaration carries, and a link to a declaration
// in another file of the project. Every case here is answered without a compiler
// and without reading a file the hover does not already read, and each refusal is
// asserted to be exactly what the hover showed before.

fn hx_app() &App {
	temp_dir := os.join_path(os.temp_dir(), 'vls_hx_${os.getpid()}')
	os.mkdir_all(temp_dir) or {
		assert false, 'hx_app: cannot create ${temp_dir}: ${err}'
		return &App{
			open_files: map[string]string{}
			temp_dir:   temp_dir
		}
	}
	return &App{
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
}

// hx_project writes `files` into a project named `name`, opens them all and
// returns the uri of each.
fn hx_project(files map[string]string, name string, mut app App) map[string]string {
	root := os.join_path(app.temp_dir, name)
	os.mkdir_all(root) or {
		assert false, 'hx_project: cannot create ${root}: ${err}'
	}
	os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or {
		assert false, 'hx_project: cannot write v.mod in ${root}: ${err}'
	}
	mut uris := map[string]string{}
	for file, content in files {
		path := os.join_path(root, file)
		os.mkdir_all(os.dir(path)) or {
			assert false, 'hx_project: cannot create the directory of ${path}: ${err}'
		}
		os.write_file(path, content) or {
			assert false, 'hx_project: cannot write ${path}: ${err}'
		}
		uri := path_to_uri(path)
		app.open_files[uri] = content
		app.reindex_uri(uri)
		uris[file] = uri
	}
	app.workspace_roots = [root]
	return uris
}

// hx_pos_of is the position of `word` on the line of `content` that contains
// `line_text`.
fn hx_pos_of(content string, line_text string, word string) Position {
	for i, line in content.split_into_lines() {
		if line.contains(line_text) {
			col := line.index(word) or { continue }
			return Position{
				line: i
				char: col + 1
			}
		}
	}
	assert false, 'hx_pos_of: ${word} is not on a line containing ${line_text}'
	return Position{}
}

// hx_value is what a hover shows, or 'null' when there is no hover.
fn hx_value(hover ?Hover) string {
	if h := hover {
		return h.contents.value
	}
	return 'null'
}

// hx_declaration_hover asks the hover the index alone answers, at the `word` of
// the line that contains `line_text`.
fn hx_declaration_hover(mut app App, uri string, content string, line_text string, word string) string {
	return hx_value(app.source_hover_fallback(uri, hx_pos_of(content, line_text, word)))
}

// hx_hover asks a hover through the request handler, at the `word` of the line
// of `uri`'s content that contains `line_text`, and returns what it shows.
fn hx_hover(mut app App, uri string, line_text string, word string) string {
	content := app.open_files[uri] or { '' }
	app.text = content
	response := app.operation_at_pos(.hover, Request{
		id:     9721
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      hx_pos_of(content, line_text, word)
		},
			escape_unicode: true
		)
	})
	if response.result is Hover {
		return (response.result as Hover).contents.value
	}
	if response.result is string {
		return response.result as string
	}
	return response.result.str()
}

// hx_declaration_at builds the location of the name `word` on the `line_text`
// line of `uri`'s content, the way the index resolves one.
fn hx_declaration_at(uri string, content string, line_text string, word string) Location {
	position := hx_pos_of(content, line_text, word)
	line := content.split_into_lines()[position.line]
	col := line.index(word) or { -1 }
	assert col >= 0, 'hx_declaration_at: ${word} is not in ${line_text}'
	return Location{
		uri:   uri
		range: LSPRange{
			start: Position{
				line: position.line
				char: col
			}
			end:   Position{
				line: position.line
				char: col + word.len
			}
		}
	}
}

const hx_members_main = "module main\n\nconst max_size = 100\n\nenum Color {\n\tred\t= 0xff0000\n\tgreen\n\tblue = (1 << 2)\n}\n\nstruct User {\n\tname string\n\tage  int\n}\n\nfn main() {\n\tu := User{ name: 'a', age: 3 }\n\tc := Color.blue\n\td := Color.green\n\te := Color.red\n\tprintln(u.name)\n\tprintln(c)\n\tprintln(d)\n\tprintln(e)\n\tprintln(max_size)\n}\n"

fn test_hx_struct_hover_lists_its_fields() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	uris := hx_project({
		'main.v': hx_members_main
	}, 'hx_struct', mut app)
	uri := uris['main.v'] or { '' }
	assert uri != '', 'hx_struct_hover_lists_its_fields: no uri for main.v'
	want := '```v\nstruct User {\n\tname string\n\tage int\n}\n```'
	// Where the type is used, and where it is declared.
	assert hx_declaration_hover(mut app, uri, hx_members_main, 'u := User{ name', 'User') == want, 'hx_struct_hover_lists_its_fields: use site'
	assert hx_declaration_hover(mut app, uri, hx_members_main, 'struct User {', 'User') == want, 'hx_struct_hover_lists_its_fields: declaration site'
}

fn test_hx_enum_hover_lists_its_variants() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	uris := hx_project({
		'main.v': hx_members_main
	}, 'hx_enum', mut app)
	uri := uris['main.v'] or { '' }
	assert uri != '', 'hx_enum_hover_lists_its_variants: no uri for main.v'
	got := hx_declaration_hover(mut app, uri, hx_members_main, 'c := Color.blue', 'Color')
	assert got == '```v\nenum Color {\n\tred\n\tgreen\n\tblue\n}\n```', got
}

fn test_hx_member_list_is_capped_at_twenty() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	mut fields := []string{}
	for i in 0 .. 23 {
		fields << '\tf${i} int'
	}
	content := 'module main\n\nstruct Wide {\n${fields.join('\n')}\n}\n\nfn main() {\n\tw := Wide{}\n\tprintln(w.f0)\n}\n'
	uris := hx_project({
		'main.v': content
	}, 'hx_cap', mut app)
	uri := uris['main.v'] or { '' }
	assert uri != '', 'hx_member_list_is_capped_at_twenty: no uri for main.v'
	got := hx_declaration_hover(mut app, uri, content, 'w := Wide{}', 'Wide')
	assert got.contains('// ... 3 more'), 'hx_member_list_is_capped_at_twenty: no tail\n${got}'
	assert got.ends_with('f19 int\n\t// ... 3 more\n}\n```'), 'hx_member_list_is_capped_at_twenty: tail\n${got}'
	assert !got.contains('f20 int'), 'hx_member_list_is_capped_at_twenty: f20 listed\n${got}'
	assert got.split_into_lines().len == 25, 'hx_member_list_is_capped_at_twenty: ${got.split_into_lines().len} lines'
}

fn test_hx_const_hover_shows_its_value() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	uris := hx_project({
		'main.v': hx_members_main
	}, 'hx_const', mut app)
	uri := uris['main.v'] or { '' }
	assert uri != '', 'hx_const_hover_shows_its_value: no uri for main.v'
	want := '```v\nconst max_size = 100\n```'
	// Where the name is used, and where it is declared.
	assert hx_declaration_hover(mut app, uri, hx_members_main, 'println(max_size)', 'max_size') == want, 'hx_const_hover_shows_its_value: use site'
	assert hx_declaration_hover(mut app, uri, hx_members_main, 'const max_size', 'max_size') == want, 'hx_const_hover_shows_its_value: declaration site'
}

fn test_hx_enum_variant_hover_shows_its_value() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	uris := hx_project({
		'main.v': hx_members_main
	}, 'hx_variant', mut app)
	uri := uris['main.v'] or { '' }
	assert uri != '', 'hx_enum_variant_hover_shows_its_value: no uri for main.v'
	// A value written between parentheses, as an enum variant writes one.
	parenthesised := hx_value(app.member_selector_hover(uri, hx_pos_of(hx_members_main,
		'c := Color.blue', 'blue')))
	assert parenthesised == '```v\nColor.blue = (1 << 2)\n```', 'hx_enum_variant_hover_shows_its_value: ${parenthesised}'
	// A variant that declares no value is left to the answer there was before.
	valueless := hx_value(app.member_selector_hover(uri, hx_pos_of(hx_members_main,
		'd := Color.green', 'green')))
	assert valueless == 'null', 'hx_enum_variant_hover_shows_its_value: valueless is ${valueless}'
	// A value written as a bare literal, the way a constant carries one.
	literal := hx_value(app.member_selector_hover(uri, hx_pos_of(hx_members_main,
		'e := Color.red', 'red')))
	assert literal == '```v\nColor.red = 0xff0000\n```', 'hx_enum_variant_hover_shows_its_value: literal is ${literal}'
}

const hx_link_main = 'module main\n\nfn main() {\n\tprintln(area(2))\n}\n'

const hx_link_lib = 'module main\n\n// area returns the square of a side.\npub fn area(side int) int {\n\treturn side * side\n}\n'

fn test_hx_cross_file_function_hover_links_the_file() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	uris := hx_project({
		'main.v': hx_link_main
		'area.v': hx_link_lib
	}, 'hx_link', mut app)
	main_uri := uris['main.v'] or { '' }
	lib_uri := uris['area.v'] or { '' }
	assert main_uri != '', 'hx_cross_file_function_hover_links_the_file: no uri for main.v'
	assert lib_uri != '', 'hx_cross_file_function_hover_links_the_file: no uri for area.v'
	app.line_info_mode = .missing
	// Asked from main.v, the declaration is in area.v: the link is its path
	// relative to the project root.
	got := hx_hover(mut app, main_uri, 'println(area(2))', 'area')
	assert got == '```v\npub fn area(side int) int\n```\n\narea returns the square of a side.\n\n[area.v](area.v)', 'hx_cross_file_function_hover_links_the_file: ${got}'
	// The declaration of it, in its own file, links to nothing.
	own := hx_hover(mut app, lib_uri, 'pub fn area(side int) int {', 'area')
	assert own == '```v\npub fn area(side int) int\n```\n\narea returns the square of a side.', 'hx_cross_file_function_hover_links_the_file: own file is ${own}'
	// A file in a subdirectory of the project keeps its path to the root.
	nested_src := 'module main\n\n// deep is declared here.\npub fn deep() {}\n'
	nested_path := os.join_path(app.temp_dir, 'hx_link', 'nested', 'deep.v')
	os.mkdir_all(os.dir(nested_path)) or {
		assert false, 'hx_cross_file: cannot create ${os.dir(nested_path)}: ${err}'
	}
	os.write_file(nested_path, nested_src) or {
		assert false, 'hx_cross_file: cannot write ${nested_path}: ${err}'
	}
	nested_uri := path_to_uri(nested_path)
	app.open_files[nested_uri] = nested_src
	app.reindex_uri(nested_uri)
	nested := hx_value(app.function_declaration_hover(main_uri, hx_declaration_at(nested_uri,
		nested_src, 'pub fn deep() {}', 'deep')))
	assert nested.ends_with('\n\n[nested/deep.v](nested/deep.v)'), 'hx_cross_file: nested is ${nested}'
}

fn test_hx_module_const_hover_shows_the_value() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	// A module of the project with a constant, and a file that uses it
	// qualified without importing it: the module resolves the way an import
	// would, and the value is the one the declaration states.
	shapes := 'module shapes\n\npub const max_size = 8\n\npub const label = \'"box"\'\n'
	main_src := 'module main\n\nfn build() {\n\tsize := shapes.max_size\n\tprintln(size)\n}\n'
	uris := hx_project({
		'main.v':          main_src
		'shapes/shapes.v': shapes
	}, 'hx_modconst', mut app)
	uri := uris['main.v'] or { '' }
	assert uri != '', 'hx_modconst: no uri for main.v'
	hovered := hx_hover_on(mut app, uri, main_src, 'size := shapes.max_size', 'max_size')
	assert hovered == '```v\nshapes.max_size = 8\n```', 'hx_modconst: int is ${hovered}'
	// A string constant shows its quotes, as the declaration writes them.
	label_main := 'module main\n\nfn build() {\n\tprintln(shapes.label)\n}\n'
	app.open_files[uri] = label_main
	app.reindex_uri(uri)
	text := hx_hover_on(mut app, uri, label_main, 'println(shapes.label)', 'label')
	assert text == '```v\nshapes.label = \'"box"\'\n```', 'hx_modconst: string is ${text}'
}

fn test_hx_module_const_hover_refuses_a_local_named_like_the_module() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	// A local bound to a folder's name is not that module, so nothing is
	// answered for `shapes.max_size` while `shapes` is a local.
	shapes := 'module shapes\n\npub const max_size = 8\n'
	main_src := 'module main\n\nfn build() {\n\tshapes := 1\n\tprintln(shapes.max_size)\n}\n'
	uris := hx_project({
		'main.v':          main_src
		'shapes/shapes.v': shapes
	}, 'hx_modlocal', mut app)
	uri := uris['main.v'] or { '' }
	assert uri != '', 'hx_modlocal: no uri for main.v'
	hovered := hx_hover_on(mut app, uri, main_src, 'println(shapes.max_size)', 'max_size')
	assert hovered == 'null', 'hx_modlocal: a local answered ${hovered}'
}

// hx_hover_on answers the selector hover for `word` on the line that reads
// `line_text`, as the request handler reaches it.
fn hx_hover_on(mut app App, uri string, content string, line_text string, word string) string {
	position := hx_pos_of(content, line_text, word)
	return hx_value(app.member_selector_hover(uri, position))
}

fn test_hx_hover_refuses_what_the_index_does_not_know() {
	mut app := hx_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	// An enum written on one line, and a struct with no field: the index names no
	// member of either, so the hover stays the declaration alone.
	content := 'module main\n\nenum Flags { a b c }\n\nstruct Empty {}\n\nfn main() {\n\tc := 1\n\tprintln(Flags.a)\n\tprintln(c)\n}\n'
	uris := hx_project({
		'main.v': content
	}, 'hx_refuse', mut app)
	uri := uris['main.v'] or { '' }
	assert uri != '', 'hx_hover_refuses: no uri for main.v'
	assert hx_declaration_hover(mut app, uri, content, 'println(Flags.a)', 'Flags') == '```v\nenum Flags\n```', 'hx_hover_refuses: one-line enum'
	assert hx_declaration_hover(mut app, uri, content, 'struct Empty {}', 'Empty') == '```v\nstruct Empty\n```', 'hx_hover_refuses: empty struct'
	// A name that declares nothing the index resolves: no hover at all.
	local := hx_value(app.source_hover_fallback(uri, hx_pos_of(content, 'println(c)', 'c')))
	assert local == 'null', 'hx_hover_refuses: a local shows ${local}'
	// A declaration in a file that shares no project root links to nothing.
	rootless := 'module rootless\n\n// alone is declared here.\npub fn alone() {}\n'
	rootless_path := os.join_path(app.temp_dir, 'hx_rootless', 'alone.v')
	os.mkdir_all(os.dir(rootless_path)) or {
		assert false, 'hx_hover_refuses: cannot create ${os.dir(rootless_path)}: ${err}'
	}
	os.write_file(rootless_path, rootless) or {
		assert false, 'hx_hover_refuses: cannot write ${rootless_path}: ${err}'
	}
	rootless_uri := path_to_uri(rootless_path)
	app.open_files[rootless_uri] = rootless
	app.reindex_uri(rootless_uri)
	linked := hx_value(app.function_declaration_hover(uri, hx_declaration_at(rootless_uri,
		rootless, 'pub fn alone() {}', 'alone')))
	assert linked == '```v\npub fn alone()\n```\n\nalone is declared here.', 'hx_hover_refuses: rootless is ${linked}'
}
