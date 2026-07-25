// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time

fn index_test_app() &App {
	return &App{
		open_files: map[string]string{}
		temp_dir:   os.temp_dir()
	}
}

fn index_test_tmpdir(tag string) string {
	dir := os.join_path(os.temp_dir(), 'vls_index_${tag}_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(dir) or { assert false, 'mkdir failed: ${err}' }
	return dir
}

fn test_index_workspace_symbols_from_open_buffers() {
	mut app := index_test_app()
	app.open_files['file:///tmp/a.v'] = 'module main\n\nfn alpha() {}\n\nstruct Beta {\n\tx int\n}\n'
	app.open_files['file:///tmp/b.v'] = 'module main\n\nfn gamma() {}\n'
	// No workspace root / v.mod, so only the open buffers are indexed (no walk).
	app.ensure_dirs_indexed(app.index_query_dirs())

	all := app.query_workspace_symbols('')
	names := all.map(it.name)
	assert names.any(it == 'alpha')
	assert names.any(it == 'gamma')
	assert names.any(it == 'Beta')
	assert names.any(it == 'Beta.x')

	// Filtered query is case-insensitive and substring-based.
	betas := app.query_workspace_symbols('bet')
	assert betas.any(it.name == 'Beta')
	assert betas.all(it.name.to_lower().contains('bet'))
}

fn test_index_incremental_reindex_reflects_change() {
	mut app := index_test_app()
	uri := 'file:///tmp/inc.v'
	app.open_files[uri] = 'module main\n\nfn one() {}\n'
	app.reindex_uri(uri)
	assert app.query_workspace_symbols('one').len == 1
	assert app.query_workspace_symbols('two').len == 0

	// Edit the buffer and reindex: the old symbol is gone, the new one appears.
	app.open_files[uri] = 'module main\n\nfn two() {}\n'
	app.reindex_uri(uri)
	assert app.query_workspace_symbols('one').len == 0
	assert app.query_workspace_symbols('two').len == 1
}

fn test_index_reindex_skips_unchanged_content() {
	mut app := index_test_app()
	uri := 'file:///tmp/same.v'
	app.open_files[uri] = 'module main\n\nfn f() {}\n'
	app.reindex_uri(uri)
	fp1 := app.symbol_index[uri].fingerprint
	app.reindex_uri(uri) // same content
	fp2 := app.symbol_index[uri].fingerprint
	assert fp1 == fp2
}

fn test_index_doc_lookup() {
	mut app := index_test_app()
	app.open_files['file:///tmp/doc.v'] = 'module main\n\n// greet says hello\nfn greet() {}\n'
	app.ensure_dirs_indexed(app.index_query_dirs())
	assert app.find_indexed_doc('greet') == 'greet says hello'
	assert app.find_indexed_doc('missing') == ''
}

fn test_index_find_fn() {
	mut app := index_test_app()
	uri := 'file:///tmp/fn.v'
	app.open_files[uri] = 'module main\n\nfn target() {}\n'
	app.ensure_dirs_indexed(app.index_query_dirs())
	found_uri, sym := app.find_indexed_fn('target') or {
		assert false, 'expected to find target'
		return
	}
	assert found_uri == uri
	assert extract_simple_fn_name(sym.name) == 'target'
}

fn test_find_project_root_walks_up_to_v_mod() {
	root := index_test_tmpdir('proot')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or {
		assert false, 'write v.mod failed'
		return
	}
	nested := os.join_path(root, 'sub', 'deep')
	os.mkdir_all(nested) or {
		assert false, 'mkdir nested failed'
		return
	}
	assert find_project_root(nested) == root
	// A directory with no v.mod above it has no project root.
	no_mod := index_test_tmpdir('nomod')
	defer {
		os.rmdir_all(no_mod) or {}
	}
	assert find_project_root(no_mod) == ''
}

fn test_collect_v_files_excludes_hidden_and_heavy_dirs() {
	root := index_test_tmpdir('collect')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'main.v'), 'module main\n') or { return }
	os.mkdir_all(os.join_path(root, '.git')) or { return }
	os.write_file(os.join_path(root, '.git', 'hooked.v'), 'module main\n') or { return }
	os.mkdir_all(os.join_path(root, 'node_modules')) or { return }
	os.write_file(os.join_path(root, 'node_modules', 'dep.v'), 'module main\n') or { return }
	os.mkdir_all(os.join_path(root, 'sub')) or { return }
	os.write_file(os.join_path(root, 'sub', 'lib.v'), 'module main\n') or { return }

	mut files := []string{}
	collect_v_files(root, mut files)
	assert files.any(it.ends_with('main.v'))
	assert files.any(it.ends_with('lib.v'))
	assert files.all(!it.contains('.git'))
	assert files.all(!it.contains('node_modules'))
}

fn test_index_scoped_to_v_mod_project_walks_disk() {
	root := index_test_tmpdir('scoped')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or { return }
	os.write_file(os.join_path(root, 'lib.v'), 'module main\n\nfn ondisk_fn() {}\n') or { return }
	// Open a different file in the same project (not the one with the symbol).
	uri := path_to_uri(os.join_path(root, 'main.v'))
	app_content := 'module main\n\nfn main() {}\n'
	os.write_file(os.join_path(root, 'main.v'), app_content) or { return }
	mut app := index_test_app()
	app.open_files[uri] = app_content

	app.ensure_dirs_indexed(app.index_query_dirs())
	// The on-disk sibling in the same v.mod project is indexed even though it was
	// never opened.
	assert app.query_workspace_symbols('ondisk_fn').len == 1
}
