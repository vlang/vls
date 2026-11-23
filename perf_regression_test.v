// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time

// Performance and memory regression tests.
//
// These block large slowdowns and memory regressions from future changes
// (including merges): every test is toolchain-independent (no compiler
// subprocess), in-process, and calibrated with wide margins so ordinary CI
// noise cannot flake them. They assert order-of-magnitude behavior, not
// fine performance: a per-file `real_path` syscall regression or an
// unbounded cache must fail here before it ships.
//
// Thresholds were calibrated on a loaded Windows dev box where the optimized
// paths measure tens of milliseconds; failing bounds sit 10-50x above that.

const perf_regression_files = 400

fn perf_reg_test_app() &App {
	return &App{
		open_files: map[string]string{}
		temp_dir:   os.temp_dir()
	}
}

fn perf_reg_tmpdir(tag string) string {
	dir := os.join_path(os.temp_dir(), 'vls_perf_${tag}_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

// perf_regression_project creates a same-module project with `n` files.
fn perf_regression_project(n int) (string, string, string) {
	root := perf_reg_tmpdir('reg_${n}')
	os.write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'perfreg'\n}\n") or {
		panic(err)
	}
	for i in 0 .. n {
		os.write_file(os.join_path(root, 'util${i}.v'), 'module perfreg\n\npub fn scalefn${i}(a int) int {\n\treturn a + ${i}\n}\n') or {
			panic(err)
		}
	}
	main_path := os.join_path(root, 'main.v')
	main_text := 'module perfreg\n\nfn main() {\n\tx := scalefn0(1, 2)\n\tprintln(x)\n}\n'
	os.write_file(main_path, main_text) or { panic(err) }
	main_uri := path_to_uri(main_path)
	return root, main_uri, main_text
}

fn perf_regression_cleanup(root string) {
	os.rmdir_all(root) or {}
}

// test_perf_warm_completion_stays_fast guards the completion hot path: with
// the project indexed, answering must not scale with per-file syscalls.
// (The `real_path`-per-file regression measured 300-900ms server-side here;
// the fixed path measures tens of ms. The bound sits far above both to
// absorb CI noise while still catching a 10x regression.)
fn test_perf_warm_completion_stays_fast() {
	root, main_uri, main_text := perf_regression_project(perf_regression_files)
	defer {
		perf_regression_cleanup(root)
	}
	mut app := perf_reg_test_app()
	app.open_files[main_uri] = main_text
	app.workspace_roots << root
	// Cold walk + parse (not measured against the bound).
	_ := app.collect_module_completions(main_uri, root)
	for i in 0 .. 3 {
		start := time.now().unix_milli()
		result := app.collect_module_completions(main_uri, root)
		elapsed := time.now().unix_milli() - start
		assert result.items.len >= perf_regression_files, 'missing completions: ${result.items.len}'
		assert elapsed < 2000, 'warm completion #${i} took ${elapsed}ms (regression?)'
	}
}

// test_perf_open_storm_completion_stays_fast guards the many-open-files path:
// opening 30 buffers must not make the next completion slow.
fn test_perf_open_storm_completion_stays_fast() {
	root, main_uri, main_text := perf_regression_project(perf_regression_files)
	defer {
		perf_regression_cleanup(root)
	}
	mut app := perf_reg_test_app()
	app.open_files[main_uri] = main_text
	app.workspace_roots << root
	for i in 0 .. 30 {
		p := os.join_path(root, 'util${i}.v')
		app.open_files[path_to_uri(p)] = os.read_file(p) or { '' }
	}
	// Warm up: index everything once so the timed call measures steady-state
	// completion behind many open buffers, not first-parse cost.
	_ := app.collect_module_completions(main_uri, root)
	start := time.now().unix_milli()
	result := app.collect_module_completions(main_uri, root)
	elapsed := time.now().unix_milli() - start
	assert result.items.len >= perf_regression_files, 'missing completions: ${result.items.len}'
	assert elapsed < 2000, 'post-storm completion took ${elapsed}ms (regression?)'
}

// test_perf_fn_completions_match_filtered_module_items guards the removal of
// the duplicated per-file fn_completions list: the free-function query must
// return exactly the kind-3 subset of the module completions.
fn test_perf_fn_completions_match_filtered_module_items() {
	root, main_uri, main_text := perf_regression_project(10)
	defer {
		perf_regression_cleanup(root)
	}
	mut app := perf_reg_test_app()
	app.open_files[main_uri] = main_text
	app.workspace_roots << root
	_ := app.collect_module_completions(main_uri, root)
	got := app.query_module_fn_completions('perfreg', 'file:///none.v', root)
	assert got.len >= 10, 'expected fn completions, got ${got.len}'
	for item in got {
		assert item.kind == 3, 'non-function item ${item.label} in fn completions'
	}
}

// test_mem_occurrences_bounded guards the occurrence-cache bound: sweeping
// more files than the cap must evict closed files while keeping open ones,
// and evicted files must rebuild correctly on demand.
fn test_mem_occurrences_bounded() {
	root, main_uri, main_text := perf_regression_project(600)
	defer {
		perf_regression_cleanup(root)
	}
	mut app := perf_reg_test_app()
	app.open_files[main_uri] = main_text
	app.workspace_roots << root
	_ := app.collect_module_completions(main_uri, root)
	// Simulate hover on the open buffer, then sweep far past the cap.
	_ := app.occurrences_for(main_uri)
	for i in 0 .. 600 {
		p := os.join_path(root, 'util${i}.v')
		_ := app.occurrences_for(path_to_uri(p))
	}
	assert app.ref_occurrences.len <= index_max_occ_entries, 'occurrence cache unbounded: ${app.ref_occurrences.len}'
	assert main_uri in app.ref_occurrences, 'open buffer entry must never be evicted'
	// An evicted file rebuilds on demand with identical content.
	evicted_uri := path_to_uri(os.join_path(root, 'util0.v'))
	first := app.occurrences_for(evicted_uri)
	second := app.occurrences_for(evicted_uri)
	assert first.len == second.len && first.len > 0, 'evicted occurrences must rebuild'
}

// test_perf_watcher_project_key_cache guards the watched-files path: a batch
// of events asks for the same project keys many times. Without the explicit
// cache every lookup walks all ancestors checking for v.mod and then calls
// program_root, so the cost multiplies by the number of open buffers.
fn test_perf_watcher_project_key_cache() {
	root, _, _ := perf_regression_project(perf_regression_files)
	defer {
		perf_regression_cleanup(root)
	}
	deep := os.join_path(root, 'a', 'b', 'c', 'd')
	os.mkdir_all(deep) or { panic(err) }
	mut app := perf_reg_test_app()
	app.workspace_roots << root
	for i in 0 .. 30 {
		p := os.join_path(deep, 'util${i}.v')
		app.open_files[path_to_uri(p)] = 'module perfreg\n\npub fn scalefn${i}(a int) int { return a }\n'
	}
	uris := app.open_files.keys()
	assert uris.len == 30

	mut cache := map[string]string{}
	for uri in uris {
		assert app.generation_key(uri) == app.generation_key_cached(uri, mut cache), 'cached key differs'
	}

	uncached_start := time.now().unix_milli()
	for _ in 0 .. 50 {
		for uri in uris {
			_ := app.generation_key(uri)
		}
	}
	uncached_ms := time.now().unix_milli() - uncached_start

	cached_start := time.now().unix_milli()
	mut shared_cache := map[string]string{}
	for _ in 0 .. 50 {
		for uri in uris {
			_ := app.generation_key_cached(uri, mut shared_cache)
		}
	}
	cached_ms := time.now().unix_milli() - cached_start

	assert cached_ms * 2 < uncached_ms, 'key cache not effective: ${cached_ms}ms vs ${uncached_ms}ms'
}

// test_perf_config_fingerprint_is_memoized guards every compiler request: the
// fingerprint walks up to 64 ancestors checking v.mod and .vvmrc, and is asked
// again on each check and each question until a watcher event invalidates it.
fn test_perf_config_fingerprint_is_memoized() {
	root, _, _ := perf_regression_project(perf_regression_files)
	defer {
		perf_regression_cleanup(root)
	}
	deep := os.join_path(root, 'a', 'b', 'c', 'd', 'e', 'f')
	os.mkdir_all(deep) or { panic(err) }
	expected := project_config_fingerprint(deep)
	mut pool := new_shared_diagnostics_server_pool()
	assert pool.cached_config_fingerprint(deep) == expected

	uncached_start := time.now().unix_milli()
	for _ in 0 .. 200 {
		_ := project_config_fingerprint(deep)
	}
	uncached_ms := time.now().unix_milli() - uncached_start

	cached_start := time.now().unix_milli()
	for _ in 0 .. 200 {
		_ := pool.cached_config_fingerprint(deep)
	}
	cached_ms := time.now().unix_milli() - cached_start

	assert cached_ms * 2 < uncached_ms, 'config fingerprint memo not effective: ${cached_ms}ms vs ${uncached_ms}ms'
	// Invalidation must make the next lookup see the current files again.
	pool.forget_config_fingerprints()
	assert pool.cached_config_fingerprint(deep) == expected
}

// test_perf_line_info_snapshot_stays_fast guards the start of every async
// hover/definition worker: a large index must be copied in bulk rather than
// rehashing each entry into a fresh map.
fn test_perf_line_info_snapshot_stays_fast() {
	root, main_uri, main_text := perf_regression_project(perf_regression_files)
	defer {
		perf_regression_cleanup(root)
	}
	mut app := perf_reg_test_app()
	app.open_files[main_uri] = main_text
	app.workspace_roots << root
	for i in 0 .. perf_regression_files {
		uri := path_to_uri(os.join_path(root, 'util${i}.v'))
		app.symbol_index[uri] = IndexEntry{}
		app.indexed_dirs[uri] = true
		app.index_skipped_uris[uri] = false
	}
	app.vlib_fn_cache['strings'] = map[string]string{}
	for i in 0 .. 500 {
		app.vlib_fn_cache['strings']['fn${i}'] = 'voidptr'
	}
	flag := &CancelFlag{}
	_ := app.line_info_snapshot(flag)
	start := time.now().unix_milli()
	for _ in 0 .. 50 {
		snapshot := app.line_info_snapshot(flag)
		assert snapshot.symbol_index.len == perf_regression_files
	}
	elapsed := time.now().unix_milli() - start
	assert elapsed < 2000, 'line-info snapshot took ${elapsed}ms (regression?)'
}
