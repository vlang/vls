module main

import os

// Tests for the "Add import" quick fix of add_import.v: which name it offers an
// import for, where it writes the line, and the cases it refuses. Every helper
// below is named for these tests, because the files of this module share one
// namespace and a colliding name would break the build.

// aimp_mkdir_all creates `path` and its parents.
fn aimp_mkdir_all(path string) {
	os.mkdir_all(path) or {
		assert false, 'Failed to create directory ${path}: ${err}'
		return
	}
}

// aimp_write_file writes `content` to `path`, creating its directory.
fn aimp_write_file(path string, content string) {
	aimp_mkdir_all(os.dir(path))
	os.write_file(path, content) or {
		assert false, 'Failed to write file ${path}: ${err}'
		return
	}
}

// aimp_app returns an App holding nothing open, with a temporary directory of
// its own for the projects the tests write. The modules a file can import are
// read from disk, so every project is written before it is asked about.
fn aimp_app() &App {
	temp_dir := os.join_path(os.temp_dir(), 'vls_aimp_${os.getpid()}')
	aimp_mkdir_all(temp_dir)
	return &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
}

// aimp_project writes the project of a test below `root`: the buffer at
// `main.v`, and one folder per entry of `modules`, whose source is the file that
// declares the module. It returns the path of the buffer and its document URI.
fn aimp_project(root string, modules map[string]string, main_content string) (string, string) {
	aimp_mkdir_all(root)
	for name, source in modules {
		dir := os.join_path(root, name)
		aimp_mkdir_all(dir)
		aimp_write_file(os.join_path(dir, '${name}.v'), source)
	}
	main_path := os.join_path(root, 'main.v')
	aimp_write_file(main_path, main_content)
	return main_path, path_to_uri(main_path)
}

// aimp_cursor returns the empty range of a cursor on the `nth` occurrence of
// `needle`, counting from zero, which is what an editor reports for a caret.
fn aimp_cursor(content string, needle string, nth int) LSPRange {
	mut seen := 0
	for line, text in content.split_into_lines() {
		mut from := 0
		for {
			col := text.index_after(needle, from) or { break }
			if seen == nth {
				return LSPRange{
					start: Position{
						line: line
						char: col
					}
					end:   Position{
						line: line
						char: col
					}
				}
			}
			seen++
			from = col + needle.len
		}
	}
	assert false, 'the fixture holds no occurrence ${nth} of ${needle}'
	return LSPRange{}
}

// aimp_action returns the action the quick fix offers for the buffer at `uri`
// with the cursor at `sel`, and fails the test when it offers none.
fn aimp_action(mut app App, uri string, content string, sel LSPRange) CodeAction {
	app.open_files[uri] = content
	return app.build_add_import_action(uri, content, sel) or {
		assert false, 'the quick fix must offer an action'
		return CodeAction{}
	}
}

// aimp_refuses reports whether the quick fix offers nothing for the buffer at
// `uri` with the cursor at `sel`.
fn aimp_refuses(mut app App, uri string, content string, sel LSPRange) bool {
	app.open_files[uri] = content
	return app.build_add_import_action(uri, content, sel) == none
}

// aimp_edit returns the single edit the action carries, and fails the test when
// it carries none or more than one: a new import line is one insert.
fn aimp_edit(action CodeAction) TextEdit {
	edits := action.edit or {
		assert false, 'the action must carry an edit'
		return TextEdit{}
	}
	mut all := []TextEdit{}
	for _, uri_edits in edits.changes {
		all << uri_edits
	}
	assert all.len == 1, 'one edit writes one import line'
	return all[0]
}

// aimp_inserted applies the insert of `action` to `content`, which is the buffer
// a client ends up with once the quick fix is taken.
fn aimp_inserted(content string, action CodeAction) string {
	edit := aimp_edit(action)
	assert edit.range.start == edit.range.end, 'an insert is an empty range'
	assert edit.range.start.char == 0, 'an import line starts at column 0'
	starts := line_start_offsets(content)
	at := if edit.range.start.line < starts.len {
		starts[edit.range.start.line]
	} else {
		content.len
	}
	return content[..at] + edit.new_text + content[at..]
}

// The commonest case: a buffer that writes `os.join_path(...)` and has no
// `import os`. The action is offered over the qualifier, and the line goes in
// its own paragraph after the module line.
fn test_add_import_offers_the_module_of_a_qualified_use() {
	mut app := aimp_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	root := os.join_path(app.temp_dir, 'aimp_qualified')
	content := "module main\n\nfn main() {\n\tp := os.join_path('a', 'b')\n\tprintln(p)\n}\n"
	_, uri := aimp_project(root, map[string]string{}, content)
	action := aimp_action(mut app, uri, content, aimp_cursor(content, 'os.', 0))
	assert action.title == 'Add import `os`', 'the title names the module'
	assert action.kind == code_action_kind_quickfix, 'the action is a quick fix'
	edit := aimp_edit(action)
	assert edit.range.start.line == 1, 'the import goes after the module line'
	assert edit.range.start.char == 0, 'the import line starts at column 0'
	assert edit.new_text == '\nimport os\n', 'the import line is written'
	assert aimp_inserted(content, action) == "module main\n\nimport os\n\nfn main() {\n\tp := os.join_path('a', 'b')\n\tprintln(p)\n}\n", 'the buffer holds the import once the fix is taken'
}

// A module the file already imports is not offered again: the line to add is
// already there.
fn test_add_import_refuses_a_module_the_file_already_imports() {
	mut app := aimp_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	root := os.join_path(app.temp_dir, 'aimp_imported')
	content := "module main\n\nimport os\n\nfn main() {\n\tp := os.join_path('a', 'b')\n\tprintln(p)\n}\n"
	_, uri := aimp_project(root, map[string]string{}, content)
	assert aimp_refuses(mut app, uri, content, aimp_cursor(content, 'os.', 0)), 'a module the file imports is not offered'
}

// A local that shadows the module is what the file uses at the name, so an
// import would name something the buffer never reaches. The same project is
// offered the import in test_add_import_offers_a_module_of_the_project, without
// the local.
fn test_add_import_refuses_a_local_that_shadows_the_module() {
	mut app := aimp_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	root := os.join_path(app.temp_dir, 'aimp_shadow')
	modules := {
		'aimplib': "module aimplib\n\npub fn make() string {\n\treturn ''\n}\n"
	}
	content := "module main\n\nfn main() {\n\taimplib := ''\n\tprintln(aimplib.make())\n}\n"
	_, uri := aimp_project(root, modules, content)
	assert aimp_refuses(mut app, uri, content, aimp_cursor(content, 'aimplib.', 0)), 'a module a local shadows is not offered'
}

// The control for the local above: the same buffer without it does offer the
// module of the project, so the local was the reason it was refused.
fn test_add_import_offers_a_module_of_the_project() {
	mut app := aimp_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	root := os.join_path(app.temp_dir, 'aimp_project')
	modules := {
		'aimplib': "module aimplib\n\npub fn make() string {\n\treturn ''\n}\n"
	}
	content := 'module main\n\nfn main() {\n\tprintln(aimplib.make())\n}\n'
	main_path, uri := aimp_project(root, modules, content)
	assert app.importable_modules(main_path).any(it.path == 'aimplib' && it.origin == .project), 'the project module is offered to import'
	action := aimp_action(mut app, uri, content, aimp_cursor(content, 'aimplib.', 0))
	assert action.title == 'Add import `aimplib`', 'the title names the project module'
	assert aimp_edit(action).new_text == '\nimport aimplib\n', 'the project module is imported by its path'
}

// The modules of vlib are importable from any file, so a use of one of them is
// offered the same import.
fn test_add_import_offers_a_vlib_module() {
	mut app := aimp_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	root := os.join_path(app.temp_dir, 'aimp_vlib')
	content := 'module main\n\nfn main() {\n\tm := math.max(1, 2)\n\tprintln(m)\n}\n'
	main_path, uri := aimp_project(root, map[string]string{}, content)
	assert app.importable_modules(main_path).any(it.path == 'math' && it.origin == .vlib), 'math is offered as a module of vlib'
	action := aimp_action(mut app, uri, content, aimp_cursor(content, 'math.', 0))
	assert action.title == 'Add import `math`', 'the title names the module of vlib'
	edit := aimp_edit(action)
	assert edit.range.start.line == 1, 'the import goes after the module line'
	assert edit.new_text == '\nimport math\n', 'the module of vlib is imported by its path'
}

// A name that is only mentioned — as a value, or standing on its own — is not a
// use of a module, even when a module carries that name.
fn test_add_import_refuses_a_bare_identifier_that_names_a_module() {
	mut app := aimp_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	root := os.join_path(app.temp_dir, 'aimp_bare')
	value := 'module main\n\nfn main() {\n\tprintln(math)\n}\n'
	_, uri := aimp_project(root, map[string]string{}, value)
	assert aimp_refuses(mut app, uri, value, aimp_cursor(value, 'math', 0)), 'a module passed as a value is not offered'
	standalone := 'module main\n\nfn main() {\n\tx := 1\n\tmath\n}\n'
	assert aimp_refuses(mut app, uri, standalone, aimp_cursor(standalone, 'math', 0)), 'a bare mention is not a use of a module'
}

// With the cursor on the member of a qualified expression, the import offered is
// the module of that member: `join` of `os.join` is offered an `import os`.
fn test_add_import_offers_the_module_of_the_member_under_the_cursor() {
	mut app := aimp_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	root := os.join_path(app.temp_dir, 'aimp_member')
	content := "module main\n\nfn main() {\n\tp := os.join_path('a', 'b')\n\tprintln(p)\n}\n"
	_, uri := aimp_project(root, map[string]string{}, content)
	action := aimp_action(mut app, uri, content, aimp_cursor(content, 'join_path', 0))
	assert action.title == 'Add import `os`', 'the import is the module of the member'
	assert aimp_edit(action).new_text == '\nimport os\n', 'the import line is written'
}

// Only the base of a chain can be a module: the member of `cfg.time.now` is not
// `time`, which is a module of vlib and would be offered if the name were taken
// from the member instead of from the base.
fn test_add_import_refuses_the_member_of_a_local_chain() {
	mut app := aimp_app()
	defer {
		os.rmdir_all(app.temp_dir) or {}
	}
	root := os.join_path(app.temp_dir, 'aimp_chain')
	content := "module main\n\nfn main() {\n\tcfg := ''\n\tprintln(cfg.time.now)\n}\n"
	main_path, uri := aimp_project(root, map[string]string{}, content)
	assert app.importable_modules(main_path).any(it.path == 'time'), 'time is a module this file could import'
	assert aimp_refuses(mut app, uri, content, aimp_cursor(content, 'now', 0)), 'the name is the base of the chain, not the member'
}
