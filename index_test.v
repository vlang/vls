// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json2
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

fn test_index_walk_reuses_equivalent_open_document_uri() {
	root := index_test_tmpdir('open_uri')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'main.v')
	os.write_file(path, 'module main\n\nfn stale_disk_symbol() {}\n') or {
		assert false, 'write main.v failed: ${err}'
		return
	}
	canonical_uri := path_to_uri(path)
	open_uri := canonical_uri.replace_once('file:///', 'file://localhost/')
	mut app := index_test_app()
	app.open_files[open_uri] = 'module main\n\nfn authoritative_open_symbol() {}\n'

	app.ensure_dirs_indexed([root])

	assert open_uri in app.symbol_index
	assert canonical_uri !in app.symbol_index
	assert app.query_workspace_symbols('stale_disk_symbol').len == 0
	open_symbols := app.query_workspace_symbols('authoritative_open_symbol')
	assert open_symbols.len == 1
	assert open_symbols[0].location.uri == open_uri
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

fn test_watched_file_reindex_drops_oversized_disk_entry() {
	root := index_test_tmpdir('watched_large')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'large.v')
	uri := path_to_uri(path)
	os.write_file(path, 'module main\n\nfn before_growth() {}\n') or {
		assert false, 'write initial file failed: ${err}'
		return
	}
	mut app := index_test_app()
	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [FileEvent{
				uri:        uri
				event_type: 1
			}]
		})
	})
	assert uri in app.symbol_index
	app.occurrences_for(uri)
	assert uri in app.ref_occurrences

	os.write_file(path, 'x'.repeat(index_max_file_bytes + 1)) or {
		assert false, 'grow watched file failed: ${err}'
		return
	}
	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [FileEvent{
				uri:        uri
				event_type: 2
			}]
		})
	})
	assert uri !in app.symbol_index
	assert uri !in app.ref_occurrences
}

fn test_watched_file_reindex_obeys_total_entry_limit() {
	root := index_test_tmpdir('watched_count')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'beyond_limit.v')
	uri := path_to_uri(path)
	os.write_file(path, 'module main\n\nfn beyond_limit() {}\n') or {
		assert false, 'write watched file failed: ${err}'
		return
	}
	mut app := index_test_app()
	for i in 0 .. index_max_files {
		app.symbol_index['file:///already_indexed_${i}.v'] = IndexEntry{}
	}
	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [FileEvent{
				uri:        uri
				event_type: 1
			}]
		})
	})
	assert app.symbol_index.len == index_max_files
	assert uri !in app.symbol_index
}

fn test_watched_file_reuses_equivalent_open_document_uri() {
	root := index_test_tmpdir('watched_open_uri')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'main.v')
	os.write_file(path, 'module main\n\nfn stale_disk_symbol() {}\n') or {
		assert false, 'write main.v failed: ${err}'
		return
	}
	event_uri := path_to_uri(path)
	open_uri := event_uri.replace_once('file:///', 'file://localhost/')
	mut app := index_test_app()
	app.watched_files_active = true
	app.open_files[open_uri] = 'module main\n\nfn authoritative_open_symbol() {}\n'
	app.reindex_uri(open_uri)

	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [FileEvent{
				uri:        event_uri
				event_type: 2
			}]
		})
	})

	assert open_uri in app.symbol_index
	assert event_uri !in app.symbol_index
	assert app.query_workspace_symbols('stale_disk_symbol').len == 0
	open_symbols := app.query_workspace_symbols('authoritative_open_symbol')
	assert open_symbols.len == 1
	assert open_symbols[0].location.uri == open_uri
}

fn test_reconcile_indexed_dir_retains_entries_after_incomplete_walk() {
	mut app := index_test_app()
	kept_uri := 'file:///workspace/kept.v'
	unseen_uri := 'file:///workspace/unseen.v'
	app.symbol_index[kept_uri] = IndexEntry{}
	app.symbol_index[unseen_uri] = IndexEntry{}
	app.ref_occurrences[unseen_uri] = OccEntry{}
	present := {
		kept_uri: true
	}

	// A partial walk did not see unseen.v, but it must retain the old entry.
	app.reconcile_indexed_dir('/workspace', present, false)
	assert unseen_uri in app.symbol_index
	assert unseen_uri in app.ref_occurrences

	// The same absence after a complete walk proves the file was deleted.
	app.reconcile_indexed_dir('/workspace', present, true)
	assert kept_uri in app.symbol_index
	assert unseen_uri !in app.symbol_index
	assert unseen_uri !in app.ref_occurrences
}

fn test_index_doc_lookup() {
	mut app := index_test_app()
	app.open_files['file:///tmp/doc.v'] = 'module main\n\n// greet says hello\nfn greet() {}\n'
	app.ensure_dirs_indexed(app.index_query_dirs())
	assert app.find_indexed_doc_in_scope('greet', '/tmp', '', '') == 'greet says hello'
	assert app.find_indexed_doc_in_scope('missing', '/tmp', '', '') == ''
}

fn test_index_doc_lookup_scoped_to_project() {
	mut app := index_test_app()
	// Two unrelated projects each declare a documented `foo` in module `main`.
	app.open_files['file:///projA/lib.v'] = 'module main\n\n// A-foo does A\npub fn foo() {}\n'
	app.open_files['file:///projB/lib.v'] = 'module main\n\n// B-foo does B\npub fn foo() {}\n'
	app.ensure_dirs_indexed(app.index_query_dirs())
	// A hover in project A must not pick up project B's doc for the same name.
	assert app.find_indexed_doc_in_scope('foo', '/projA', '/projA', '') == 'A-foo does A'
	assert app.find_indexed_doc_in_scope('foo', '/projB', '/projB', '') == 'B-foo does B'
}

fn test_index_find_fn() {
	mut app := index_test_app()
	uri := 'file:///tmp/fn.v'
	app.open_files[uri] = 'module main\n\nfn target() {}\n'
	app.ensure_dirs_indexed(app.index_query_dirs())
	found_uri, sym := app.find_indexed_fn('target', false, []) or {
		assert false, 'expected to find target'
		return
	}
	assert found_uri == uri
	assert extract_simple_fn_name(sym.name) == 'target'
}

fn test_index_find_fn_restricted_to_dirs() {
	mut app := index_test_app()
	// Same simple function name in two unrelated indexed roots.
	app.open_files['file:///rootA/a.v'] = 'module main\n\nfn shared() {}\n'
	app.open_files['file:///rootB/b.v'] = 'module main\n\nfn shared() {}\n'
	app.ensure_dirs_indexed(app.index_query_dirs())

	// Restricting to rootB must return rootB's declaration, never rootA's, even
	// though rootA sorts first.
	uri_b, _ := app.find_indexed_fn('shared', false, ['/rootB']) or {
		assert false, 'expected to find shared in rootB'
		return
	}
	assert uri_b == 'file:///rootB/b.v'
	uri_a, _ := app.find_indexed_fn('shared', false, ['/rootA']) or {
		assert false, 'expected to find shared in rootA'
		return
	}
	assert uri_a == 'file:///rootA/a.v'
}

fn test_index_find_fn_skips_test_files() {
	mut app := index_test_app()
	prod := 'file:///tmp/proj/lib.v'
	test := 'file:///tmp/proj/lib_test.v'
	app.open_files[prod] = 'module main\n\nfn helper() {}\n'
	app.open_files[test] = 'module main\n\nfn helper() {}\n'
	app.ensure_dirs_indexed(app.index_query_dirs())

	// Production lookup must resolve to the production file, never the test one,
	// regardless of URI sort order (lib.v sorts before lib_test.v here, but the
	// filter is what guarantees it).
	prod_uri, _ := app.find_indexed_fn('helper', false, []) or {
		assert false, 'expected to find helper in production'
		return
	}
	assert prod_uri == prod
	assert !prod_uri.ends_with('_test.v')

	// A query originating from a test file may resolve into test declarations.
	any_uri, _ := app.find_indexed_fn('helper', true, []) or {
		assert false, 'expected to find helper with tests included'
		return
	}
	assert any_uri in [prod, test]
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
	assert collect_v_files(root, mut files)
	assert files.any(it.ends_with('main.v'))
	assert files.any(it.ends_with('lib.v'))
	assert files.all(!it.contains('.git'))
	assert files.all(!it.contains('node_modules'))
}

fn test_collect_v_files_excludes_out_of_tree_symlink() {
	root := index_test_tmpdir('containment')
	outside := index_test_tmpdir('outside')
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(outside) or {}
	}
	os.write_file(os.join_path(root, 'in.v'), 'module main\n') or {
		assert false, 'write in.v failed'
		return
	}
	os.write_file(os.join_path(outside, 'out.v'), 'module main\n') or {
		assert false, 'write out.v failed'
		return
	}
	// A directory symlink inside the workspace whose target is outside it.
	os.symlink(outside, os.join_path(root, 'external')) or {
		// Symlink creation can be unavailable (permissions/filesystem); skip then.
		return
	}
	mut files := []string{}
	assert collect_v_files(root, mut files)
	assert files.any(it.ends_with('in.v'))
	// The out-of-tree file reachable only via the symlink must NOT be indexed.
	assert files.all(!it.ends_with('out.v'))
}

fn test_collect_v_files_excludes_out_of_tree_file_symlink() {
	root := index_test_tmpdir('file_containment')
	outside := index_test_tmpdir('file_outside')
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(outside) or {}
	}
	os.write_file(os.join_path(root, 'in.v'), 'module main\n') or {
		assert false, 'write in.v failed'
		return
	}
	outside_file := os.join_path(outside, 'out.v')
	os.write_file(outside_file, 'module external\n') or {
		assert false, 'write out.v failed'
		return
	}
	os.symlink(outside_file, os.join_path(root, 'external.v')) or {
		// Symlink creation can be unavailable (permissions/filesystem); skip then.
		return
	}

	mut files := []string{}
	assert collect_v_files(root, mut files)
	assert files.any(it.ends_with('in.v'))
	assert files.all(!it.ends_with('external.v'))
}

fn test_collect_v_files_deduplicates_in_tree_file_symlink() {
	root := index_test_tmpdir('file_alias')
	defer {
		os.rmdir_all(root) or {}
	}
	real_file := os.join_path(root, 'real.v')
	os.write_file(real_file, 'module main\n\nfn unique_symbol() {}\n') or {
		assert false, 'write real.v failed: ${err}'
		return
	}
	os.symlink(real_file, os.join_path(root, 'alias.v')) or {
		// Symlink creation can be unavailable (permissions/filesystem); skip then.
		return
	}

	mut files := []string{}
	assert collect_v_files(root, mut files)
	assert files.len == 1
	assert normalized_index_path(files[0]) == normalized_index_path(real_file)

	mut app := index_test_app()
	app.ensure_dirs_indexed([root])
	assert app.query_workspace_symbols('unique_symbol').len == 1
	assert app.symbol_index.len == 1
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

fn test_index_module_fn_completions_same_module_only() {
	mut app := index_test_app()
	app.open_files['file:///tmp/mod/a.v'] = 'module foo\n\npub fn helper(x int) int {\n\treturn x\n}\n'
	app.open_files['file:///tmp/mod/b.v'] = 'module foo\n\nfn main() {}\n'
	app.open_files['file:///tmp/mod/c.v'] = 'module bar\n\nfn other() {}\n'

	comps := app.collect_module_fn_completions('file:///tmp/mod/b.v', '/tmp/mod')
	// helper is a same-module (foo) sibling of b.v
	assert comps.any(it.label == 'helper')
	// other belongs to module bar and must be excluded
	assert !comps.any(it.label == 'other')
	// b.v's own functions are excluded (it is the current file)
	assert !comps.any(it.label == 'main')
}

fn test_index_module_fn_completions_scoped_to_directory() {
	mut app := index_test_app()
	// Two unrelated projects that both declare `module main`.
	app.open_files['file:///proj1/a.v'] = 'module main\n\npub fn one() {}\n'
	app.open_files['file:///proj1/b.v'] = 'module main\n\nfn main() {}\n'
	app.open_files['file:///proj2/c.v'] = 'module main\n\npub fn two() {}\n'

	comps := app.collect_module_fn_completions('file:///proj1/b.v', '/proj1')
	// A same-directory sibling in the same module is offered.
	assert comps.any(it.label == 'one')
	// A file with the same module name in a DIFFERENT directory must not leak in.
	assert !comps.any(it.label == 'two')
}

fn test_shallow_index_refreshes_and_reconciles_without_watchers() {
	root := index_test_tmpdir('shallow')
	defer {
		os.rmdir_all(root) or {}
	}
	sib := os.join_path(root, 'sib.v')
	os.write_file(sib, 'module main\n\nfn gamma() {}\n') or {
		assert false, 'write sib.v failed'
		return
	}
	mut app := index_test_app()
	app.supports_dynamic_watched_files_registration = false // no client watchers
	app.ensure_dir_shallow_indexed(root)
	assert app.query_workspace_symbols('gamma').len == 1

	// An external edit to the unopened sibling is picked up on a throttled refresh.
	os.write_file(sib, 'module main\n\nfn delta() {}\n') or {
		assert false, 'rewrite sib.v failed'
		return
	}
	app.indexed_dir_walk_ms[root] = 0
	app.ensure_dir_shallow_indexed(root)
	assert app.query_workspace_symbols('gamma').len == 0
	assert app.query_workspace_symbols('delta').len == 1

	// Deleting the sibling reconciles its entry out of the index.
	os.rm(sib) or {
		assert false, 'rm sib.v failed'
		return
	}
	app.indexed_dir_walk_ms[root] = 0
	app.ensure_dir_shallow_indexed(root)
	assert app.query_workspace_symbols('delta').len == 0
}

fn test_shallow_index_excludes_out_of_tree_file_symlink() {
	root := index_test_tmpdir('shallow_file_containment')
	outside := index_test_tmpdir('shallow_file_outside')
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(outside) or {}
	}
	os.write_file(os.join_path(root, 'in.v'), 'module main\n\nfn inside_symbol() {}\n') or {
		assert false, 'write in.v failed: ${err}'
		return
	}
	outside_file := os.join_path(outside, 'out.v')
	os.write_file(outside_file, 'module main\n\nfn external_symbol() {}\n') or {
		assert false, 'write out.v failed: ${err}'
		return
	}
	os.symlink(outside_file, os.join_path(root, 'external.v')) or {
		// Symlink creation can be unavailable (permissions/filesystem); skip then.
		return
	}

	mut app := index_test_app()
	app.ensure_dir_shallow_indexed(root)

	assert app.query_workspace_symbols('inside_symbol').len == 1
	assert app.query_workspace_symbols('external_symbol').len == 0
	assert path_to_uri(os.join_path(root, 'external.v')) !in app.symbol_index
}

fn test_shallow_index_skips_reconciliation_after_hitting_entry_cap() {
	root := index_test_tmpdir('shallow_cap')
	defer {
		os.rmdir_all(root) or {}
	}
	new_path := os.join_path(root, 'a_new.v')
	kept_path := os.join_path(root, 'z_kept.v')
	os.write_file(new_path, 'module main\n\nfn new_symbol() {}\n') or {
		assert false, 'write new file failed: ${err}'
		return
	}
	os.write_file(kept_path, 'module main\n\nfn kept_symbol() {}\n') or {
		assert false, 'write kept file failed: ${err}'
		return
	}
	mut app := index_test_app()
	for i in 0 .. index_max_files {
		app.symbol_index['file:///already_indexed_${i}.v'] = IndexEntry{}
	}
	app.symbol_index.delete('file:///already_indexed_0.v')
	kept_uri := path_to_uri(kept_path)
	app.reindex_uri(kept_uri)
	assert app.symbol_index.len == index_max_files
	app.indexed_dir_walk_ms[root] = 0

	app.ensure_dir_shallow_indexed(root)

	assert 'shallow:${root}' in app.index_incomplete_scopes
	assert kept_uri in app.symbol_index
	assert app.query_workspace_symbols('kept_symbol').len == 1
}

// --- reference / occurrence index (P1-05) ---

fn test_extract_identifier_occurrences_skips_comments_strings_numbers() {
	content := 'fn foo() {\n\tbar := 123 // baz\n\ts := "qux"\n\tfoo()\n}\n'
	occ := extract_identifier_occurrences(content, .utf16)
	// foo: declaration (line 0) + call (line 3)
	assert occ['foo'].len == 2
	assert occ['foo'][0].line == 0
	assert occ['foo'][0].start_char == 3
	assert occ['foo'][0].end_char == 6
	assert occ['foo'][1].line == 3
	// bar assigned once
	assert occ['bar'].len == 1
	// identifiers inside a line comment (baz) and a string (qux) are not indexed
	assert 'baz' !in occ
	assert 'qux' !in occ
	// number literals are not identifiers
	assert '123' !in occ
}

fn test_extract_identifier_occurrences_indexes_string_interpolations() {
	content := "fn greet(name string) string {\n\tother := 'ignored'\n\treturn 'hello \${name} \${other.to_upper()} \$name literal_name'\n}\n"
	occ := extract_identifier_occurrences(content, .utf16)

	// The parameter plus braced and shorthand interpolation references.
	assert occ['name'].len == 3
	// The declaration and its use inside a compound interpolation expression.
	assert occ['other'].len == 2
	assert occ['to_upper'].len == 1
	// Ordinary literal text remains excluded from rename candidates.
	assert 'ignored' !in occ
	assert 'hello' !in occ
	assert 'literal_name' !in occ
}

fn test_extract_identifier_occurrences_skips_multiline_block_comments() {
	mut content := 'fn target() {}\n/*\n'
	for _ in 0 .. reference_semantic_max_candidates + 1 {
		content += 'target\n'
	}
	content += '*/\nfn use() { target() }\n'
	occ := extract_identifier_occurrences(content, .utf16)

	// Only the declaration and real call are candidates; repeated comment text
	// cannot push rename over its semantic candidate cap.
	assert occ['target'].len == 2
}

fn test_occurrences_for_caches_by_fingerprint() {
	mut app := index_test_app()
	uri := 'file:///tmp/occ.v'
	app.open_files[uri] = 'module main\n\nfn a() {\n\ta()\n}\n'
	first := app.occurrences_for(uri)
	assert first['a'].len == 2
	fp1 := app.ref_occurrences[uri].fingerprint
	// Unchanged content reuses the cache entry.
	app.occurrences_for(uri)
	assert app.ref_occurrences[uri].fingerprint == fp1
	// Changing the buffer rebuilds it.
	app.open_files[uri] = 'module main\n\nfn a() {\n\ta()\n\ta()\n}\n'
	second := app.occurrences_for(uri)
	assert second['a'].len == 3
}

fn test_search_symbol_in_dirs_finds_cross_file_occurrences() {
	mut app := index_test_app()
	app.open_files['file:///tmp/r/a.v'] = 'module main\n\nfn foo() {}\n'
	app.open_files['file:///tmp/r/b.v'] = 'module main\n\nfn bar() {\n\tfoo()\n}\n'
	locs := app.search_symbol_in_dirs('foo', 0)
	// declaration in a.v + call in b.v
	assert locs.len == 2
	uris := locs.map(it.uri)
	assert uris.any(it.ends_with('a.v'))
	assert uris.any(it.ends_with('b.v'))
}

fn test_search_symbol_in_dirs_indexes_loose_unopened_siblings() {
	root := index_test_tmpdir('loose')
	defer {
		os.rmdir_all(root) or {}
	}
	// A loose multi-file module: no v.mod, no workspace root.
	a := os.join_path(root, 'a.v')
	b := os.join_path(root, 'b.v')
	os.write_file(a, 'module main\n\nfn foo() {}\n') or {
		assert false, 'write a.v failed'
		return
	}
	os.write_file(b, 'module main\n\nfn bar() {\n\tfoo()\n}\n') or {
		assert false, 'write b.v failed'
		return
	}
	mut app := index_test_app()
	// Only a.v is open; b.v is an unopened sibling that exists only on disk.
	app.open_files[path_to_uri(a)] = os.read_file(a) or { '' }

	locs := app.search_symbol_in_dirs('foo', 0)
	uris := locs.map(it.uri)
	// The declaration in the open a.v AND the call in the unopened sibling b.v
	// must both be found — otherwise rename would leave the module uncompilable.
	assert uris.any(it.ends_with('a.v'))
	assert uris.any(it.ends_with('b.v'))
}

fn test_generation_key_scopes_to_project_root() {
	root := index_test_tmpdir('genkey')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or {
		assert false, 'write v.mod failed'
		return
	}
	sub := os.join_path(root, 'sub')
	os.mkdir_all(sub) or {
		assert false, 'mkdir sub failed'
		return
	}
	mut app := index_test_app()
	// Two files in different directories of the same project share a generation
	// key (the project root), so editing one invalidates the other's cache.
	uri_a := path_to_uri(os.join_path(root, 'a.v'))
	uri_b := path_to_uri(os.join_path(sub, 'b.v'))
	assert app.generation_key(uri_a) == app.generation_key(uri_b)
	before := app.project_generation(uri_a)
	app.bump_generation(uri_b)
	assert app.project_generation(uri_a) == before + 1
}

fn test_index_refresh_discovers_new_files_without_watchers() {
	root := index_test_tmpdir('refresh')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or {
		assert false, 'write v.mod failed'
		return
	}
	os.write_file(os.join_path(root, 'a.v'), 'module main\n\nfn alpha() {}\n') or {
		assert false, 'write a.v failed'
		return
	}
	mut app := index_test_app()
	app.supports_dynamic_watched_files_registration = false // no client watchers
	app.ensure_dirs_indexed([root])
	assert app.query_workspace_symbols('alpha').len == 1
	assert app.query_workspace_symbols('beta').len == 0

	// A file created after the first walk is discovered on a throttled re-walk.
	os.write_file(os.join_path(root, 'b.v'), 'module main\n\nfn beta() {}\n') or {
		assert false, 'write b.v failed'
		return
	}
	app.indexed_dir_walk_ms[root] = 0 // force the throttle to treat the dir as stale
	app.ensure_dirs_indexed([root])
	assert app.query_workspace_symbols('beta').len == 1
}

fn test_index_completeness_is_scoped_to_relevant_project() {
	parent := index_test_tmpdir('scoped_complete')
	defer {
		os.rmdir_all(parent) or {}
	}
	root_a := os.join_path(parent, 'root_a')
	root_b := os.join_path(parent, 'root_b')
	os.mkdir_all(root_a) or {
		assert false, 'mkdir root_a failed: ${err}'
		return
	}
	os.mkdir_all(root_b) or {
		assert false, 'mkdir root_b failed: ${err}'
		return
	}
	for root in [root_a, root_b] {
		os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or {
			assert false, 'write v.mod failed: ${err}'
			return
		}
	}
	path_a := os.join_path(root_a, 'main.v')
	os.write_file(path_a, 'module main\n\nfn target() {}\n') or {
		assert false, 'write root_a file failed: ${err}'
		return
	}
	path_b := os.join_path(root_b, 'oversized.v')
	os.write_file(path_b, 'x'.repeat(index_max_file_bytes + 1)) or {
		assert false, 'write oversized root_b file failed: ${err}'
		return
	}
	mut app := index_test_app()
	app.workspace_roots = [root_a, root_b]
	app.ensure_dirs_indexed(app.index_query_dirs())
	scope_a := app.index_scope_for_uri(path_to_uri(path_a))
	scope_b := app.index_scope_for_uri(path_to_uri(path_b))

	assert app.index_is_complete_for_scope(scope_a)
	assert !app.index_is_complete_for_scope(scope_b)
	assert !app.index_is_complete()
}

fn test_index_refresh_removes_deleted_files_without_watchers() {
	root := index_test_tmpdir('reconcile')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or {
		assert false, 'write v.mod failed'
		return
	}
	os.write_file(os.join_path(root, 'a.v'), 'module main\n\nfn alpha() {}\n') or {
		assert false, 'write a.v failed'
		return
	}
	b_path := os.join_path(root, 'b.v')
	os.write_file(b_path, 'module main\n\nfn beta() {}\n') or {
		assert false, 'write b.v failed'
		return
	}
	mut app := index_test_app()
	app.supports_dynamic_watched_files_registration = false // no client watchers
	app.ensure_dirs_indexed([root])
	assert app.query_workspace_symbols('alpha').len == 1
	assert app.query_workspace_symbols('beta').len == 1

	// Delete an unopened file on disk. Without watchers there is no delete
	// notification, so a throttled refresh must reconcile it out of the index.
	os.rm(b_path) or {
		assert false, 'rm b.v failed'
		return
	}
	app.indexed_dir_walk_ms[root] = 0 // force the throttle to treat the dir as stale
	app.ensure_dirs_indexed([root])
	assert app.query_workspace_symbols('beta').len == 0
	// The surviving file is untouched.
	assert app.query_workspace_symbols('alpha').len == 1
}

fn test_index_no_refresh_when_watchers_available() {
	root := index_test_tmpdir('nowatch')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or {
		assert false, 'write v.mod failed'
		return
	}
	os.write_file(os.join_path(root, 'a.v'), 'module main\n\nfn alpha() {}\n') or {
		assert false, 'write a.v failed'
		return
	}
	mut app := index_test_app()
	app.watched_files_active = true // registration acknowledged; rely on watcher events
	app.ensure_dirs_indexed([root])
	assert app.query_workspace_symbols('alpha').len == 1

	// With watchers active, freshness comes from didChangeWatchedFiles, so a bare
	// re-index call does NOT re-walk even when the recorded walk time looks stale.
	os.write_file(os.join_path(root, 'b.v'), 'module main\n\nfn beta() {}\n') or {
		assert false, 'write b.v failed'
		return
	}
	app.indexed_dir_walk_ms[root] = 0
	app.ensure_dirs_indexed([root])
	assert app.query_workspace_symbols('beta').len == 0
}

fn test_drop_index_under_removes_folder_entries() {
	mut app := index_test_app()
	app.open_files['file:///proj/a/x.v'] = 'module main\n\nfn ax() {}\n'
	app.open_files['file:///proj/b/y.v'] = 'module main\n\nfn by() {}\n'
	app.reindex_uri('file:///proj/a/x.v')
	app.reindex_uri('file:///proj/b/y.v')
	app.occurrences_for('file:///proj/a/x.v')
	app.indexed_dirs['/proj/a'] = true

	app.drop_index_under('/proj/a')
	// Entries under /proj/a are gone; /proj/b remains.
	assert 'file:///proj/a/x.v' !in app.symbol_index
	assert 'file:///proj/a/x.v' !in app.ref_occurrences
	assert 'file:///proj/b/y.v' in app.symbol_index
	// A boundary-similar path is NOT dropped.
	assert app.indexed_dirs.len == 0
}

fn test_removed_workspace_root_keeps_only_open_buffer_indexed() {
	root := index_test_tmpdir('removed_root')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), 'Module {}\n') or {
		assert false, 'write v.mod failed: ${err}'
		return
	}
	open_path := os.join_path(root, 'main.v')
	sibling_path := os.join_path(root, 'sibling.v')
	os.write_file(open_path, 'module main\n\nfn disk_open_symbol() {}\n') or {
		assert false, 'write main.v failed: ${err}'
		return
	}
	os.write_file(sibling_path, 'module main\n\nfn removed_sibling_symbol() {}\n') or {
		assert false, 'write sibling.v failed: ${err}'
		return
	}
	open_uri := path_to_uri(open_path)
	mut app := index_test_app()
	app.workspace_roots = [root]
	app.open_files[open_uri] = 'module main\n\nfn retained_open_symbol() {}\n'
	app.ensure_dirs_indexed(app.index_query_dirs())
	assert app.query_workspace_symbols('removed_sibling_symbol').len == 1

	app.on_did_change_workspace_folders(Request{
		params: json2.encode(DidChangeWorkspaceFoldersParams{
			event: WorkspaceFoldersChangeEvent{
				removed: [WorkspaceFolder{
					uri: path_to_uri(root)
				}]
			}
		})
	})
	app.ensure_dirs_indexed(app.index_query_dirs())
	app.ensure_loose_file_dirs_shallow_indexed()

	assert app.index_query_dirs().len == 0
	assert open_uri in app.symbol_index
	assert app.query_workspace_symbols('retained_open_symbol').len == 1
	assert app.query_workspace_symbols('removed_sibling_symbol').len == 0

	app.on_did_change_workspace_folders(Request{
		params: json2.encode(DidChangeWorkspaceFoldersParams{
			event: WorkspaceFoldersChangeEvent{
				added: [WorkspaceFolder{
					uri: path_to_uri(root)
				}]
			}
		})
	})
	app.ensure_dirs_indexed(app.index_query_dirs())
	assert app.query_workspace_symbols('removed_sibling_symbol').len == 1
}

fn test_index_large_multifile_project_stays_complete_and_incremental() {
	root := index_test_tmpdir('many_files')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'large_index_test'\n}\n") or {
		assert false, 'write v.mod failed: ${err}'
		return
	}

	file_count := 1500
	files_per_dir := 50
	for i in 0 .. file_count {
		dir := os.join_path(root, 'module_${i / files_per_dir:02}')
		os.mkdir_all(dir) or {
			assert false, 'mkdir ${dir} failed: ${err}'
			return
		}
		mut body := 'module large_index_test\n\nfn stress_symbol_${i}() int {\n\treturn ${i}\n}\n'
		if i == 0 {
			body += '\nfn shared_stress_symbol() {}\n'
		}
		if i == file_count - 1 {
			body += '\nfn use_shared_stress_symbol() {\n\tshared_stress_symbol()\n}\n'
		}
		os.write_file(os.join_path(dir, 'file_${i:04}.v'), body) or {
			assert false, 'write stress file ${i} failed: ${err}'
			return
		}
	}

	mut app := index_test_app()
	app.workspace_roots = [root]
	app.watched_files_active = true
	app.ensure_dirs_indexed([root])

	assert app.symbol_index.len == file_count
	assert app.index_is_complete()
	assert app.query_workspace_symbols('stress_symbol_0').any(it.name == 'stress_symbol_0')
	assert app.query_workspace_symbols('stress_symbol_749').any(it.name == 'stress_symbol_749')
	assert app.query_workspace_symbols('stress_symbol_1499').any(it.name == 'stress_symbol_1499')

	shared_locations := app.search_symbol_in_dirs('shared_stress_symbol', 0)
	assert shared_locations.len == 2
	assert shared_locations.any(it.range.start.line == 6)
	assert shared_locations.any(it.range.start.line == 7)

	changed_path := os.join_path(root, 'module_14', 'file_0749.v')
	changed_uri := path_to_uri(changed_path)
	os.write_file(changed_path,
		'module large_index_test\n\nfn stress_symbol_reindexed() int {\n\treturn 749\n}\n') or {
		assert false, 'rewrite stress file failed: ${err}'
		return
	}
	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [FileEvent{
				uri:        changed_uri
				event_type: 2
			}]
		})
	})
	assert app.symbol_index.len == file_count
	assert app.query_workspace_symbols('stress_symbol_749').len == 0
	assert app.query_workspace_symbols('stress_symbol_reindexed').len == 1
}

fn test_large_vlang_v_workspace_from_env() {
	configured_root := os.getenv('VLS_VLANG_V_REPO')
	if configured_root == '' {
		return
	}
	root := os.real_path(configured_root)
	assert os.is_file(os.join_path(root, 'v.mod')), 'VLS_VLANG_V_REPO must point at a vlang/v checkout'

	mut files := []string{}
	assert collect_v_files(root, mut files), 'vlang/v walk must finish without hitting index bounds'
	assert files.len >= 2000, 'expected a large vlang/v checkout, found only ${files.len} V files'

	mut app := index_test_app()
	app.workspace_roots = [root]
	app.watched_files_active = true
	app.ensure_dirs_indexed([root])

	assert app.index_is_complete()
	assert app.symbol_index.len >= 2000
	assert app.index_skipped_uris.len == 0
	assert app.symbol_index.len == files.len

	preferences := app.query_workspace_symbols('Preferences')
	assert preferences.len > 0
	preferences_uri := preferences[0].location.uri
	preference_occurrences := app.occurrences_for(preferences_uri)
	assert preference_occurrences['Preferences'].len > 0

	if main_uri, main_symbol := app.find_indexed_fn('main', false, [
		os.join_path(root, 'cmd'),
	])
	{
		assert main_uri.starts_with(path_to_uri(os.join_path(root, 'cmd')))
		assert main_symbol.name == 'main'
	} else {
		assert false, 'expected to find a production fn main under vlang/v cmd'
	}
}
