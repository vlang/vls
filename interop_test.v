// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json2
import time

fn interop_test_must_mkdir_all(path string) {
	os.mkdir_all(path) or {
		assert false, 'Failed to create directory ${path}: ${err}'
		return
	}
}

fn interop_test_must_write_file(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'Failed to write file ${path}: ${err}'
		return
	}
}

// ============================================================================
// Unit tests for interop utilities (URI/path conversion)
// ============================================================================

fn test_resolve_v_compiler_exe_prefers_configured_command() {
	old_command := os.getenv('VLS_V_COMMAND')
	defer {
		if old_command == '' {
			os.unsetenv('VLS_V_COMMAND')
		} else {
			os.setenv('VLS_V_COMMAND', old_command, true)
		}
	}
	configured := os.join_path(os.temp_dir(), 'configured-v-compiler')
	os.setenv('VLS_V_COMMAND', configured, true)
	assert resolve_v_compiler_exe() == configured
}

fn test_resolve_wrapper_target_ignores_plain_executable() {
	assert resolve_wrapper_target('C:\\v\\v.exe') == ''
	assert resolve_wrapper_target('/usr/local/bin/v') == ''
	assert resolve_wrapper_target('') == ''
	assert resolve_wrapper_target('v') == ''
}

fn test_resolve_wrapper_target_ignores_missing_wrapper() {
	missing := os.join_path(os.temp_dir(), 'vls_no_such_wrapper_${os.getpid()}.bat')
	assert resolve_wrapper_target(missing) == ''
}

fn test_resolve_wrapper_target_unwraps_bat_forwarding_to_exe() {
	base := os.join_path(os.temp_dir(), 'vls_wrapper_probe_${os.getpid()}')
	bin := os.join_path(base, '.bin')
	interop_test_must_mkdir_all(bin)
	defer {
		os.rmdir_all(base) or {}
	}
	target := os.join_path(base, 'v.exe')
	interop_test_must_write_file(target, '')
	wrapper := os.join_path(bin, 'v.bat')
	interop_test_must_write_file(wrapper, '@echo off\n"${target}" %*\n')
	assert resolve_wrapper_target(wrapper) == target
}

fn test_resolve_wrapper_target_ignores_bat_without_quoted_target() {
	base := os.join_path(os.temp_dir(), 'vls_wrapper_bare_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	wrapper := os.join_path(base, 'v.bat')
	interop_test_must_write_file(wrapper, '@echo off\nv.exe %*\n')
	assert resolve_wrapper_target(wrapper) == ''
}

fn test_resolve_wrapper_target_ignores_wrapper_chain() {
	base := os.join_path(os.temp_dir(), 'vls_wrapper_chain_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	inner := os.join_path(base, 'inner.bat')
	interop_test_must_write_file(inner, '@echo off\necho hi\n')
	outer := os.join_path(base, 'outer.bat')
	interop_test_must_write_file(outer, '@echo off\n"${inner}" %*\n')
	assert resolve_wrapper_target(outer) == ''
}

fn test_resolve_v_compiler_exe_unwraps_configured_wrapper() {
	old_command := os.getenv('VLS_V_COMMAND')
	defer {
		if old_command == '' {
			os.unsetenv('VLS_V_COMMAND')
		} else {
			os.setenv('VLS_V_COMMAND', old_command, true)
		}
	}
	base := os.join_path(os.temp_dir(), 'vls_wrapper_env_${os.getpid()}')
	bin := os.join_path(base, '.bin')
	interop_test_must_mkdir_all(bin)
	defer {
		os.rmdir_all(base) or {}
	}
	target := os.join_path(base, 'v.exe')
	interop_test_must_write_file(target, '')
	// A real V installation holds vlib next to the compiler; without it the
	// walk-up has no V home to find.
	interop_test_must_mkdir_all(os.join_path(base, 'vlib'))
	wrapper := os.join_path(bin, 'v.bat')
	interop_test_must_write_file(wrapper, '@echo off\n"${target}" %*\n')
	os.setenv('VLS_V_COMMAND', wrapper, true)
	assert resolve_v_compiler_exe() == target
	assert find_v_dir() == os.dir(os.real_path(target))
}

// --- uri_to_path tests ---

fn test_uri_to_path_unix_style() {
	// Standard Unix path
	assert uri_to_path('file:///home/user/project/main.v') == '/home/user/project/main.v'
	assert uri_to_path('file:///tmp/test.v') == '/tmp/test.v'
	assert uri_to_path('file:///root/vls/handlers.v') == '/root/vls/handlers.v'
}

fn test_uri_to_path_windows_style() {
	// Windows path with drive letter
	result := uri_to_path('file:///C:/Users/test/project/main.v')
	// On Unix systems, this should strip the leading slash before the drive letter
	assert result == 'C:/Users/test/project/main.v' || result == '/C:/Users/test/project/main.v'
}

fn test_uri_to_path_with_file_prefix() {
	// Both file:// and file:/// prefixes should work
	result1 := uri_to_path('file:///path/to/file.v')
	result2 := uri_to_path('file://path/to/file.v')
	// file:// removes 7 characters, leaving /path/to/file.v or path/to/file.v
	assert result1.contains('file.v')
	assert result2.contains('file.v')
}

fn test_uri_to_path_no_prefix() {
	// If no file:// prefix, should return as-is
	assert uri_to_path('/home/user/test.v') == '/home/user/test.v'
	assert uri_to_path('relative/path.v') == 'relative/path.v'
}

fn test_uri_to_path_special_characters() {
	// Percent-encoded spaces must be decoded to real spaces (P0-10).
	result := uri_to_path('file:///home/user/my%20project/test.v')
	assert result == '/home/user/my project/test.v'
}

fn test_uri_to_path_percent_encoded_hash_and_percent() {
	// %23 -> '#', %25 -> '%' must round back to the literal characters.
	assert uri_to_path('file:///home/user/a%23b.v') == '/home/user/a#b.v'
	assert uri_to_path('file:///home/user/100%25.v') == '/home/user/100%.v'
}

fn test_uri_to_path_localhost_authority_is_local() {
	// A `localhost` authority denotes the local machine (RFC 8089), so the path
	// must resolve to the local file, not a //localhost/... UNC-style path.
	assert uri_to_path('file://localhost/tmp/main.v') == '/tmp/main.v'
	assert uri_to_path('file://LOCALHOST/tmp/main.v') == '/tmp/main.v'
	// A genuine remote authority is still preserved as a UNC path.
	assert uri_to_path('file://server/share/main.v') == '//server/share/main.v'
}

fn test_uri_to_path_drops_fragment_and_query() {
	assert uri_to_path('file:///home/user/test.v#L10') == '/home/user/test.v'
	assert uri_to_path('file:///home/user/test.v?rev=2') == '/home/user/test.v'
}

fn test_uri_path_roundtrip_with_spaces_and_hash() {
	for original in ['/home/user/my project/a#b.v', '/tmp/weird %name%.v', '/a/plus+file.v'] {
		uri := path_to_uri(original)
		// The URI must not contain a raw space.
		assert !uri.contains(' ')
		assert uri_to_path(uri) == original
	}
}

fn test_path_to_uri_encodes_space() {
	assert path_to_uri('/home/user/my project/a.v') == 'file:///home/user/my%20project/a.v'
}

fn test_uri_to_path_empty_string() {
	result := uri_to_path('')
	assert result == ''
}

fn test_uri_to_path_root() {
	result := uri_to_path('file:///')
	assert result == '/' || result == ''
}

fn test_uri_to_path_nested_deep() {
	result := uri_to_path('file:///a/b/c/d/e/f/g/h/i/j/file.v')
	assert result == '/a/b/c/d/e/f/g/h/i/j/file.v'
}

fn test_uri_to_path_with_dots() {
	result := uri_to_path('file:///path/./to/../file.v')
	assert result == '/path/./to/../file.v'
}

fn test_path_is_within_with_case_accepts_windows_case_differences() {
	assert path_is_within_with_case('c:/repo/src/main.v', 'C:/Repo', true)
	assert path_is_within_with_case('//server/share/FILE.v', '//SERVER/SHARE', true)
	assert !path_is_within_with_case('c:/repository/main.v', 'C:/Repo', true)
	assert !path_is_within_with_case('c:/repo/src/main.v', 'C:/Repo', false)
	relative := path_relative_to_with_case('c:/repo/src/Main.v', 'C:/Repo', true) or {
		assert false, 'expected a relative Windows path'
		return
	}
	assert relative == 'src/Main.v'
}

fn test_normalize_overlay_path_before_windows_containment_checks() {
	path := normalize_overlay_path_with_windows_rules(r'C:\Users\Alex\project\src\main.v', true)
	root := normalize_overlay_path_with_windows_rules(r'c:\users\alex\project', true)
	assert path == 'C:/Users/Alex/project/src/main.v'
	assert root == 'c:/users/alex/project'
	assert path_is_within_with_case(path, root, true)
	relative := path_relative_to_with_case(path, root, true) or {
		assert false, 'expected normalized Windows path to remain inside the project'
		return
	}
	assert relative == 'src/main.v'
}

fn test_normalize_overlay_path_preserves_posix_backslashes() {
	path := r'/tmp/project\name/main.v'
	assert normalize_overlay_path_with_windows_rules(path, false) == path
	$if !windows {
		assert normalize_overlay_path(path) == path
	}
}

fn test_source_path_from_overlay_normalizes_windows_relative_join() {
	overlay := CompilationOverlay{
		source_display_root: r'C:\repo'
		temp_root:           r'C:\temp\overlay'
		temp_work_dir:       r'C:\temp\overlay\src'
	}
	mapped := source_path_from_overlay_with_windows_rules('./main.v', overlay, true, '')
	assert mapped == 'C:/repo/src/main.v'
}

fn test_overlay_relative_path_prefers_nested_symlink_layout() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_overlay_relative_symlink_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	shared_src := os.join_path(temp_dir, 'shared', 'src')
	lexical_src := os.join_path(project_dir, 'src')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(shared_src)
	os.symlink(shared_src, lexical_src) or { return }

	lexical_file := os.join_path(lexical_src, 'main.v')
	relative := overlay_relative_path(lexical_file, project_dir) or {
		assert false, 'expected the lexical source path to remain inside the project'
		return
	}
	assert relative == 'src/main.v'
}

fn test_overlay_path_lists_can_use_windows_case_rules() {
	tracked_paths := ['Src/Main.v']
	assert overlay_path_in_with_case('src/main.v', tracked_paths, true)
	assert overlay_path_has_descendant_with_case('src', tracked_paths, true)
	assert !overlay_path_in_with_case('src/main.v', tracked_paths, false)
	assert !overlay_path_has_descendant_with_case('src', tracked_paths, false)
}

fn test_path_to_uri_keeps_the_authority_of_a_unc_path() {
	// An editor opens a file on a Windows network share as `file://server/...`,
	// and `uri_to_path` already resolves that authority to a `//server/share/...`
	// UNC path. Re-encoding that path must reproduce the same URI, because VLS
	// keys open buffers, the index, and every published diagnostic by URI.
	assert uri_to_path('file://server/share/proj/main.v') == '//server/share/proj/main.v'
	assert path_to_uri('//server/share/proj/main.v') == 'file://server/share/proj/main.v'
	assert path_to_uri(uri_to_path('file://server/share/proj/main.v')) == 'file://server/share/proj/main.v'
	// The share is the authority, not the first path segment: four slashes put it
	// in the path and produce a URI no client will match.
	assert !path_to_uri('//server/share/proj/main.v').starts_with('file:////')
	// Characters that need escaping still are, and the round trip holds.
	assert path_to_uri('//server/share/my project/main.v') == 'file://server/share/my%20project/main.v'
	assert uri_to_path(path_to_uri('//server/share/my project/main.v')) == '//server/share/my project/main.v'
	// A single leading slash stays an ordinary local path, so POSIX paths and
	// Windows drive paths are unaffected.
	assert path_to_uri('/home/user/project/main.v') == 'file:///home/user/project/main.v'
	assert path_to_uri('C:/Users/me/main.v') == 'file:///C:/Users/me/main.v'
}

// --- path_to_uri tests ---

fn test_path_to_uri_unix() {
	result := path_to_uri('/home/user/project/main.v')
	assert result == 'file:///home/user/project/main.v'
}

fn test_path_to_uri_relative() {
	// Relative paths should get file:/// prefix
	result := path_to_uri('project/main.v')
	assert result == 'file:///project/main.v'
}

fn test_path_to_uri_with_backslashes() {
	// On POSIX a backslash is a valid, literal filename character. It must be
	// percent-encoded in the URI (never left raw) and must round-trip exactly.
	// Windows treats the same bytes as path separators and normalizes them.
	original := '/home/user\\project\\main.v'
	result := path_to_uri(original)
	assert !result.contains('\\')
	$if windows {
		assert uri_to_path(result) == original.replace('\\', '/')
	} $else {
		assert uri_to_path(result) == original
	}
}

fn test_path_to_uri_empty() {
	result := path_to_uri('')
	assert result == 'file:///'
}

fn test_path_to_uri_single_file() {
	result := path_to_uri('file.v')
	assert result == 'file:///file.v'
}

fn test_path_to_uri_current_dir() {
	result := path_to_uri('./file.v')
	assert result.contains('file.v')
}

fn test_path_to_uri_parent_dir() {
	result := path_to_uri('../file.v')
	assert result.contains('file.v')
}

fn test_compiler_location_reuses_equivalent_open_uri() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_compiler_location_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	path := os.join_path(temp_dir, 'main.v')
	interop_test_must_write_file(path, 'aaaa target\n')
	canonical_uri := path_to_uri(path)
	open_uri := canonical_uri.replace_once('file:///', 'file://localhost/')
	mut app := &App{
		open_files:        map[string]string{}
		position_encoding: .utf16
	}
	app.open_files[open_uri] = '🚀 target\n'

	location := app.compiler_location(path, 0, 5)

	assert location.uri == open_uri
	assert location.range.start.char == 3
	assert location.range.end.char == 3

	app.position_encoding = .utf32
	location_utf32 := app.compiler_location(path, 0, 5)
	assert location_utf32.uri == open_uri
	assert location_utf32.range.start.char == 2
}

// --- Round-trip conversion tests ---

fn test_path_uri_roundtrip() {
	// Test roundtrip conversion
	original := '/home/user/project/test.v'
	uri := path_to_uri(original)
	back := uri_to_path(uri)
	assert back == original
}

fn test_path_uri_roundtrip_multiple() {
	paths := [
		'/home/user/test.v',
		'/tmp/file.v',
		'/root/vls/main.v',
		'/a/b/c/d.v',
	]

	for path in paths {
		uri := path_to_uri(path)
		back := uri_to_path(uri)
		assert back == path
	}
}

fn test_make_singlefile_temp_path_uses_given_root() {
	temp_root := os.join_path(os.temp_dir(), 'vls_interop_temp_root')
	path := make_singlefile_temp_path(temp_root, '/tmp/example.v', 'check')
	assert path.starts_with(temp_root)
	assert path.ends_with('.v')
	assert path.contains('vls_check_')
}

fn test_make_singlefile_temp_path_has_unique_tag_for_purpose() {
	root := os.temp_dir()
	path_a := make_singlefile_temp_path(root, '/tmp/example.v', 'lineinfo')
	path_b := make_singlefile_temp_path(root, '/tmp/example.v', 'check')
	assert path_a != path_b
}

fn test_make_singlefile_temp_path_avoids_test_suffix_regression() {
	root := os.temp_dir()
	path := make_singlefile_temp_path(root, '/tmp/test.v', 'check')
	assert !path.ends_with('_test.v')
	assert path.ends_with('.v')
}

fn test_cleanup_compilation_temp_removes_singlefile_path() {
	tmppath := os.join_path(os.temp_dir(), 'vls_cleanup_single_${os.getpid()}_${time.now().unix_nano()}.v')
	interop_test_must_write_file(tmppath, 'module main\n')
	assert os.exists(tmppath)
	cleanup_compilation_temp('', tmppath)
	assert !os.exists(tmppath)
}

fn test_cleanup_compilation_temp_removes_project_dir() {
	project_dir := os.join_path(os.temp_dir(), 'vls_cleanup_project_${os.getpid()}_${time.now().unix_nano()}')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_write_file(os.join_path(project_dir, 'main.v'), 'module main\n')
	assert os.exists(project_dir)
	cleanup_compilation_temp(project_dir, '')
	assert !os.exists(project_dir)
}

// Compiler invocation is now argv-based (no shell). These tests assert that
// filenames — including ones containing shell metacharacters — are passed as
// single, literal argument-vector elements, so command injection is impossible.

fn test_build_v_check_args_single_passes_path_literally() {
	args := build_v_check_args_single('/tmp/a b/test.v', false)
	mut expected := v3_compiler_selection_args()
	expected << ['-check', '-nocolor', '/tmp/a b/test.v']
	assert args == expected
	assert '-vls-mode' !in args
	assert '-json-errors' !in args
	// At the pinned V3 revision `-w` hides warnings; omission preserves them.
	assert '-w' !in args
	$if macos || linux {
		assert '-new-compiler' in args
	} $else {
		assert '-new-compiler' !in args
	}
}

fn test_build_v_check_args_multifile_uses_v3_compatible_flags() {
	args := build_v_check_args_multifile(false)
	mut expected := v3_compiler_selection_args()
	expected << ['-check', '-nocolor', '.']
	assert args == expected
	assert '-vls-mode' !in args
	assert '-json-errors' !in args
	// V3 reports warnings by default, while `-w` requests compatibility suppression.
	assert '-w' !in args
	$if macos || linux {
		assert '-new-compiler' in args
	} $else {
		assert '-new-compiler' !in args
	}
}

fn test_build_v_check_args_use_shared_for_library_modules() {
	single_args := build_v_check_args_single('/tmp/library.v', true)
	mut expected_single := v3_compiler_selection_args()
	expected_single << ['-shared', '-check', '-nocolor', '/tmp/library.v']
	assert single_args == expected_single

	multifile_args := build_v_check_args_multifile(true)
	mut expected_multifile := v3_compiler_selection_args()
	expected_multifile << ['-shared', '-check', '-nocolor', '.']
	assert multifile_args == expected_multifile
}

fn test_build_v_check_args_single_no_shell_injection() {
	// A path containing command substitution must remain one literal argv element.
	malicious := '/tmp/\$(touch /tmp/pwned)/x.v'
	args := build_v_check_args_single(malicious, false)
	assert malicious in args
	// The dangerous text is never split or interpreted; it is exactly one element.
	mut count := 0
	for a in args {
		if a == malicious {
			count++
		}
	}
	assert count == 1
}

fn test_build_v_fmt_args_passes_temp_file_literally() {
	args := build_v_fmt_args('/tmp/fmt file.v')
	assert args == ['fmt', '-inprocess', '-w', '/tmp/fmt file.v']
}

fn test_build_v_run_args_targets_containing_module() {
	assert build_v_run_args() == ['-nocolor', 'run', '.']
	assert build_v_run_compile_args('/tmp/code lens program') == [
		'-nocolor',
		'-o',
		'/tmp/code lens program',
		'.',
	]
}

fn test_build_v_test_args_selects_one_test_without_a_shell() {
	file_path := '/tmp/file with spaces_test.v'
	args := build_v_test_args(file_path, 'test_one')
	assert args == ['-nocolor', 'test', file_path, '-run-only', 'test_one']
	assert build_v_test_args(file_path, '') == ['-nocolor', 'test', file_path]
	assert build_v_test_compile_args(file_path, 'test_one', '/tmp/test program') == [
		'-nocolor',
		'-skip-running',
		'-o',
		'/tmp/test program',
		file_path,
		'-run-only',
		'test_one',
	]
}

fn test_build_v_line_info_args_single_embeds_line_info() {
	args := build_v_line_info_args_single('/tmp/a.v', '10:gd^5', '/tmp/a.v')
	assert '/tmp/a.v:10:gd^5' in args
	assert '-line-info' in args
	assert '-json-errors' !in args
	assert '-vls-mode' in args
}

fn test_compiler_rejects_line_info_detects_a_v_without_the_v1_checker() {
	// V prints exactly this and exits before doing any work.
	assert compiler_rejects_line_info('unknown option `-vls-mode`')
	assert compiler_rejects_line_info('unknown option `-line-info`')
	assert compiler_rejects_line_info('unknown option `-json-errors`')
	// A compiler that understands the options answers with its payload instead.
	assert !compiler_rejects_line_info('{"contents":{"kind":"markdown","value":"fn f()"}}')
	assert !compiler_rejects_line_info('')
	assert !compiler_rejects_line_info('unknown option `-nosuch`')
	// A refusal is only recognized as a whole line, so a diagnostic that merely
	// quotes the message cannot disable compiler-backed lookups for the session.
	assert !compiler_rejects_line_info('a.v:1:1: error: unknown option `-vls-mode` in flag list')
	assert compiler_rejects_any_option('unknown option `-old-compiler`', [
		'-old-compiler',
	])
	assert !compiler_rejects_any_option('unknown option `-vls-mode`', ['-old-compiler'])
}

fn test_compiler_refused_and_stopped_separates_a_dead_end_from_a_recovery() {
	// A launcher with no answer prints its refusal and exits.
	assert compiler_refused_and_stopped('unknown option `-vls-mode`')
	assert compiler_refused_and_stopped('unknown option `-vls-mode`\n\n')
	// One that reruns the request against a compatibility compiler says more,
	// even when that rerun finds nothing to report.
	assert !compiler_refused_and_stopped('unknown option `-vls-mode`\nV compilation failed (compiler_error); retrying with `/v1_fallback`.')
	assert !compiler_refused_and_stopped('unknown option `-vls-mode`\nV compilation failed (compiler_error); retrying with `/v1_fallback`.\n./main.v:3:7')
	// An invocation that was never refused is not a dead end either.
	assert !compiler_refused_and_stopped('')
	assert !compiler_refused_and_stopped('./main.v:3:7')
}

fn test_compiler_lacks_compatibility_compiler_detects_every_launcher_refusal() {
	// These are the single-line refusals `ensure_v1_fallback` prints in the V
	// launcher, verbatim. None of them is an "unknown option" line, so before
	// this was recognized VLS never retired the lookups and never said anything.
	assert compiler_lacks_compatibility_compiler('`-vls-mode` requires the compatibility compiler, but no usable V 0.5.2 fallback was found and make is unavailable. Install make, then run `make v1` in `C:\\Users\\me\\v`.')
	// vlang/v#29369 rewrote the tail of that refusal: the hint after "make is
	// unavailable" is now platform specific, and the sentence is split. Detection
	// keys on "requires the compatibility compiler", so both spellings must retire
	// the lookups, and this test has to hold either side of that change.
	assert compiler_lacks_compatibility_compiler('`-vls-mode` requires the compatibility compiler, but no usable V 0.5.2 fallback was found and make is unavailable. On Windows, install GNU make in MSYS2 (`make` or `mingw32-make`) and put its tools, including `sh`, on PATH. Then run `make v1` in `C:\\Users\\me\\v`.')
	assert compiler_lacks_compatibility_compiler('`-vls-mode` requires the compatibility compiler, but the V source tree could not be found. Run `make v1` in the V source directory.')
	assert compiler_lacks_compatibility_compiler('`-old-compiler` was requested, but no usable V 0.5.2 fallback was found and make is unavailable. Install make, then run `make v1` in `/home/me/v`.')
	// The same rewrite as above, on the host where the hint is the short one.
	assert compiler_lacks_compatibility_compiler('`-old-compiler` was requested, but no usable V 0.5.2 fallback was found and make is unavailable. Install make. Then run `make v1` in `/home/me/v`.')
	assert compiler_lacks_compatibility_compiler('`make v1` failed with exit code 2. Run it manually in `/home/me/v` for more details.')
	assert compiler_lacks_compatibility_compiler('`make v1` completed without installing a usable V 0.5.2 fallback at `/home/me/.cache/v1_fallback`.')
	// A launcher that recovers on its own only announces the fallback before
	// rerunning, then answers. Retiring the lookups on that would cost the
	// session every compiler-backed hover, signature, and receiver definition.
	assert !compiler_lacks_compatibility_compiler('unknown option `-vls-mode`')
	assert !compiler_lacks_compatibility_compiler('unknown option `-vls-mode`\nV compilation failed (compiler_error); retrying with `/v1_fallback`.')
	assert !compiler_lacks_compatibility_compiler('`-vls-mode` requires the compatibility compiler, but no usable V 0.5.2 fallback was found; running `make v1` now...\n{"contents":{"kind":"markdown","value":"fn f()"}}')
	assert !compiler_lacks_compatibility_compiler('`-old-compiler` was requested; retrying with `/v1_fallback`.\n{"contents":{"kind":"markdown","value":"fn f()"}}')
	// Starting an automatic fallback build does not mean that it succeeds.
	building := '`-vls-mode` requires the compatibility compiler, but no usable V 0.5.2 fallback was found; running `make v1` now...\n'
	assert compiler_lacks_compatibility_compiler(building + '`make v1` failed with exit code 2. Run it manually in `/v` for more details.')
	assert compiler_lacks_compatibility_compiler(building + '`make v1` completed without installing a usable V 0.5.2 fallback at `/v1_fallback`.')
	// A working compiler's payload, an ordinary diagnostic, and empty output.
	assert !compiler_lacks_compatibility_compiler('{"contents":{"kind":"markdown","value":"fn f()"}}')
	assert !compiler_lacks_compatibility_compiler('./main.v:3:7: error: unknown option')
	assert !compiler_lacks_compatibility_compiler('')
}

// A launcher that understands `-vls-mode` but cannot reach the compatibility
// compiler that implements it, and stops there. Its refusal is not an "unknown
// option" line, which is what made it invisible to the dead-end check.
const no_compat_compiler_launcher_stub = r'#!/bin/sh
echo "\`-vls-mode\` requires the compatibility compiler, but no usable V 0.5.2 fallback was found and make is unavailable. Install make, then run \`make v1\` in \`/v\`." >&2
exit 1
'

fn test_run_v_line_info_retires_lookups_when_the_compatibility_compiler_is_missing() {
	$if windows {
		// The stand-in launcher is a POSIX shell script.
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_no_compat_compiler', no_compat_compiler_launcher_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}

	assert app.run_v_line_info(.hover, uri, '6:hv^4') == ResponseResult('null')
	assert app.line_info_mode == .missing
}

const explicit_compatibility_launcher_stub = r'#!/bin/sh
for arg in "$@"; do
	if [ "$arg" = "-old-compiler" ]; then
		echo "\`-old-compiler\` was requested; retrying with \`/v1_fallback\`." >&2
		echo "{\"contents\":{\"kind\":\"markdown\",\"value\":\"fn helper()\"}}"
		exit 0
	fi
done
echo "unknown option \`-vls-mode\`" >&2
exit 1
'

fn test_run_v_line_info_keeps_successful_explicit_compatibility_retry() {
	$if windows {
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_explicit_compatibility', explicit_compatibility_launcher_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}
	app.capture_output = true

	// An explicit compatibility retry carries a notice before the valid payload.
	for _ in 0 .. 2 {
		hover := app.run_v_line_info(.hover, uri, '6:hv^4')
		assert app.line_info_mode == .compat
		assert hover is Hover
		if hover is Hover {
			assert hover.contents.value.contains('fn helper()')
		}
	}
	assert app.captured_output.len == 0
}

const failed_compatibility_build_launcher_stub = r'#!/bin/sh
echo "\`-vls-mode\` requires the compatibility compiler, but no usable V 0.5.2 fallback was found; running \`make v1\` now..." >&2
echo "\`make v1\` failed with exit code 2. Run it manually in \`/v\` for more details." >&2
exit 1
'

fn test_run_v_line_info_retires_lookups_after_automatic_compatibility_build_fails() {
	$if windows {
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_failed_compatibility_build', failed_compatibility_build_launcher_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}
	app.capture_output = true

	for _ in 0 .. 2 {
		result := app.run_v_line_info(.hover, uri, '6:hv^4')
		assert result == ResponseResult('null')
		assert app.line_info_mode == .missing
	}
	assert app.captured_output.len == 1
	assert app.captured_output[0].contains('window/showMessage')
}

fn test_report_missing_compatibility_compiler_names_the_repair() {
	// The editor otherwise shows a VLS that highlights code but answers nothing
	// for completion, hover, signature help, or go to definition, with no hint
	// that the compiler is the reason. Platform-independent: no stub compiler.
	mut app := App{
		capture_output: true
	}
	app.report_missing_compatibility_compiler()
	assert app.captured_output.len == 1
	assert app.captured_output[0].contains('window/showMessage')
	// Name the actual repair, not just the symptom.
	assert app.captured_output[0].contains('make v1')
	assert app.captured_output[0].contains('VLS_V_COMMAND')
	assert app.captured_output[0].contains('type":2')
}

fn test_a_retired_lookup_never_reports_the_missing_compiler_again() {
	// Once the lookups are retired, `run_v_line_info` answers from the index at
	// its early `.missing` check, so it never spawns the compiler and never
	// re-reports. That structural guarantee is why the notice needs no
	// "already warned" flag.
	previous := os.getenv('VLS_V_COMMAND')
	mut app := App{
		capture_output: true
		line_info_mode: .missing
		open_files:     map[string]string{}
	}
	uri := 'file:///tmp/vls_retired_lookup.v'
	app.open_files[uri] = 'module main\n\n// greet writes a greeting.\nfn greet() {}\n\nfn main() {\n\tgreet()\n}\n'
	// A compiler that cannot be spawned at all: reaching it would fail loudly.
	os.setenv('VLS_V_COMMAND', os.join_path(os.temp_dir(), 'vls_no_such_compiler'), true)
	defer {
		restore_v_command(previous)
	}

	hover := app.run_v_line_info(.hover, uri, '7:hv^1')
	// Answered from the index, from the document's own vdoc comment.
	assert hover is Hover
	if hover is Hover {
		assert hover.contents.value.contains('greet writes a greeting.')
	}
	// Nothing was said to the client, and no compiler was launched.
	assert app.captured_output.len == 0
	assert app.line_info_mode == .missing
}

// line_info_stub_app writes `script` as an executable stand-in for `v`, points
// VLS_V_COMMAND at it, and returns an App plus the URI of a lone source file.
// The source sits in its own directory so the request takes the single-file
// path, and scratch files land elsewhere so they never become its siblings.
fn line_info_stub_app(name string, script string) (&App, string, string) {
	root := os.join_path(os.temp_dir(), '${name}_${os.getpid()}_${time.now().unix_nano()}')
	source_dir := os.join_path(root, 'src')
	interop_test_must_mkdir_all(os.join_path(root, 'bin'))
	interop_test_must_mkdir_all(source_dir)
	interop_test_must_mkdir_all(os.join_path(root, 'work'))
	stub := os.join_path(root, 'bin', 'v')
	interop_test_must_write_file(stub, script)
	os.chmod(stub, 0o755) or { assert false, 'Failed to chmod ${stub}: ${err}' }
	os.setenv('VLS_V_COMMAND', stub, true)
	source_file := os.join_path(source_dir, 'main.v')
	interop_test_must_write_file(source_file, 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n')
	mut app := &App{
		temp_dir: os.join_path(root, 'work')
	}
	return app, path_to_uri(source_file), root
}

fn restore_v_command(previous string) {
	if previous == '' {
		os.unsetenv('VLS_V_COMMAND')
	} else {
		os.setenv('VLS_V_COMMAND', previous, true)
	}
}

// A launcher with no in-tree `-line-info` checker that refuses the
// `-old-compiler` selector but reruns the request against a compatibility
// compiler on its own. The refusal is on every invocation, so an empty answer
// through it must not be read as "nothing here can serve line info".
const recovering_launcher_stub = r'#!/bin/sh
for arg in "$@"; do
	if [ "$arg" = "-old-compiler" ]; then
		echo "unknown option \`-old-compiler\`" >&2
		exit 1
	fi
done
echo "unknown option \`-vls-mode\`" >&2
echo "V compilation failed (compiler_error); retrying with \`/v1_fallback\`." >&2
case " $* " in
	*hv^4*) echo "{\"contents\":{\"kind\":\"markdown\",\"value\":\"fn helper()\"}}" ;;
esac
'

// A launcher that refuses both the options and the selector, and stops there.
const dead_end_launcher_stub = r'#!/bin/sh
for arg in "$@"; do
	if [ "$arg" = "-old-compiler" ]; then
		echo "unknown option \`-old-compiler\`" >&2
		exit 1
	fi
done
echo "unknown option \`-vls-mode\`" >&2
exit 1
'

fn test_run_v_line_info_keeps_a_recovering_launcher_after_an_empty_lookup() {
	// Regression: an empty lookup used to be read together with the launcher's
	// standing refusal as proof that nothing serves `-line-info`, retiring
	// compiler-backed hover, signature help, and receiver definitions for the
	// rest of the session (PR #516 review, discussion_r3998999227).
	$if windows {
		// The stand-in launcher is a POSIX shell script.
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_recovering_launcher', recovering_launcher_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}

	// A hover past the end of the file resolves nothing, which is an ordinary
	// answer and not a reason to stop asking.
	assert app.run_v_line_info(.hover, uri, '9:hv^1') == ResponseResult('null')
	assert app.line_info_mode == .direct

	// So the very next hover still reaches the launcher.
	hover := app.run_v_line_info(.hover, uri, '6:hv^4')
	assert app.line_info_mode == .direct
	assert hover is Hover
	if hover is Hover {
		assert hover.contents.value.contains('fn helper()')
	}
}

fn test_run_v_line_info_retires_lookups_when_the_launcher_only_refuses() {
	// The other direction: a launcher that refuses and stops really has no
	// answer, so the session stops spawning a process per request.
	$if windows {
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_dead_end_launcher', dead_end_launcher_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}

	assert app.run_v_line_info(.hover, uri, '6:hv^4') == ResponseResult('null')
	assert app.line_info_mode == .missing
}

fn test_with_line_info_selection_only_asks_for_the_compatibility_compiler_when_needed() {
	base := build_v_line_info_args_single('/tmp/a.v', '10:gd^5', '/tmp/a.v')
	mut app := App{}
	// Unprobed and known-direct compilers are driven without a selection flag, so
	// V releases that predate `-old-compiler` never see it.
	assert app.line_info_mode == .unknown
	assert app.with_line_info_selection(base) == base
	app.line_info_mode = .direct
	assert app.with_line_info_selection(base) == base
	app.line_info_mode = .compat
	selected := app.with_line_info_selection(base)
	assert selected[0] == '-old-compiler'
	assert selected[1..] == base
}

fn test_line_info_unavailable_result_answers_hover_from_the_index() {
	// When no compiler can serve `-line-info`, hover still resolves the vdoc
	// comment, completion returns an augmentable empty list, and the remaining
	// methods report "nothing found" rather than an empty popup.
	mut app := App{}
	uri := 'file:///tmp/vls_line_info_unavailable.v'
	app.open_files[uri] = 'module main\n\n// greet writes a greeting.\nfn greet() {}\n\nfn main() {\n\tgreet()\n}\n'

	hover := app.line_info_unavailable_result(.hover, uri, '7:hv^1')
	assert hover is Hover
	if hover is Hover {
		assert hover.contents.value.contains('greet writes a greeting.')
	}
	// A cursor that is not on a symbol has no documentation to report.
	assert app.line_info_unavailable_result(.hover, uri, '5:hv^0') == ResponseResult('null')

	completion := app.line_info_unavailable_result(.completion, uri, '7:1')
	assert completion is []Detail
	if completion is []Detail {
		assert completion.len == 0
	}

	assert app.line_info_unavailable_result(.signature_help, uri, '7:fn^6') == ResponseResult('null')
	assert app.line_info_unavailable_result(.definition, uri, '7:gd^1') == ResponseResult('null')
}

fn test_normalize_v_line_info_output_ignores_launcher_notices() {
	signature := 'unknown option `-vls-mode`\n{"signatures":[],"activeSignature":0}'
	assert normalize_v_line_info_output(signature, .signature_help) == '{"signatures":[],"activeSignature":0}'
	definition := 'unknown option `-vls-mode`\n./main.v:3:7\n'
	assert normalize_v_line_info_output(definition, .definition) == './main.v:3:7'
	assert normalize_v_line_info_output('unknown option `-vls-mode`', .definition) == ''
}

fn test_parse_v_check_diagnostics_reads_v3_output() {
	output := '/tmp/main.v:4:7: error: undefined variable: `missing_name`
    2 |
    3 | fn main() {
    4 |     x := missing_name
      |          ~~~~~~~~~~~~
    5 | }
/tmp/main.v:8:3: warning: unused variable `value`
    8 |   value := 1
      |   ~~~~~
'
	diagnostics := parse_v_check_diagnostics(output, '')
	assert diagnostics.len == 2
	assert diagnostics[0] == JsonError{
		path:    '/tmp/main.v'
		message: 'undefined variable: `missing_name`'
		line_nr: 4
		col:     7
		len:     12
		level:   'error'
	}
	assert diagnostics[1].level == 'warning'
	assert diagnostics[1].line_nr == 8
	assert diagnostics[1].col == 3
	assert diagnostics[1].len == 5
}

fn test_parse_v_check_program_diagnostics_places_errors_without_a_position() {
	// Some errors are about the program rather than a place in it, as a module
	// imported under a name its files do not declare. V prints them without a
	// position; they are shown where they point: at the import and at the module
	// declaration of the files they name, else in the file that was checked.
	dir := os.join_path(os.vtmp_dir(), 'vls_program_errors_${os.getpid()}')
	os.rmdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	interop_test_must_mkdir_all(os.join_path(dir, 'lib'))
	interop_test_must_write_file(os.join_path(dir, 'main.v'), 'module main\n\nimport lib\n\nfn main() {\n\tprintln(lib.valor())\n}\n')
	interop_test_must_write_file(os.join_path(dir, 'lib', 'lib.v'), 'module otro\n\npub fn valor() int {\n\treturn 1\n}\n')
	bad_module := 'bad module definition: ./main.v imports module "lib" but ./lib/lib.v is defined as module `otro`'
	output := 'error: ${bad_module}\nbuilder error: redefinition of function `main`\n'
	got := parse_v_check_program_diagnostics(output, dir, os.join_path(dir, 'main.v')).map('${os.file_name(it.path)}:${it.line_nr}:${it.col}:${it.len} ${it.level}: ${it.message}')
	assert got == [
		'main.v:3:1:10 error: ${bad_module}', // `import lib`
		'lib.v:1:1:11 error: ${bad_module}', // `module otro`
		'main.v:5:1:11 error: redefinition of function `main`', // `fn main() {`, the checked file
	], got.str()
}

fn test_a_redefinition_is_shown_on_each_declaration_it_names() {
	// V says without a position that a function is declared twice, then where
	// each declaration is: each one gets the error, and the line without a
	// position is not placed again on its own.
	output := 'builder error: redefinition of function `other`
/tmp/main.v:3:1: conflicting declaration: fn other(n int) int
    3 | fn other(n int) int {
      | ~~~~~~~~~~~~~~~~~~~
/tmp/main.v:7:1: conflicting declaration: fn other(n int) int
    7 | fn other(n int) int {
      | ~~~~~~~~~~~~~~~~~~~
'
	got := parse_v_check_diagnostics(output, '').map('${it.line_nr}:${it.col}:${it.len} ${it.level}: ${it.message}')
	assert got == ['3:1:19 error: redefinition of function `other`',
		'7:1:19 error: redefinition of function `other`'], got.str()
	assert parse_v_check_program_diagnostics(output, '/tmp', '/tmp/main.v') == []
}

fn test_parse_v_check_diagnostics_maps_v3_builder_error_to_error() {
	output := '/tmp/main.v:3:1: builder error: cannot import module "missing" (not found)
    3 | import missing
      | ~~~~~~~~~~~~~~
'
	diagnostics := parse_v_check_diagnostics(output, '')
	assert diagnostics == [JsonError{
		path:    '/tmp/main.v'
		message: 'cannot import module "missing" (not found)'
		line_nr: 3
		col:     1
		len:     14
		level:   'error'
	}]
}

fn test_parse_v_check_diagnostics_preserves_windows_drive_path() {
	header := r'C:\work\project\main.v:12:9: notice: deprecated declaration'
	diagnostics := parse_v_check_diagnostics(header, '')
	assert diagnostics.len == 1
	assert diagnostics[0].path == r'C:\work\project\main.v'
	assert diagnostics[0].line_nr == 12
	assert diagnostics[0].col == 9
	assert diagnostics[0].level == 'notice'
}

fn test_parse_v_check_diagnostics_preserves_severity_marker_in_posix_path() {
	header := '/tmp/project: error: fixtures/main.v:12:9: error: unknown identifier'
	diagnostics := parse_v_check_diagnostics(header, '')
	assert diagnostics.len == 1
	assert diagnostics[0].path == '/tmp/project: error: fixtures/main.v'
	assert diagnostics[0].message == 'unknown identifier'
	assert diagnostics[0].line_nr == 12
	assert diagnostics[0].col == 9
	assert diagnostics[0].level == 'error'
}

fn test_parse_v_check_diagnostics_chooses_rightmost_marker_across_severities() {
	header := '/tmp/foo:1:2: error: dir/main.v:12:9: warning: unused variable'
	diagnostics := parse_v_check_diagnostics(header, '')
	assert diagnostics.len == 1
	assert diagnostics[0].path == '/tmp/foo:1:2: error: dir/main.v'
	assert diagnostics[0].message == 'unused variable'
	assert diagnostics[0].line_nr == 12
	assert diagnostics[0].col == 9
	assert diagnostics[0].level == 'warning'
}

fn test_parse_v_check_diagnostics_preserves_severity_marker_in_message() {
	header := '/tmp/main.v:1:1: error: failed: error: detail'
	diagnostics := parse_v_check_diagnostics(header, '')
	assert diagnostics.len == 1
	assert diagnostics[0].path == '/tmp/main.v'
	assert diagnostics[0].message == 'failed: error: detail'
	assert diagnostics[0].line_nr == 1
	assert diagnostics[0].col == 1
	assert diagnostics[0].level == 'error'
}

fn test_parse_v_check_diagnostics_rejects_header_marker_in_message() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_diagnostic_source_${os.getpid()}_${time.now().unix_nano()}')
	interop_test_must_mkdir_all(temp_dir)
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	source_path := os.join_path(temp_dir, 'main.v')
	interop_test_must_write_file(source_path, 'module main\n')
	header := '${source_path}:1:1: error: failed at foo.v:2:3: warning: detail'
	diagnostics := parse_v_check_diagnostics(header, temp_dir)
	assert diagnostics.len == 1
	assert diagnostics[0].path == source_path
	assert diagnostics[0].message == 'failed at foo.v:2:3: warning: detail'
	assert diagnostics[0].line_nr == 1
	assert diagnostics[0].col == 1
	assert diagnostics[0].level == 'error'
}

fn test_parse_v_check_diagnostics_ignores_non_diagnostic_output() {
	output := 'V3 compatibility fallback disabled; requested reason: compiler_error
Use `v help build` for more information.
'
	assert parse_v_check_diagnostics(output, '').len == 0
}

fn test_cache_v_check_result_retries_failure_without_diagnostics() {
	mut app := App{}
	path := 'file:///tmp/main.v'
	app.diag_cache[path] = DiagCacheEntry{
		fingerprint: 'fp'
		errors:      []
	}
	app.cache_v_check_result(path, '', 'fp2', [], compiler_exit_timeout, 0)
	assert path !in app.diag_cache
}

fn test_cache_v_check_result_retries_timeout_with_partial_diagnostics() {
	mut app := App{}
	path := 'file:///tmp/main.v'
	app.diag_cache[path] = DiagCacheEntry{
		fingerprint: 'fp'
		errors:      []
	}
	partial_errors := [
		JsonError{
			path:    '/tmp/main.v'
			message: 'partial compiler output'
			line_nr: 1
			col:     1
			level:   'error'
		},
	]
	app.cache_v_check_result(path, '', 'fp2', partial_errors, compiler_exit_timeout, partial_errors.len)
	assert path !in app.diag_cache
}

fn test_cache_v_check_result_keeps_valid_clean_and_diagnostic_results() {
	mut app := App{}
	path := 'file:///tmp/main.v'
	app.cache_v_check_result(path, '', 'fp1', [], 0, 0)
	assert path in app.diag_cache
	assert app.diag_cache[path].errors.len == 0

	app.cache_v_check_result(path, '', 'fp2', [], 1, 1)
	assert path in app.diag_cache
	assert app.diag_cache[path].fingerprint == 'fp2'
}

// with_temp_diag_cache_dir points VLS_DIAG_CACHE_DIR at a fresh temp folder.
fn with_temp_diag_cache_dir(tag string) string {
	dir := os.join_path(os.temp_dir(), 'vls_diagcache_${tag}_${os.getpid()}_${time.now().unix_nano()}')
	interop_test_must_mkdir_all(dir)
	previous := os.getenv('VLS_DIAG_CACHE_DIR')
	os.setenv('VLS_DIAG_CACHE_DIR', dir, true)
	return previous
}

fn restore_diag_cache_dir(previous string) {
	if previous == '' {
		os.unsetenv('VLS_DIAG_CACHE_DIR')
	} else {
		os.setenv('VLS_DIAG_CACHE_DIR', previous, true)
	}
}

fn test_program_content_fingerprint_tracks_buffers_and_siblings() {
	root := os.join_path(os.temp_dir(), 'vls_fp_${os.getpid()}_${time.now().unix_nano()}')
	interop_test_must_mkdir_all(root)
	main_file := os.join_path(root, 'main.v')
	other_file := os.join_path(root, 'other.v')
	interop_test_must_write_file(main_file, 'module main\n\nfn main() {}\n')
	interop_test_must_write_file(other_file, 'module main\n\nfn helper() {}\n')
	main_uri := path_to_uri(main_file)
	app := App{
		open_files: {
			main_uri: 'module main\n\nfn main() {}\n'
		}
	}
	// Deterministic for an unchanged state, buffers included.
	before := app.program_content_fingerprint(root)
	assert before == app.program_content_fingerprint(root)
	// An unsaved buffer change alters it without touching disk.
	mut changed := App{
		open_files: {
			main_uri: 'module main\n\nfn main() {\n\tprintln(1)\n}\n'
		}
	}
	assert changed.program_content_fingerprint(root) != before
	// So does a sibling changing on disk.
	interop_test_must_write_file(other_file, 'module main\n\nfn helper() int {\n\treturn 2\n}\n')
	assert app.program_content_fingerprint(root) != before
	os.rmdir_all(root) or {}
}

fn test_diag_disk_cache_round_trip_and_rejections() {
	previous := with_temp_diag_cache_dir('roundtrip')
	defer {
		restore_diag_cache_dir(previous)
	}
	root := os.join_path(os.temp_dir(), 'vls_dc_${os.getpid()}_${time.now().unix_nano()}')
	interop_test_must_mkdir_all(root)
	entry := DiagCacheEntry{
		fingerprint: 'fp1'
		errors:      [
			JsonError{
				path:    os.join_path(root, 'main.v')
				message: 'seeded error'
				line_nr: 2
				col:     3
				len:     4
				level:   'error'
			},
		]
	}
	save_diag_disk_entry(root, 'file:///main.v', entry)
	loaded := load_diag_disk_cache(root)
	assert loaded['file:///main.v'].fingerprint == 'fp1'
	assert loaded['file:///main.v'].errors.len == 1
	assert loaded['file:///main.v'].errors[0].message == 'seeded error'
	assert loaded['file:///main.v'].errors[0].line_nr == 2
	// Unreadable content is dropped, not fatal.
	os.write_file(diag_cache_file(root), 'not json') or { panic(err) }
	assert load_diag_disk_cache(root).len == 0
	// Results written by another compiler are dropped.
	save_diag_disk_entry(root, 'file:///main.v', entry)
	previous_command := os.getenv('VLS_V_COMMAND')
	os.setenv('VLS_V_COMMAND', os.join_path(root, 'no-such-compiler'), true)
	assert load_diag_disk_cache(root).len == 0
	restore_v_command(previous_command)
	os.rmdir_all(root) or {}
}

fn test_diag_disk_cache_serves_a_later_session() {
	previous := with_temp_diag_cache_dir('twosession')
	defer {
		restore_diag_cache_dir(previous)
	}
	root := os.join_path(os.temp_dir(), 'vls_2sess_${os.getpid()}_${time.now().unix_nano()}')
	interop_test_must_mkdir_all(root)
	source := os.join_path(root, 'main.v')
	content := 'module main\n\nfn main() {}\n'
	interop_test_must_write_file(source, content)
	uri := path_to_uri(source)
	// First session: compute the fingerprint exactly as run_v_check does and
	// store a result on disk.
	mut first := &App{
		open_files: {
			uri: content
		}
	}
	real_path := uri_to_path(uri)
	program_dir := first.program_root(real_path)
	fingerprint := compiler_fingerprint() + '\n' +
		first.program_content_fingerprint(program_overlay_root(real_path, program_dir))
	entry := DiagCacheEntry{
		fingerprint: fingerprint
		errors:      [
			JsonError{
				path:    real_path
				message: 'persisted diagnostic'
				line_nr: 1
				col:     1
				level:   'error'
			},
		]
	}
	save_diag_disk_entry(program_dir, uri, entry)
	// Second session: a fresh App must merge and match the same fingerprint.
	mut second := &App{
		open_files: {
			uri: content
		}
	}
	second.ensure_diag_disk_cache(second.program_root(real_path))
	assert uri in second.diag_cache, 'disk results did not merge'
	refingerprint := compiler_fingerprint() + '\n' +
		second.program_content_fingerprint(program_overlay_root(real_path,
			second.program_root(real_path)))
	assert second.diag_cache[uri].fingerprint == refingerprint, 'fingerprint moved between sessions'
	assert second.diag_cache[uri].errors[0].message == 'persisted diagnostic'
	os.rmdir_all(root) or {}
}

fn test_run_v_check_returns_cached_result_without_compiler() {
	previous_cache := with_temp_diag_cache_dir('hit')
	previous_command := os.getenv('VLS_V_COMMAND')
	defer {
		restore_diag_cache_dir(previous_cache)
		restore_v_command(previous_command)
	}
	root := os.join_path(os.temp_dir(), 'vls_hit_${os.getpid()}_${time.now().unix_nano()}')
	work := os.join_path(root, 'work')
	interop_test_must_mkdir_all(work)
	os.setenv('VLS_V_COMMAND', os.join_path(root, 'no-such-compiler'), true)
	source := os.join_path(root, 'main.v')
	content := 'module main\n\nfn main() {}\n'
	interop_test_must_write_file(source, content)
	uri := path_to_uri(source)
	mut app := &App{
		temp_dir:   work
		open_files: {
			uri: content
		}
	}
	// Seed exactly the state run_v_check will compute: with a compiler
	// that does not exist, only a fingerprint hit can answer.
	real_path := uri_to_path(uri)
	program_dir := app.program_root(real_path)
	fingerprint := compiler_fingerprint() + '\n' +
		app.program_content_fingerprint(program_overlay_root(real_path, program_dir))
	cached_errors := [
		JsonError{
			path:    real_path
			message: 'seeded diagnostic'
			line_nr: 1
			col:     1
			level:   'error'
		},
	]
	app.diag_cache[uri] = DiagCacheEntry{
		fingerprint: fingerprint
		errors:      cached_errors
	}
	got := app.run_v_check(uri, content)
	assert got.len == 1
	assert got[0].message == 'seeded diagnostic'
	// A changed buffer misses and, with no compiler, answers nothing.
	changed := content + '\n// changed\n'
	app.open_files[uri] = changed
	missing := app.run_v_check(uri, changed)
	assert missing.len == 0, missing.str()
	os.rmdir_all(root) or {}
}

fn test_run_v_argv_reports_missing_working_dir() {
	missing_dir := os.join_path(os.temp_dir(), 'vls_missing_dir_${os.getpid()}_${time.now().unix_nano()}')
	original := os.getwd()
	result := run_v_argv(build_v_check_args_multifile(false), missing_dir)
	assert result.exit_code != 0
	// The parent process working directory must never be mutated.
	assert os.getwd() == original
}

// ============================================================================
// Tests for v_error_to_lsp_diagnostic conversion
// ============================================================================

fn test_v_error_to_lsp_diagnostic_basic() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'undefined identifier `foo`'
		line_nr: 10
		col:     5
		len:     3
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	// LSP is 0-indexed, V parser is 1-indexed
	assert diag.range.start.line == 9
	assert diag.range.start.char == 4
	assert diag.range.end.line == 9
	assert diag.range.end.char == 7 // start_char + len = 4 + 3 = 7
	assert diag.message == 'undefined identifier `foo`'
	assert diag.severity == 1 // Error
}

fn test_v_error_to_lsp_diagnostic_first_line() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'syntax error'
		line_nr: 1
		col:     1
		len:     1
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 0
	assert diag.range.start.char == 0
	assert diag.range.end.char == 1
}

fn test_v_error_to_lsp_diagnostic_long_error() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'unexpected token'
		line_nr: 100
		col:     50
		len:     20
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 99
	assert diag.range.start.char == 49
	assert diag.range.end.char == 69 // 49 + 20
}

fn test_v_error_to_lsp_diagnostic_zero_length() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'error at position'
		line_nr: 5
		col:     10
		len:     0
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.char == 9
	assert diag.range.end.char == 9 // start + 0 = same position
}

fn test_v_error_to_lsp_diagnostic_large_line_numbers() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'error in large file'
		line_nr: 10000
		col:     200
		len:     50
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 9999
	assert diag.range.start.char == 199
	assert diag.range.end.char == 249
}

fn test_v_error_to_lsp_diagnostic_column_one() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'error at start of line'
		line_nr: 5
		col:     1
		len:     5
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.char == 0
	assert diag.range.end.char == 5
}

// ============================================================================
// Tests for LSP data structures
// ============================================================================

fn test_position_struct() {
	pos := Position{
		line: 10
		char: 5
	}
	assert pos.line == 10
	assert pos.char == 5
}

fn test_position_struct_zero() {
	pos := Position{
		line: 0
		char: 0
	}
	assert pos.line == 0
	assert pos.char == 0
}

fn test_lsp_range_struct() {
	r := LSPRange{
		start: Position{
			line: 0
			char: 0
		}
		end:   Position{
			line: 0
			char: 10
		}
	}
	assert r.start.line == 0
	assert r.end.char == 10
}

fn test_lsp_range_multiline() {
	r := LSPRange{
		start: Position{
			line: 5
			char: 10
		}
		end:   Position{
			line: 10
			char: 5
		}
	}
	assert r.start.line < r.end.line
}

fn test_lsp_diagnostic_struct() {
	diag := LSPDiagnostic{
		range:    LSPRange{
			start: Position{
				line: 5
				char: 0
			}
			end:   Position{
				line: 5
				char: 10
			}
		}
		message:  'test error'
		severity: 1
	}
	assert diag.message == 'test error'
	assert diag.severity == 1
	assert diag.range.start.line == 5
}

fn test_lsp_diagnostic_severities() {
	// Test all severity levels
	severities := [1, 2, 3, 4] // Error, Warning, Information, Hint
	for sev in severities {
		diag := LSPDiagnostic{
			range:    LSPRange{}
			message:  'test'
			severity: sev
		}
		assert diag.severity == sev
	}
}

fn test_location_struct() {
	loc := Location{
		uri:   'file:///test/file.v'
		range: LSPRange{
			start: Position{
				line: 10
				char: 5
			}
			end:   Position{
				line: 10
				char: 15
			}
		}
	}
	assert loc.uri == 'file:///test/file.v'
	assert loc.range.start.line == 10
}

fn test_location_empty() {
	loc := Location{}
	assert loc.uri == ''
	assert loc.range.start.line == 0
}

fn test_detail_struct() {
	detail := Detail{
		kind:          6 // Function
		label:         'my_function'
		detail:        'fn my_function() string'
		documentation: 'A helper function'
	}
	assert detail.kind == 6
	assert detail.label == 'my_function'
	assert detail.detail == 'fn my_function() string'
}

fn test_detail_kinds() {
	// Test various completion item kinds
	kinds := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] // Text, Method, Function, etc.
	for k in kinds {
		detail := Detail{
			kind:  k
			label: 'test'
		}
		assert detail.kind == k
	}
}

fn test_detail_struct_with_snippet() {
	detail := Detail{
		kind:               6
		label:              'println'
		detail:             'fn println(s string)'
		documentation:      'Prints a string'
		insert_text:        'println(\${1:s})'
		insert_text_format: 2 // Snippet format
	}
	assert detail.insert_text? == 'println(\${1:s})'
	assert detail.insert_text_format? == 2
}

fn test_detail_without_snippet() {
	detail := Detail{
		kind:  6
		label: 'println'
	}
	assert detail.insert_text == none
	assert detail.insert_text_format == none
}

fn test_signature_help_struct() {
	sig := SignatureHelp{
		signatures:       [
			SignatureInformation{
				label:      'fn my_func(a int, b string) bool'
				parameters: [
					ParameterInformation{
						label: 'a int'
					},
					ParameterInformation{
						label: 'b string'
					},
				]
			},
		]
		active_signature: 0
		active_parameter: 1
	}
	assert sig.signatures.len == 1
	assert sig.active_parameter == 1
	assert sig.signatures[0].parameters.len == 2
}

fn test_signature_help_multiple_signatures() {
	sig := SignatureHelp{
		signatures:       [
			SignatureInformation{
				label: 'fn overload1(a int)'
			},
			SignatureInformation{
				label: 'fn overload2(a int, b int)'
			},
			SignatureInformation{
				label: 'fn overload3(a int, b int, c int)'
			},
		]
		active_signature: 1
		active_parameter: 0
	}
	assert sig.signatures.len == 3
	assert sig.active_signature == 1
}

fn test_signature_help_empty() {
	sig := SignatureHelp{}
	assert sig.signatures.len == 0
	assert sig.active_signature == 0
	assert sig.active_parameter == 0
}

fn test_capabilities_struct() {
	cap := Capabilities{
		capabilities: Capability{
			text_document_sync:      TextDocumentSyncOptions{
				open_close: true
				change:     1
			}
			completion_provider:     CompletionProvider{
				trigger_characters: ['.']
			}
			signature_help_provider: SignatureHelpOptions{
				trigger_characters: ['(', ',']
			}
			definition_provider:     true
		}
	}
	assert cap.capabilities.definition_provider == true
	assert cap.capabilities.completion_provider.trigger_characters == ['.']
	assert cap.capabilities.signature_help_provider.trigger_characters == ['(', ',']
	assert cap.capabilities.text_document_sync.change == 1
}

fn test_capabilities_minimal() {
	cap := Capabilities{
		capabilities: Capability{
			definition_provider: true
		}
	}
	assert cap.capabilities.definition_provider == true
	assert cap.capabilities.completion_provider.trigger_characters.len == 0
}

fn test_request_struct() {
	req := Request{
		id:      1
		method:  'textDocument/completion'
		jsonrpc: '2.0'
		params:  json2.encode(Params{
			position:      Position{
				line: 5
				char: 10
			}
			text_document: TextDocumentIdentifier{
				uri: 'file:///test.v'
			}
		},
			escape_unicode: true
		)
	}
	assert req.id == 1
	assert req.method == 'textDocument/completion'
	params := json2.decode[Params](req.params.str()) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert params.position.line == 5
}

fn test_request_params_decode_malformed_returns_error() {
	malformed := '{"textDocument":{"uri":"file:///test.v"},"position":{"line":5,"character":}}'
	if _ := json2.decode[Params](malformed) {
		assert false, 'Expected malformed params JSON to fail decoding'
	} else {
		assert true
	}
}

fn test_response_struct() {
	resp := Response{
		id:     1
		result: 'null'
	}
	assert resp.id == 1
	assert resp.jsonrpc == '2.0'
}

fn test_response_with_capabilities() {
	resp := Response{
		id:     0
		result: Capabilities{
			capabilities: Capability{
				definition_provider: true
			}
		}
	}
	assert resp.id == 0
	if resp.result is Capabilities {
		assert resp.result.capabilities.definition_provider == true
	}
}

fn test_notification_struct() {
	notif := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri:         'file:///test.v'
			diagnostics: []
		}
	}
	assert notif.method == 'textDocument/publishDiagnostics'
	assert notif.jsonrpc == '2.0'
}

fn test_notification_with_diagnostics() {
	notif := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri:         'file:///test.v'
			diagnostics: [
				LSPDiagnostic{
					range:    LSPRange{}
					message:  'error 1'
					severity: 1
				},
				LSPDiagnostic{
					range:    LSPRange{}
					message:  'error 2'
					severity: 1
				},
			]
		}
	}
	assert notif.params.diagnostics.len == 2
}

fn test_content_change_struct() {
	change := ContentChange{
		text: 'fn main() {\n\tprintln("hello")\n}'
	}
	assert change.text.contains('fn main()')
}

fn test_content_change_empty() {
	change := ContentChange{}
	assert change.text == ''
}

fn test_content_change_unicode() {
	change := ContentChange{
		text: "fn main() { println('Hello, 世界') }"
	}
	assert change.text.contains('世界')
}

// ============================================================================
// Tests for write_tracked_files_to_temp function
// ============================================================================

fn test_write_tracked_files_to_temp_single_file() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_interop_test_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	interop_test_must_mkdir_all(project_dir)

	test_file := os.join_path(project_dir, 'main.v')
	interop_test_must_write_file(test_file, 'module main')

	mut app := &App{
		temp_dir:   temp_dir
		open_files: map[string]string{}
	}

	uri := path_to_uri(test_file)
	app.open_files[uri] = 'module main\n\nfn main() { modified }'

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	assert os.exists(temp_project)
	temp_file := os.join_path(temp_project, 'main.v')
	assert os.exists(temp_file)

	content := os.read_file(temp_file) or { '' }
	assert content.contains('modified')
}

fn test_write_tracked_files_to_temp_multiple_files() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_interop_test2_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	interop_test_must_mkdir_all(project_dir)

	// Create original files
	files := ['main.v', 'utils.v', 'helpers.v']
	for file in files {
		path := os.join_path(project_dir, file)
		interop_test_must_write_file(path, 'module main\n\nfn ${file}() {}')
	}

	mut app := &App{
		temp_dir:   temp_dir
		open_files: map[string]string{}
	}

	// Track all files with modified content
	for file in files {
		path := os.join_path(project_dir, file)
		uri := path_to_uri(path)
		app.open_files[uri] = 'module main\n\nfn ${file}_modified() {}'
	}

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	// Verify all files were written
	for file in files {
		temp_file := os.join_path(temp_project, file)
		assert os.exists(temp_file)
		content := os.read_file(temp_file) or { '' }
		assert content.contains('_modified')
	}
}

fn test_write_tracked_files_to_temp_nested_directories() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_interop_test3_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	subdir := os.join_path(project_dir, 'src', 'internal')
	interop_test_must_mkdir_all(subdir)

	// Create nested file
	nested_file := os.join_path(subdir, 'util.v')
	interop_test_must_write_file(nested_file, 'module internal')

	mut app := &App{
		temp_dir:   temp_dir
		open_files: map[string]string{}
	}

	uri := path_to_uri(nested_file)
	app.open_files[uri] = 'module internal\n\nfn modified() {}'

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	// Verify nested structure was preserved
	temp_nested := os.join_path(temp_project, 'src', 'internal', 'util.v')
	assert os.exists(temp_nested)
}

fn test_program_root_is_the_program_that_imports_a_module() {
	// `v .` in the directory of a program checks the modules it imports, wherever
	// they sit below it, so a file of such a module is checked from there: on its
	// own, the module has no program to tell what it leaves unused, and a check
	// of the program misses the changes made to it.
	temp_dir := os.join_path(os.vtmp_dir(), 'vls_program_root_${os.getpid()}')
	os.rmdir_all(temp_dir) or {}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	for with_vmod in [false, true] {
		project := os.join_path(temp_dir, if with_vmod { 'with_vmod' } else { 'without_vmod' })
		for rel, content in {
			'main.v':            'module main\n\nimport lib\n\nfn main() {}\n'
			'lib/lib.v':         'module lib\n\nimport lib.inner\n'
			'lib/inner/inner.v': 'module inner\n'
			'lone/lone.v':       'module lone\n'
			'extra/extra.v':     'module extra\n'
			'demo/main.v':       'module main\n\nfn main() {}\n'
		} {
			path := os.join_path(project, rel)
			interop_test_must_mkdir_all(os.dir(path))
			interop_test_must_write_file(path, content)
		}
		if with_vmod {
			interop_test_must_write_file(os.join_path(project, 'v.mod'), "Module {\n\tname: 'proyecto'\n}\n")
		}
		mut app := &App{
			open_files: map[string]string{}
		}
		// An import typed in the editor and not saved yet counts as well.
		app.open_files[path_to_uri(os.join_path(project, 'main.v'))] = 'module main\n\nimport lib\nimport extra\n\nfn main() {}\n'
		root := normalize_overlay_path(project)
		mut failures := []string{}
		for rel, want in {
			'main.v':            root
			'lib/lib.v':         root // imported by main.v
			'lib/inner/inner.v': root // through lib
			'extra/extra.v':     root // imported by the unsaved buffer of main.v
			'lone/lone.v':       normalize_overlay_path(os.join_path(project, 'lone')) // imported by nothing
			'demo/main.v':       normalize_overlay_path(os.join_path(project, 'demo')) // a program of its own
		} {
			got := app.program_root(os.join_path(project, rel))
			if got != want {
				failures << '${with_vmod} ${rel}: ${got}, not ${want}'
			}
		}
		assert failures.len == 0, failures.join('\n')
	}
}

fn test_prepare_compilation_overlay_checks_vmod_subdirs_from_the_program_root() {
	// V compiles the subdirectories a v.mod lists in `subdirs` as part of the
	// program next to it, so a file there is checked from that directory: a
	// check of its own directory alone misses the rest of the program.
	temp_dir := os.join_path(os.vtmp_dir(), 'vls_vmod_subdirs_${os.getpid()}')
	os.rmdir_all(temp_dir) or {}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	app_temp_dir := os.join_path(temp_dir, 'app-temp')
	for dir in ['repo/deeper', 'tools', 'plugin'] {
		interop_test_must_mkdir_all(os.join_path(project_dir, dir))
	}
	interop_test_must_mkdir_all(app_temp_dir)
	interop_test_must_write_file(os.join_path(project_dir, 'v.mod'), "Module {\n\tname: 'subdirs_test'\n\tsubdirs: ['repo', 'plugin']\n}\n")
	interop_test_must_write_file(os.join_path(project_dir, 'plugin', 'v.mod'), "Module {\n\tname: 'plugin'\n}\n")
	mut app := &App{
		temp_dir: app_temp_dir
	}
	mut failures := []string{}
	for rel, expected in {
		'main.v':             ''
		'repo/repo.v':        ''
		'repo/deeper/more.v': ''
		'tools/tool.v':       'tools'
		'plugin/plugin.v':    'plugin'
	} {
		path := os.join_path(project_dir, rel)
		interop_test_must_write_file(path, 'module main\n')
		overlay := app.prepare_compilation_overlay(path) or {
			failures << '${rel}: ${err}'
			continue
		}
		os.rmdir_all(overlay.temp_root) or {}
		want := normalize_overlay_path(if expected == '' {
			project_dir
		} else {
			os.join_path(project_dir, expected)
		})
		if overlay.source_work_dir != want {
			failures << '${rel}: checked from ${overlay.source_work_dir}, not ${want}'
		}
	}
	assert failures.len == 0, failures.join('\n')
}

fn test_prepare_compilation_overlay_preserves_nested_symlink_layout() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_overlay_nested_symlink_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	shared_src := os.join_path(temp_dir, 'shared', 'src')
	lexical_src := os.join_path(project_dir, 'src')
	app_temp_dir := os.join_path(temp_dir, 'app-temp')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(shared_src)
	interop_test_must_mkdir_all(app_temp_dir)
	interop_test_must_write_file(os.join_path(project_dir, 'v.mod'), "Module {\n\tname: 'nested_symlink_test'\n}\n")
	os.symlink(shared_src, lexical_src) or { return }

	main_file := os.join_path(lexical_src, 'main.v')
	interop_test_must_write_file(main_file, 'module main\n')
	main_uri := path_to_uri(main_file)
	unsaved_content := 'module main\n\nfn unsaved() {}\n'
	mut app := &App{
		temp_dir:   app_temp_dir
		open_files: {
			main_uri: unsaved_content
		}
	}

	overlay := app.prepare_compilation_overlay(main_file) or {
		assert false, 'Failed to prepare nested-symlink overlay: ${err}'
		return
	}
	defer {
		os.rmdir_all(overlay.temp_root) or {}
	}

	assert overlay.source_root == normalize_overlay_path(project_dir)
	assert overlay.source_display_root == normalize_overlay_path(project_dir)
	assert overlay.source_work_dir == normalize_overlay_path(lexical_src)
	assert overlay.temp_work_dir == os.join_path(overlay.temp_root, 'src')
	assert overlay.temp_source_file == os.join_path(overlay.temp_root, 'src', 'main.v')
	assert os.read_file(overlay.temp_source_file) or { '' } == unsaved_content
	mapped_path := source_path_from_overlay(overlay.temp_source_file, overlay, '')
	assert normalize_overlay_path(mapped_path) == normalize_overlay_path(main_file)
}

fn test_prepare_compilation_overlay_preserves_posix_backslashes() {
	$if !windows {
		temp_dir := os.join_path(os.temp_dir(), 'vls_overlay_posix_backslash_${os.getpid()}_${time.now().unix_nano()}')
		defer {
			os.rmdir_all(temp_dir) or {}
		}
		project_dir := os.join_path(temp_dir, r'project\name')
		app_temp_dir := os.join_path(temp_dir, 'app-temp')
		interop_test_must_mkdir_all(project_dir)
		interop_test_must_mkdir_all(app_temp_dir)
		interop_test_must_write_file(os.join_path(project_dir, 'v.mod'), "Module {\n\tname: 'posix_backslash_test'\n}\n")
		main_file := os.join_path(project_dir, 'main.v')
		interop_test_must_write_file(main_file, 'module main\n')
		main_uri := path_to_uri(main_file)
		assert uri_to_path(main_uri) == main_file
		unsaved_content := 'module main\n\nfn unsaved() {}\n'
		mut app := &App{
			temp_dir:   app_temp_dir
			open_files: {
				main_uri: unsaved_content
			}
		}

		overlay := app.prepare_compilation_overlay(main_file) or {
			assert false, 'Failed to prepare literal-backslash overlay: ${err}'
			return
		}
		defer {
			os.rmdir_all(overlay.temp_root) or {}
		}

		assert overlay.source_root == project_dir
		assert overlay.source_display_root == project_dir
		assert os.read_file(overlay.temp_source_file) or { '' } == unsaved_content
		mapped_path := source_path_from_overlay(overlay.temp_source_file, overlay, '')
		assert mapped_path == main_file
	}
}

fn test_write_tracked_files_skips_files_outside_working_dir() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_interop_test4_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	other_dir := os.join_path(temp_dir, 'other')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(other_dir)

	// Create files in both directories
	project_file := os.join_path(project_dir, 'main.v')
	other_file := os.join_path(other_dir, 'other.v')
	interop_test_must_write_file(project_file, 'module main')
	interop_test_must_write_file(other_file, 'module other')

	mut app := &App{
		temp_dir:   temp_dir
		open_files: map[string]string{}
	}

	// Track both files
	app.open_files[path_to_uri(project_file)] = 'module main modified'
	app.open_files[path_to_uri(other_file)] = 'module other modified'

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	// Only project file should be written
	assert os.exists(os.join_path(temp_project, 'main.v'))
	assert !os.exists(os.join_path(temp_project, 'other.v'))
}

// ============================================================================
// Tests for symlink_untracked_files function
// ============================================================================

fn test_symlink_untracked_files_basic() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_test_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(target_dir)

	// Create some V files
	tracked_file := os.join_path(project_dir, 'tracked.v')
	untracked_file := os.join_path(project_dir, 'untracked.v')
	interop_test_must_write_file(tracked_file, 'module main')
	interop_test_must_write_file(untracked_file, 'module main')

	// Only track one file
	mut tracked := map[string]string{}
	tracked[path_to_uri(tracked_file)] = 'content'

	symlink_untracked_files(project_dir, project_dir, target_dir, tracked) or {
		assert false, 'Failed to symlink: ${err}'
		return
	}

	// Only untracked file should be symlinked
	assert !os.exists(os.join_path(target_dir, 'tracked.v'))
	target_untracked := os.join_path(target_dir, 'untracked.v')
	assert os.exists(target_untracked) || os.is_link(target_untracked)
}

fn test_symlink_untracked_files_nested() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_test2_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	subdir := os.join_path(project_dir, 'src')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(subdir)
	interop_test_must_mkdir_all(target_dir)

	// Create nested untracked file
	nested_file := os.join_path(subdir, 'nested.v')
	interop_test_must_write_file(nested_file, 'module src')

	tracked := map[string]string{}

	symlink_untracked_files(project_dir, project_dir, target_dir, tracked) or {
		assert false, 'Failed to symlink: ${err}'
		return
	}

	// Nested structure should be created
	target_nested := os.join_path(target_dir, 'src', 'nested.v')
	assert os.exists(target_nested) || os.is_link(target_nested)
}

fn test_symlink_untracked_files_empty_tracked() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_test3_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(target_dir)

	// Create files
	for i in 0 .. 3 {
		interop_test_must_write_file(os.join_path(project_dir, 'file${i}.v'), 'module main')
	}

	tracked := map[string]string{} // Empty - all files untracked

	symlink_untracked_files(project_dir, project_dir, target_dir, tracked) or {
		assert false, 'Failed to symlink: ${err}'
		return
	}

	// All files should be symlinked
	for i in 0 .. 3 {
		target_file := os.join_path(target_dir, 'file${i}.v')
		assert os.exists(target_file) || os.is_link(target_file)
	}
}

fn test_symlink_untracked_files_materializes_local_imports() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_local_import_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	module_dir := os.join_path(project_dir, 'mathutil')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(module_dir)
	interop_test_must_mkdir_all(target_dir)

	main_file := os.join_path(project_dir, 'main.v')
	main_content := 'module main\n\nimport (\n\tmathutil\n)\n'
	module_file := os.join_path(module_dir, 'mathutil.v')
	module_content := 'module mathutil\n\npub fn answer() int { return 42 }\n'
	interop_test_must_write_file(main_file, main_content)
	interop_test_must_write_file(module_file, module_content)

	mut tracked := map[string]string{}
	tracked[path_to_uri(main_file)] = main_content
	symlink_untracked_files(project_dir, project_dir, target_dir, tracked) or {
		assert false, 'Failed to populate overlay: ${err}'
		return
	}

	target_module_dir := os.join_path(target_dir, 'mathutil')
	target_module_file := os.join_path(target_module_dir, 'mathutil.v')
	assert os.is_dir(target_module_dir)
	assert !os.is_link(target_module_dir)
	assert os.is_file(target_module_file)
	assert !os.is_link(target_module_file)
	assert os.read_file(target_module_file) or { '' } == module_content
}

fn test_symlink_untracked_files_materializes_import_relative_to_source_module() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_nested_import_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	source_dir := os.join_path(project_dir, 'src')
	module_dir := os.join_path(source_dir, 'mathutil')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(module_dir)
	interop_test_must_mkdir_all(target_dir)

	main_file := os.join_path(source_dir, 'main.v')
	main_content := 'module main\n\nimport mathutil\n'
	module_file := os.join_path(module_dir, 'mathutil.v')
	module_content := 'module mathutil\n\npub fn answer() int { return 42 }\n'
	interop_test_must_write_file(main_file, main_content)
	interop_test_must_write_file(module_file, module_content)

	mut tracked := map[string]string{}
	tracked[path_to_uri(main_file)] = main_content
	symlink_untracked_files(project_dir, source_dir, target_dir, tracked) or {
		assert false, 'Failed to populate nested-source overlay: ${err}'
		return
	}

	target_module_dir := os.join_path(target_dir, 'src', 'mathutil')
	target_module_file := os.join_path(target_module_dir, 'mathutil.v')
	assert os.is_dir(target_module_dir)
	assert !os.is_link(target_module_dir)
	assert os.is_file(target_module_file)
	assert !os.is_link(target_module_file)
	assert os.read_file(target_module_file) or { '' } == module_content
}

fn deny_overlay_symlink(_ string, _ string) ! {
	return error('permission denied')
}

fn test_symlink_untracked_files_matches_tracked_descendants_with_windows_case_rules() {
	$if windows {
		temp_dir := os.join_path(os.temp_dir(), 'vls_overlay_windows_case_${os.getpid()}_${time.now().unix_nano()}')
		defer {
			os.rmdir_all(temp_dir) or {}
		}
		project_dir := os.join_path(temp_dir, 'project')
		source_dir := os.join_path(project_dir, 'Src')
		target_dir := os.join_path(temp_dir, 'target')
		target_source_dir := os.join_path(target_dir, 'src')
		interop_test_must_mkdir_all(source_dir)
		interop_test_must_mkdir_all(target_source_dir)
		main_file := os.join_path(source_dir, 'main.v')
		sibling_file := os.join_path(source_dir, 'sibling.v')
		interop_test_must_write_file(main_file, 'module main\n')
		interop_test_must_write_file(sibling_file, 'module main\n')
		interop_test_must_write_file(os.join_path(target_source_dir, 'main.v'), 'module main\n\n// unsaved\n')

		mut tracked := map[string]string{}
		lowercase_main_file := os.join_path(project_dir, 'src', 'main.v')
		tracked[path_to_uri(lowercase_main_file)] = 'module main\n\n// unsaved\n'
		symlink_untracked_files_with_linker(project_dir, project_dir, target_dir, tracked, deny_overlay_symlink) or {
			assert false, 'Failed to populate case-insensitive overlay: ${err}'
			return
		}

		assert os.is_file(os.join_path(target_source_dir, 'sibling.v'))
	}
}

fn test_bounded_overlay_copy_caps_file_count_across_entries() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_overlay_file_limit_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	source_dir := os.join_path(temp_dir, 'source')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(source_dir)
	interop_test_must_write_file(os.join_path(source_dir, 'one.txt'), 'one')
	interop_test_must_write_file(os.join_path(source_dir, 'two.txt'), 'two')
	mut budget := OverlayCopyBudget{
		max_files: 1
		max_bytes: 1024
	}
	mut first_visited := map[string]bool{}
	copied := copy_bounded_overlay_entry(os.join_path(source_dir, 'one.txt'), os.join_path(target_dir, 'one.txt'), mut budget, mut first_visited) or {
		assert false, 'Failed to copy the first bounded entry: ${err}'
		return
	}
	assert copied == 1
	mut second_visited := map[string]bool{}
	second_copied := copy_bounded_overlay_entry(os.join_path(source_dir, 'two.txt'), os.join_path(target_dir, 'two.txt'), mut budget, mut second_visited) or {
		assert false, 'The overlay file limit must not abort the fallback: ${err}'
		return
	}
	assert second_copied == 0
	assert budget.files == 1
	assert !os.exists(os.join_path(target_dir, 'two.txt'))
}

fn test_directories_made_the_overlay_own_share_one_copy_budget() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_overlay_own_dirs_budget_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	// Two directories the overlay links whole, made its own one after the other
	// where no link can be made.
	project_dir := os.join_path(temp_dir, 'project')
	overlay_dir := os.join_path(temp_dir, 'overlay')
	interop_test_must_mkdir_all(overlay_dir)
	for name in ['a', 'b'] {
		interop_test_must_mkdir_all(os.join_path(project_dir, name))
		interop_test_must_write_file(os.join_path(project_dir, name, '${name}.v'), 'module ${name}\n')
		os.symlink(os.join_path(project_dir, name), os.join_path(overlay_dir, name)) or { return }
	}
	mut budget := OverlayCopyBudget{
		max_files: 1
		max_bytes: 1024
	}
	for name in ['a', 'b'] {
		own_overlay_dirs_with_linker(project_dir, overlay_dir, name, deny_overlay_symlink, mut budget) or {
			assert false, 'Failed to make ${name} the overlay own: ${err}'
			return
		}
		assert os.is_dir(os.join_path(overlay_dir, name))
		assert !os.is_link(os.join_path(overlay_dir, name))
	}
	// The limit holds for both together: a.v was copied, b.v was not.
	assert os.is_file(os.join_path(overlay_dir, 'a', 'a.v'))
	assert !os.exists(os.join_path(overlay_dir, 'b', 'b.v'))
	assert budget.files == 1
	// Nothing was written into the project.
	assert os.read_file(os.join_path(project_dir, 'b', 'b.v'))! == 'module b\n'
}

fn test_bounded_overlay_copy_caps_bytes() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_overlay_byte_limit_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	source_file := os.join_path(temp_dir, 'asset.txt')
	target_file := os.join_path(temp_dir, 'target', 'asset.txt')
	interop_test_must_mkdir_all(temp_dir)
	interop_test_must_write_file(source_file, 'too large')
	mut budget := OverlayCopyBudget{
		max_files: 10
		max_bytes: 4
	}
	mut visited := map[string]bool{}
	copied := copy_bounded_overlay_entry(source_file, target_file, mut budget, mut visited) or {
		assert false, 'The overlay byte limit must not abort the fallback: ${err}'
		return
	}
	assert copied == 0
	assert budget.bytes == 0
	assert !os.exists(target_file)
}

fn test_symlink_denied_fallback_copies_external_symlink_targets() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_external_symlink_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	external_dir := os.join_path(temp_dir, 'external_assets')
	linked_dir := os.join_path(project_dir, 'assets')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(external_dir)
	interop_test_must_mkdir_all(target_dir)
	interop_test_must_write_file(os.join_path(project_dir, 'main.v'), 'module main\n')
	interop_test_must_write_file(os.join_path(external_dir, 'config.json'), '{"external":true}\n')
	os.symlink(external_dir, linked_dir) or { return }

	symlink_untracked_files_with_linker(project_dir, project_dir, target_dir, map[string]string{}, deny_overlay_symlink) or {
		assert false, 'Failed to copy an external symlink target: ${err}'
		return
	}

	target_asset := os.join_path(target_dir, 'assets', 'config.json')
	assert os.is_file(target_asset)
	assert !os.is_link(os.join_path(target_dir, 'assets'))
	assert os.read_file(target_asset) or { '' } == '{"external":true}\n'
}

fn test_local_module_copy_fallback_shares_overlay_budget() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_local_module_budget_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	source_dir := os.join_path(temp_dir, 'source')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(source_dir)
	asset_file := os.join_path(source_dir, 'asset.txt')
	module_file := os.join_path(source_dir, 'helper.v')
	interop_test_must_write_file(asset_file, 'asset')
	interop_test_must_write_file(module_file, 'module helper\n')

	mut budget := OverlayCopyBudget{
		max_files: 1
		max_bytes: 1024
	}
	mut visited := map[string]bool{}
	copy_bounded_overlay_entry(asset_file, os.join_path(target_dir, 'asset.txt'), mut budget, mut visited) or {
		assert false, 'Failed to consume the first overlay budget slot: ${err}'
		return
	}
	target_module := os.join_path(target_dir, 'helper.v')
	materialized := materialize_overlay_file_with_linker(module_file, target_module, deny_overlay_symlink, mut budget) or {
		assert false, 'The local-module copy limit must not abort the overlay: ${err}'
		return
	}
	assert !materialized
	assert budget.files == 1
	assert !os.exists(target_module)
}

fn test_symlink_denied_fallback_keeps_sources_when_copy_limit_is_reached() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_overlay_partial_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	source_dir := os.join_path(temp_dir, 'source')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(source_dir)
	interop_test_must_mkdir_all(target_dir)
	asset_file := os.join_path(source_dir, 'aaa_asset.txt')
	source_file := os.join_path(source_dir, 'zzz_sibling.v')
	interop_test_must_write_file(asset_file, 'asset')
	interop_test_must_write_file(source_file, 'module main\n')

	mut budget := OverlayCopyBudget{
		max_files: 1
		max_bytes: 1024
	}
	symlink_untracked_tree(source_dir, source_dir, target_dir, '', []string{}, []string{}, deny_overlay_symlink, mut budget) or {
		assert false, 'The copy limit must preserve the partial overlay: ${err}'
		return
	}

	assert os.is_file(os.join_path(target_dir, 'zzz_sibling.v'))
	assert !os.exists(os.join_path(target_dir, 'aaa_asset.txt'))
	assert budget.files == 1
}

fn test_symlink_untracked_files_copies_when_symlinks_are_denied() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_denied_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	module_dir := os.join_path(project_dir, 'helper')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(module_dir)
	interop_test_must_mkdir_all(target_dir)

	main_file := os.join_path(project_dir, 'main.v')
	vmod_file := os.join_path(project_dir, 'v.mod')
	module_file := os.join_path(module_dir, 'helper.v')
	git_dir := os.join_path(project_dir, '.git')
	node_modules_dir := os.join_path(project_dir, 'node_modules', 'dependency')
	thirdparty_dir := os.join_path(project_dir, 'thirdparty', 'native_dependency')
	build_dir := os.join_path(project_dir, 'build')
	assets_dir := os.join_path(project_dir, 'assets')
	main_content := 'module main\n'
	vmod_content := "Module {\n\tname: 'denied_symlink_test'\n}\n"
	module_content := 'module helper\n\npub fn answer() int { return 42 }\n'
	interop_test_must_mkdir_all(git_dir)
	interop_test_must_mkdir_all(node_modules_dir)
	interop_test_must_mkdir_all(thirdparty_dir)
	interop_test_must_mkdir_all(build_dir)
	interop_test_must_mkdir_all(assets_dir)
	interop_test_must_write_file(main_file, main_content)
	interop_test_must_write_file(vmod_file, vmod_content)
	interop_test_must_write_file(module_file, module_content)
	interop_test_must_write_file(os.join_path(project_dir, 'README.md'), 'project documentation\n')
	interop_test_must_write_file(os.join_path(assets_dir, 'config.json'), '{"enabled":true}\n')
	interop_test_must_write_file(os.join_path(assets_dir, 'template.txt'), 'Hello, embedded asset!\n')
	interop_test_must_write_file(os.join_path(assets_dir, 'logo.png'), 'fake png bytes')
	interop_test_must_write_file(os.join_path(git_dir, 'metadata.json'), '{"git":true}\n')
	interop_test_must_write_file(os.join_path(node_modules_dir, 'dependency.json'), '{"dependency":true}\n')
	interop_test_must_write_file(os.join_path(thirdparty_dir, 'dependency.json'), '{"native_dependency":true}\n')
	interop_test_must_write_file(os.join_path(thirdparty_dir, 'embedded.json'), '{"embedded":true}\n')
	interop_test_must_write_file(os.join_path(thirdparty_dir, 'dependency.h'), '#define DEPENDENCY 1\n')
	interop_test_must_write_file(os.join_path(thirdparty_dir, 'dependency.a'), 'fake library bytes')
	interop_test_must_write_file(os.join_path(build_dir, 'generated.json'), '{"build":true}\n')

	mut tracked := map[string]string{}
	tracked[path_to_uri(main_file)] = "module main\n\n#flag -I @VMODROOT/thirdparty/native_dependency\nconst embedded = \$embed_file('thirdparty/native_dependency/embedded.json')\n"
	symlink_untracked_files_with_linker(project_dir, project_dir, target_dir, tracked, deny_overlay_symlink) or {
		assert false, 'Failed to copy denied symlinks: ${err}'
		return
	}

	assert !os.exists(os.join_path(target_dir, 'main.v'))
	target_vmod := os.join_path(target_dir, 'v.mod')
	target_module := os.join_path(target_dir, 'helper')
	target_module_file := os.join_path(target_module, 'helper.v')
	assert os.is_file(target_vmod)
	assert !os.is_link(target_vmod)
	assert os.read_file(target_vmod) or { '' } == vmod_content
	assert os.is_dir(target_module)
	assert !os.is_link(target_module)
	assert os.read_file(target_module_file) or { '' } == module_content
	assert os.read_file(os.join_path(target_dir, 'README.md')) or { '' } == 'project documentation\n'
	assert os.read_file(os.join_path(target_dir, 'assets', 'config.json')) or { '' } == '{"enabled":true}\n'
	assert os.read_file(os.join_path(target_dir, 'assets', 'template.txt')) or { '' } == 'Hello, embedded asset!\n'
	assert os.read_file(os.join_path(target_dir, 'assets', 'logo.png')) or { '' } == 'fake png bytes'
	assert !os.exists(os.join_path(target_dir, '.git'))
	assert !os.exists(os.join_path(target_dir, 'node_modules'))
	target_thirdparty := os.join_path(target_dir, 'thirdparty', 'native_dependency')
	assert os.read_file(os.join_path(target_thirdparty, 'embedded.json')) or { '' } == '{"embedded":true}\n'
	assert os.read_file(os.join_path(target_thirdparty, 'dependency.h')) or { '' } == '#define DEPENDENCY 1\n'
	assert os.read_file(os.join_path(target_thirdparty, 'dependency.a')) or { '' } == 'fake library bytes'
	assert !os.exists(os.join_path(target_thirdparty, 'dependency.json'))
	assert !os.exists(os.join_path(target_dir, 'build'))
}

// ============================================================================
// Tests for edge cases
// ============================================================================

fn test_uri_path_edge_cases() {
	// Test various URI formats
	test_cases := [
		'file:///simple.v',
		'file:///path/to/file.v',
		'file:///path/with spaces/file.v',
		'file:///very/deep/nested/path/to/file.v',
	]

	for uri in test_cases {
		path := uri_to_path(uri)
		reconstructed := path_to_uri(path)
		// Should be able to convert back (approximately)
		assert reconstructed.contains('file://')
		assert reconstructed.contains('.v')
	}
}

fn test_json_error_defaults() {
	err := JsonError{}
	assert err.path == ''
	assert err.message == ''
	assert err.line_nr == 0
	assert err.col == 0
	assert err.len == 0
}

fn test_json_error_negative_values() {
	// LSP positions must be non-negative. Invalid compiler values are clamped
	// to 0 rather than emitted as negative positions (P1-09).
	err := JsonError{
		line_nr: -1
		col:     -1
		len:     -1
	}
	diag := v_error_to_lsp_diagnostic(err)
	assert diag.severity == 1
	assert diag.range.start.line == 0
	assert diag.range.start.char == 0
	assert diag.range.end.line == 0
	assert diag.range.end.char == 0
}

fn test_text_document_identifier() {
	doc := TextDocumentIdentifier{
		uri: 'file:///test.v'
	}
	assert doc.uri == 'file:///test.v'
}

fn test_text_document_identifier_empty() {
	doc := TextDocumentIdentifier{}
	assert doc.uri == ''
}

fn test_params_struct_complete() {
	params := Params{
		content_changes: [ContentChange{
			text: 'test'
		}]
		position:        Position{
			line: 5
			char: 10
		}
		text_document:   TextDocumentIdentifier{
			uri: 'file:///test.v'
		}
	}
	assert params.content_changes.len == 1
	assert params.position.line == 5
	assert params.text_document.uri == 'file:///test.v'
}

fn test_completion_provider_multiple_triggers() {
	provider := CompletionProvider{
		trigger_characters: ['.', ':', '@', '(']
	}
	assert provider.trigger_characters.len == 4
	assert '.' in provider.trigger_characters
	assert ':' in provider.trigger_characters
}

fn test_signature_help_options_triggers() {
	opts := SignatureHelpOptions{
		trigger_characters: ['(', ',', '<']
	}
	assert opts.trigger_characters.len == 3
}

fn test_text_document_sync_options() {
	sync := TextDocumentSyncOptions{
		open_close: true
		change:     1 // Full sync
	}
	assert sync.open_close == true
	assert sync.change == 1
}

fn test_text_document_sync_incremental() {
	sync := TextDocumentSyncOptions{
		open_close: true
		change:     2 // Incremental sync
	}
	assert sync.change == 2
}

fn test_parameter_information() {
	param := ParameterInformation{
		label: 'x int'
	}
	assert param.label == 'x int'
}

fn test_signature_information_with_params() {
	sig := SignatureInformation{
		label:      'fn test(a int, b string, c bool)'
		parameters: [
			ParameterInformation{
				label: 'a int'
			},
			ParameterInformation{
				label: 'b string'
			},
			ParameterInformation{
				label: 'c bool'
			},
		]
	}
	assert sig.parameters.len == 3
	assert sig.label.contains('test')
}

fn test_publish_diagnostics_params() {
	params := PublishDiagnosticsParams{
		uri:         'file:///test.v'
		diagnostics: [
			LSPDiagnostic{
				range:    LSPRange{}
				message:  'error'
				severity: 1
			},
		]
	}
	assert params.uri == 'file:///test.v'
	assert params.diagnostics.len == 1
}

// ============================================================================
// Compiler-compatibility matrix: one stub compiler per LineInfoMode.
// Each stub answers `-check` with a diagnostic (so diagnostics are
// independent of the `-line-info` mode) and answers `-line-info` the way
// its generation does. Every test asserts the probed mode, that a
// diagnostics spot-check still returns results, and that the mode never
// regresses within the session once probed.
// ============================================================================

// A current compiler answers `-line-info` itself: no refusal, no selector.
const compat_matrix_modern_direct_stub = r'#!/bin/sh
case " $* " in
  *"-line-info"*)
    case " $* " in
      *hv^4*) echo "{\"contents\":{\"kind\":\"markdown\",\"value\":\"fn helper()\"}}" ;;
    esac
    exit 0
    ;;
esac
case " $* " in
  *" -check "*)
    for last in "$@"; do :; done
    echo "${last}:1:1: error: stub check error" >&2
    exit 1
    ;;
esac
exit 0
'

// An older launcher refuses `-line-info` until `-old-compiler` selects it.
const compat_matrix_old_flag_stub = r'#!/bin/sh
case " $* " in
  *"-line-info"*)
    for arg in "$@"; do
      if [ "$arg" = "-old-compiler" ]; then
        echo "\`-old-compiler\` was requested; retrying with \`/v1_fallback\`." >&2
        echo "{\"contents\":{\"kind\":\"markdown\",\"value\":\"fn helper()\"}}"
        exit 0
      fi
    done
    echo "unknown option \`-vls-mode\`" >&2
    exit 1
    ;;
esac
case " $* " in
  *" -check "*)
    for last in "$@"; do :; done
    echo "${last}:1:1: error: stub check error" >&2
    exit 1
    ;;
esac
exit 0
'

// A launcher with no checker refuses the options and the selector outright.
const compat_matrix_dead_end_stub = r'#!/bin/sh
case " $* " in
  *"-line-info"*)
    for arg in "$@"; do
      if [ "$arg" = "-old-compiler" ]; then
        echo "unknown option \`-old-compiler\`" >&2
        exit 1
      fi
    done
    echo "unknown option \`-vls-mode\`" >&2
    exit 1
    ;;
esac
case " $* " in
  *" -check "*)
    for last in "$@"; do :; done
    echo "${last}:1:1: error: stub check error" >&2
    exit 1
    ;;
esac
exit 0
'

fn test_compat_matrix_modern_direct_probes_direct() {
	$if windows {
		// The stand-in compiler is a POSIX shell script.
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_compat_modern', compat_matrix_modern_direct_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}
	assert app.line_info_mode == .unknown

	hover := app.run_v_line_info(.hover, uri, '6:hv^4')
	assert app.line_info_mode == .direct
	assert hover is Hover
	if hover is Hover {
		assert hover.contents.value.contains('fn helper()')
	}

	content := os.read_file(uri_to_path(uri)) or { '' }
	check := app.run_v_check(uri, content)
	assert check.len > 0, 'expected diagnostics from the modern stub'
	assert check[0].message.contains('stub check error')

	// A probed mode never regresses within the session.
	again := app.run_v_line_info(.hover, uri, '6:hv^4')
	assert app.line_info_mode == .direct
	assert again is Hover
}

fn test_compat_matrix_old_flag_needs_explicit_selector() {
	$if windows {
		// The stand-in compiler is a POSIX shell script.
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_compat_old_flag', compat_matrix_old_flag_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}
	assert app.line_info_mode == .unknown

	hover := app.run_v_line_info(.hover, uri, '6:hv^4')
	assert app.line_info_mode == .compat
	assert hover is Hover
	if hover is Hover {
		assert hover.contents.value.contains('fn helper()')
	}

	content := os.read_file(uri_to_path(uri)) or { '' }
	check := app.run_v_check(uri, content)
	assert check.len > 0, 'expected diagnostics from the old-flag stub'
	assert check[0].message.contains('stub check error')

	// Compat stays compat: the retry keeps selecting the checker directly.
	again := app.run_v_line_info(.hover, uri, '6:hv^4')
	assert app.line_info_mode == .compat
	assert again is Hover
}

fn test_compat_matrix_dead_end_without_checker() {
	$if windows {
		// The stand-in compiler is a POSIX shell script.
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_compat_dead_end', compat_matrix_dead_end_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}
	app.capture_output = true
	assert app.line_info_mode == .unknown

	assert app.run_v_line_info(.hover, uri, '6:hv^4') == ResponseResult('null')
	assert app.line_info_mode == .missing

	// Retiring the lookups must not retire diagnostics: `v check` needs
	// no compatibility compiler.
	content := os.read_file(uri_to_path(uri)) or { '' }
	check := app.run_v_check(uri, content)
	assert check.len > 0, 'expected diagnostics from the dead-end stub'
	assert check[0].message.contains('stub check error')

	// Retired stays retired: no new process, no second notice.
	assert app.run_v_line_info(.hover, uri, '6:hv^4') == ResponseResult('null')
	assert app.line_info_mode == .missing
	assert app.captured_output.len == 1
}

// ============================================================================
// Tiered-diagnostics coverage for interop.v, diag_cache.v and run_command.v.
// Every test below names the production function it covers directly.
// ============================================================================

fn test_cov_hex_nibble_decodes_and_rejects() {
	assert (hex_nibble(`0`) or { 255 }) == 0, 'hex 0 decodes to 0'
	assert (hex_nibble(`9`) or { 255 }) == 9, 'hex 9 decodes to 9'
	assert (hex_nibble(`a`) or { 255 }) == 10, 'hex a decodes to 10'
	assert (hex_nibble(`f`) or { 255 }) == 15, 'hex f decodes to 15'
	assert (hex_nibble(`A`) or { 255 }) == 10, 'hex A decodes to 10'
	assert (hex_nibble(`F`) or { 255 }) == 15, 'hex F decodes to 15'
	if _ := hex_nibble(`g`) {
		assert false, 'g is not a hex digit'
	} else {
		assert true, 'g is rejected'
	}
	if _ := hex_nibble(`/`) {
		assert false, '/ is not a hex digit'
	} else {
		assert true, '/ is rejected'
	}
}

fn test_cov_percent_decode_keeps_invalid_escapes() {
	assert percent_decode('abc') == 'abc', 'no escape passes through'
	assert percent_decode('a%20b') == 'a b', '%20 decodes to a space'
	assert percent_decode('a%2Gb%') == 'a%2Gb%', 'invalid and trailing escapes are kept'
	assert percent_decode('100%25') == '100%', '%25 decodes to percent'
	assert percent_decode('%') == '%', 'lone percent is kept'
}

fn test_cov_path_byte_needs_escape_and_percent_encode_path() {
	assert !path_byte_needs_escape(`a`), 'lowercase is unreserved'
	assert !path_byte_needs_escape(`Z`), 'uppercase is unreserved'
	assert !path_byte_needs_escape(`0`), 'digit is unreserved'
	assert !path_byte_needs_escape(`-`), 'dash is unreserved'
	assert !path_byte_needs_escape(`/`), 'slash is kept as separator'
	assert !path_byte_needs_escape(`:`), 'colon is kept for drive letters'
	assert path_byte_needs_escape(` `), 'space must be escaped'
	assert path_byte_needs_escape(`#`), 'hash must be escaped'
	assert path_byte_needs_escape(`%`), 'percent must be escaped'
	assert path_byte_needs_escape(`\\`), 'backslash must be escaped'
	assert percent_encode_path('a b#c%d:e/f-._~') == 'a%20b%23c%25d:e/f-._~', 'encodes only reserved bytes'
}

fn test_cov_path_is_within_and_path_relative_to_wrappers() {
	assert path_is_within('/a/b/c', '/a/b'), 'child is within parent'
	assert path_is_within('/a/b', '/a/b'), 'directory is within itself'
	assert !path_is_within('/a/barley', '/a/bar'), 'sibling prefix is not within'
	assert !path_is_within('/a/b', ''), 'empty dir never contains'
	assert path_relative_to('/a/b/c', '/a/b') or { '' } == 'c', 'relative strips the prefix'
	assert path_relative_to('/a/b', '/a/b') or { 'x' } == '', 'equal paths give empty relative'
	if _ := path_relative_to('/other/file.v', '/a/b') {
		assert false, 'outside path must be none'
	} else {
		assert true, 'outside path is none'
	}
}

fn test_cov_make_unique_temp_path_tags_extension() {
	tagged := make_unique_temp_path('check', '/tmp/foo.v')
	assert tagged.contains('check'), 'tag names the purpose: ${tagged}'
	assert tagged.ends_with('.v'), 'extension is kept: ${tagged}'
	assert tagged.contains('foo'), 'base name is kept: ${tagged}'
	plain := make_unique_temp_path('work', '/tmp/foo')
	assert plain.ends_with('.v'), 'extensionless input defaults to .v: ${plain}'
	other := make_unique_temp_path('check', '/tmp/foo.v')
	assert other.contains('check'), 'a repeated call keeps the tag: ${other}'
	assert other.ends_with('.v'), 'a repeated call keeps the extension: ${other}'
}

fn test_cov_build_v_line_info_args_multifile_shape() {
	args := build_v_line_info_args_multifile('main.v', '10:gd^5')
	assert args == ['-w', '-check', '-nocolor', '-vls-mode', '-line-info', 'main.v:10:gd^5', '.'], 'multifile line-info argv is exact: ${args}'
}

fn test_cov_compiler_is_available_reports_exe_presence() {
	previous := os.getenv('VLS_V_COMMAND')
	defer {
		restore_v_command(previous)
	}
	base := os.join_path(os.temp_dir(), 'vls_cov_available_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	real := os.join_path(base, 'v')
	interop_test_must_write_file(real, 'stub')
	os.setenv('VLS_V_COMMAND', real, true)
	assert compiler_is_available(), 'an existing configured compiler is available'
	os.setenv('VLS_V_COMMAND', os.join_path(base, 'no-such-compiler'), true)
	assert !compiler_is_available(), 'a missing configured compiler is unavailable'
}

fn test_cov_program_diagnostic_level_prefixes() {
	if level, message := program_diagnostic_level('builder error: redefinition of function `main`') {
		assert level == 'error', 'builder error maps to error'
		assert message == 'redefinition of function `main`', 'builder message is kept'
	} else {
		assert false, 'builder error must parse'
	}
	if level, _ := program_diagnostic_level('checker error: bad') {
		assert level == 'error', 'checker error maps to error'
	} else {
		assert false, 'checker error must parse'
	}
	if level, _ := program_diagnostic_level('parser error: bad') {
		assert level == 'error', 'parser error maps to error'
	} else {
		assert false, 'parser error must parse'
	}
	if level, _ := program_diagnostic_level('cgen error: bad') {
		assert level == 'error', 'cgen error maps to error'
	} else {
		assert false, 'cgen error must parse'
	}
	if level, message := program_diagnostic_level('error: plain failure') {
		assert level == 'error', 'plain error keeps its level'
		assert message == 'plain failure', 'plain error keeps its message'
	} else {
		assert false, 'plain error must parse'
	}
	if level, _ := program_diagnostic_level('warning: unused') {
		assert level == 'warning', 'warning keeps its level'
	} else {
		assert false, 'warning must parse'
	}
	if level, _ := program_diagnostic_level('notice: hint') {
		assert level == 'notice', 'notice keeps its level'
	} else {
		assert false, 'notice must parse'
	}
	if _, _ := program_diagnostic_level('/tmp/main.v:1:1: error: placed') {
		assert false, 'a placed diagnostic is not a program diagnostic'
	} else {
		assert true, 'a placed diagnostic is skipped'
	}
}

fn test_cov_quoted_words_extracts_both_quote_styles() {
	assert quoted_words('uses `alpha` plus "beta"') == ['alpha', 'beta'], 'backticks and double quotes are read'
	assert quoted_words('nothing quoted here') == [], 'unquoted text gives no words'
	assert quoted_words('empty `` quotes') == [], 'empty quotes give no words'
}

fn test_cov_program_diagnostic_place_keyword_order_and_fallback() {
	lines := ['module main', 'import lib', 'fn main() {']
	line_nr, col, len := program_diagnostic_place(lines, ['lib'], ['import ', 'module '])
	assert line_nr == 2, 'import keyword finds line 2, got ${line_nr}'
	assert col == 1, 'column starts at 1, got ${col}'
	assert len == 'import lib'.len, 'length covers the whole line, got ${len}'
	// Keywords are tried in order: fn first finds the function even though an
	// import of another word exists.
	ordered := ['import lib', 'fn main() {']
	line_fn, _, _ := program_diagnostic_place(ordered, ['main', 'lib'], ['fn ', 'import '])
	assert line_fn == 2, 'function keyword wins when listed first, got ${line_fn}'
	fallback_nr, fallback_col, fallback_len := program_diagnostic_place(lines, ['zzz'], [
		'import ',
		'fn ',
	])
	assert fallback_nr == 1, 'unknown words fall back to line 1, got ${fallback_nr}'
	assert fallback_col == 1, 'fallback column is 1, got ${fallback_col}'
	assert fallback_len == 'module main'.len, 'fallback covers the first line, got ${fallback_len}'
	empty_nr, empty_col, empty_len := program_diagnostic_place([]string{}, ['zzz'], ['fn '])
	assert empty_nr == 1 && empty_col == 1 && empty_len == 0, 'empty files anchor at 1:1 with length 0'
}

fn test_cov_diagnostic_source_path_is_valid_suffix_and_disk() {
	assert diagnostic_source_path_is_valid('main.v', ''), '.v is valid without a source dir'
	assert diagnostic_source_path_is_valid('run.vsh', ''), '.vsh is valid without a source dir'
	assert !diagnostic_source_path_is_valid('notes.txt', ''), '.txt is never a source'
	assert !diagnostic_source_path_is_valid('novtsuffix', ''), 'suffixless paths are rejected'
	base := os.join_path(os.temp_dir(), 'vls_cov_valid_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	real := os.join_path(base, 'main.v')
	interop_test_must_write_file(real, 'module main\n')
	assert diagnostic_source_path_is_valid(real, base), 'an existing absolute file is valid'
	assert !diagnostic_source_path_is_valid(os.join_path(base, 'missing.v'), base), 'a missing file is invalid'
	assert diagnostic_source_path_is_valid('main.v', base), 'a relative file present on disk is valid'
	assert !diagnostic_source_path_is_valid('missing.v', base), 'a relative file missing on disk is invalid'
}

fn test_cov_parse_v_check_diagnostic_header_accepts_and_rejects() {
	if diag := parse_v_check_diagnostic_header('/tmp/main.v:3:7: error: boom', '') {
		assert diag.path == '/tmp/main.v', 'path is kept'
		assert diag.line_nr == 3, 'line is parsed'
		assert diag.col == 7, 'column is parsed'
		assert diag.message == 'boom', 'message is parsed'
		assert diag.level == 'error', 'level is parsed'
	} else {
		assert false, 'a plain header must parse'
	}
	if diag := parse_v_check_diagnostic_header('/tmp/main.v:3:7: builder error: broken', '') {
		assert diag.level == 'error', 'builder error maps to error, got ${diag.level}'
	} else {
		assert false, 'a builder header must parse'
	}
	if _ := parse_v_check_diagnostic_header('/tmp/main.v:3:x: error: boom', '') {
		assert false, 'a non-numeric column must be rejected'
	} else {
		assert true, 'a non-numeric column is rejected'
	}
	if _ := parse_v_check_diagnostic_header('/tmp/notes.txt:3:7: error: boom', '') {
		assert false, 'a non-V path must be rejected'
	} else {
		assert true, 'a non-V path is rejected'
	}
	if _ := parse_v_check_diagnostic_header('just some log line', '') {
		assert false, 'a log line must be rejected'
	} else {
		assert true, 'a log line is rejected'
	}
}

fn test_cov_decimal_text_is_valid_cases() {
	assert decimal_text_is_valid('0'), 'zero is valid'
	assert decimal_text_is_valid('123'), 'digits are valid'
	assert !decimal_text_is_valid(''), 'empty text is invalid'
	assert !decimal_text_is_valid('12a'), 'letters are invalid'
	assert !decimal_text_is_valid('-3'), 'a sign is invalid'
}

fn test_cov_v_diagnostic_underline_len_cases() {
	assert v_diagnostic_underline_len('      |   ~~~') == 3, 'tildes measure the span'
	assert v_diagnostic_underline_len('      |   ^^^') == 3, 'carets measure the span'
	assert v_diagnostic_underline_len('no separator here') == 0, 'a line without a pipe gives 0'
	assert v_diagnostic_underline_len('  |   ') == 0, 'a blank marker gives 0'
	assert v_diagnostic_underline_len('  | ~~xx') == 0, 'mixed markers give 0'
}

fn test_cov_resolve_compiler_timeout_ms_env_override() {
	previous := os.getenv('VLS_TIMEOUT_MS')
	defer {
		if previous == '' {
			os.unsetenv('VLS_TIMEOUT_MS')
		} else {
			os.setenv('VLS_TIMEOUT_MS', previous, true)
		}
	}
	os.unsetenv('VLS_TIMEOUT_MS')
	assert resolve_compiler_timeout_ms() == 30000, 'the default timeout is 30s'
	os.setenv('VLS_TIMEOUT_MS', '1500', true)
	assert resolve_compiler_timeout_ms() == 1500, 'a positive override wins'
	os.setenv('VLS_TIMEOUT_MS', '0', true)
	assert resolve_compiler_timeout_ms() == 30000, 'zero falls back to the default'
	os.setenv('VLS_TIMEOUT_MS', '-5', true)
	assert resolve_compiler_timeout_ms() == 30000, 'a negative value falls back to the default'
	os.setenv('VLS_TIMEOUT_MS', 'abc', true)
	assert resolve_compiler_timeout_ms() == 30000, 'a non-numeric value falls back to the default'
}

fn test_cov_compilation_overlay_root_and_work_dir() {
	base := os.join_path(os.temp_dir(), 'vls_cov_root_${os.getpid()}')
	plain := os.join_path(base, 'plain')
	proj := os.join_path(base, 'proj')
	sub := os.join_path(proj, 'repo', 'deeper')
	interop_test_must_mkdir_all(sub)
	interop_test_must_mkdir_all(plain)
	interop_test_must_write_file(os.join_path(proj, 'v.mod'), "Module {\n\tname: 'covroot'\n}\n")
	plain_file := os.join_path(plain, 'main.v')
	interop_test_must_write_file(plain_file, 'module main\n')
	assert compilation_overlay_root(plain_file) == normalize_overlay_path(plain), 'loose files overlay from their own dir'
	proj_file := os.join_path(sub, 'more.v')
	interop_test_must_write_file(proj_file, 'module main\n')
	assert compilation_overlay_root(proj_file) == normalize_overlay_path(proj), 'v.mod files overlay from the project root'
	assert compilation_work_dir(plain_file) == normalize_overlay_path(plain), 'loose files check from their own dir'
	assert compilation_work_dir(proj_file) == normalize_overlay_path(sub), 'unlisted subdirs check from their own dir'
	os.rmdir_all(base) or {}
	listed_base := os.join_path(os.temp_dir(), 'vls_cov_subdirs_${os.getpid()}')
	listed_proj := os.join_path(listed_base, 'proj')
	listed_sub := os.join_path(listed_proj, 'repo')
	interop_test_must_mkdir_all(listed_sub)
	interop_test_must_write_file(os.join_path(listed_proj, 'v.mod'), "Module {\n\tname: 'covsub'\n\tsubdirs: ['repo']\n}\n")
	listed_file := os.join_path(listed_sub, 'repo.v')
	interop_test_must_write_file(listed_file, 'module main\n')
	assert compilation_work_dir(listed_file) == normalize_overlay_path(listed_proj), 'listed subdirs check from the program root'
	os.rmdir_all(listed_base) or {}
}

fn test_cov_should_use_compilation_overlay_branches() {
	base := os.join_path(os.temp_dir(), 'vls_cov_should_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	lone := os.join_path(base, 'lone.v')
	interop_test_must_write_file(lone, 'module main\n')
	assert !should_use_compilation_overlay(lone, 1), 'a lone file with one buffer needs no overlay'
	assert should_use_compilation_overlay(lone, 2), 'two open buffers need an overlay'
	sibling := os.join_path(base, 'sibling.v')
	interop_test_must_write_file(sibling, 'module main\n')
	assert should_use_compilation_overlay(lone, 1), 'a sibling module file needs an overlay'
	interop_test_must_write_file(os.join_path(base, 'v.mod'), "Module {\n\tname: 'covshould'\n}\n")
	assert should_use_compilation_overlay(lone, 1), 'a v.mod project needs an overlay'
}

fn test_cov_resolve_local_module_dir_variants() {
	base := os.join_path(os.temp_dir(), 'vls_cov_localmod_${os.getpid()}')
	prog := os.join_path(base, 'prog')
	interop_test_must_mkdir_all(os.join_path(prog, 'a', 'b'))
	defer {
		os.rmdir_all(base) or {}
	}
	if got := resolve_local_module_dir('a.b', prog, '') {
		assert got == normalize_overlay_path(os.join_path(prog, 'a', 'b')), 'dotted imports resolve below the program'
	} else {
		assert false, 'a.b must resolve below the program'
	}
	if _ := resolve_local_module_dir('missing', prog, '') {
		assert false, 'an unknown module must be none'
	} else {
		assert true, 'an unknown module is none'
	}
	// A v.mod root named proj serves proj.a from its own a/ directory.
	root := os.join_path(base, 'proj')
	interop_test_must_mkdir_all(os.join_path(root, 'a'))
	if got := resolve_local_module_dir('proj.a', prog, root) {
		assert got == normalize_overlay_path(os.join_path(root, 'a')), 'the project prefix resolves below the v.mod root'
	} else {
		assert false, 'proj.a must resolve below the v.mod root'
	}
}

fn test_cov_v_files_in_and_source_text_and_has_sibling() {
	base := os.join_path(os.temp_dir(), 'vls_cov_vfiles_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	main_file := os.join_path(base, 'main.v')
	other_file := os.join_path(base, 'other.v')
	interop_test_must_write_file(main_file, 'module main\n')
	interop_test_must_write_file(other_file, 'module main\n')
	interop_test_must_write_file(os.join_path(base, 'skip_test.v'), 'module main\n')
	interop_test_must_write_file(os.join_path(base, 'keep_test_test.v'), 'module main\n')
	main_uri := path_to_uri(main_file)
	mut app := &App{
		open_files: {
			main_uri:                                 'buffer wins'
			path_to_uri(os.join_path(base, 'new.v')): 'unsaved module'
		}
	}
	files := app.v_files_in(normalize_overlay_path(base))
	assert normalize_overlay_path(main_file) in files, 'disk files are listed'
	assert normalize_overlay_path(other_file) in files, 'sibling files are listed'
	assert files.any(it.ends_with('new.v')), 'unsaved buffers are listed'
	assert !files.any(it.ends_with('keep_test_test.v')), 'test files are left out'
	assert app.source_text(normalize_overlay_path(main_file)) == 'buffer wins', 'open buffers win over disk'
	assert app.source_text(normalize_overlay_path(other_file)) == 'module main\n', 'closed files read from disk'
	assert app.source_text(normalize_overlay_path(os.join_path(base, 'gone.v'))) == '', 'missing files read as empty'
	assert has_sibling_v_files(base, main_file), 'a sibling .v file is detected'
	lone_dir := os.join_path(base, 'lone')
	interop_test_must_mkdir_all(lone_dir)
	lone_file := os.join_path(lone_dir, 'only.v')
	interop_test_must_write_file(lone_file, 'module main\n')
	assert !has_sibling_v_files(lone_dir, lone_file), 'a lone file has no siblings'
	assert !has_sibling_v_files(os.join_path(base, 'no-such-dir'), lone_file), 'a missing dir has no siblings'
}

fn test_cov_program_reaches_is_program_dir_imports_local() {
	base := os.join_path(os.temp_dir(), 'vls_cov_reaches_${os.getpid()}')
	interop_test_must_mkdir_all(os.join_path(base, 'lib'))
	interop_test_must_mkdir_all(os.join_path(base, 'lone'))
	defer {
		os.rmdir_all(base) or {}
	}
	interop_test_must_write_file(os.join_path(base, 'main.v'), 'module main\n\nimport lib\n\nfn main() {}\n')
	interop_test_must_write_file(os.join_path(base, 'lib', 'lib.v'), 'module lib\n')
	interop_test_must_write_file(os.join_path(base, 'lone', 'lone.v'), 'module lone\n')
	interop_test_must_write_file(os.join_path(base, 'plain.v'), 'module main\n\nfn main() {}\n')
	lib_dir := normalize_overlay_path(os.join_path(base, 'lib'))
	lone_dir := normalize_overlay_path(os.join_path(base, 'lone'))
	root := normalize_overlay_path(base)
	mut app := &App{
		open_files: map[string]string{}
	}
	assert app.program_reaches(root, '', lib_dir), 'the program reaches its imported module'
	assert !app.program_reaches(root, '', lone_dir), 'the program does not reach an unimported module'
	assert !app.program_reaches(lib_dir, '', lone_dir), 'a library dir is not a program'
	assert app.is_program_dir(root), 'a dir with module main is a program dir'
	assert !app.is_program_dir(lib_dir), 'a library dir is not a program dir'
	assert app.imports_local_module(os.join_path(base, 'main.v'), root), 'main.v imports a local module'
	assert !app.imports_local_module(os.join_path(base, 'plain.v'), root), 'a file without local imports needs no program check'
}

fn test_cov_prepare_compilation_overlay_in_and_with_and_line_info() {
	base := os.join_path(os.temp_dir(), 'vls_cov_prep_${os.getpid()}')
	proj := os.join_path(base, 'proj')
	interop_test_must_mkdir_all(proj)
	work := os.join_path(base, 'work')
	interop_test_must_mkdir_all(work)
	defer {
		os.rmdir_all(base) or {}
	}
	main_file := os.join_path(proj, 'main.v')
	interop_test_must_write_file(main_file, 'module main\n')
	main_uri := path_to_uri(main_file)
	unsaved := 'module main\n\nfn unsaved() {}\n'
	mut app := &App{
		temp_dir:   work
		open_files: {
			main_uri: unsaved
		}
	}
	overlay := app.prepare_compilation_overlay_in(main_file, proj) or {
		assert false, 'prepare in must succeed: ${err}'
		return
	}
	defer {
		os.rmdir_all(overlay.temp_root) or {}
	}
	assert os.read_file(overlay.temp_source_file) or { '' } == unsaved, 'the buffer is materialized'
	assert overlay.source_work_dir == normalize_overlay_path(proj), 'the work dir is kept'
	with_overlay := app.prepare_compilation_overlay_with(main_file, proj, map[string]string{}) or {
		assert false, 'prepare with must succeed: ${err}'
		return
	}
	defer {
		os.rmdir_all(with_overlay.temp_root) or {}
	}
	assert with_overlay.source_work_dir == normalize_overlay_path(proj), 'prepare with keeps the work dir'
	line_overlay := app.prepare_line_info_overlay(main_file, proj) or {
		assert false, 'line info overlay must succeed: ${err}'
		return
	}
	defer {
		os.rmdir_all(line_overlay.temp_root) or {}
	}
	assert os.read_file(line_overlay.temp_source_file) or { '' } == unsaved, 'line info overlay keeps the buffer'
	// A work dir outside the source tree cannot hold the file.
	if _ := app.prepare_compilation_overlay_with(main_file, os.join_path(base, 'elsewhere'), map[string]string{}) {
		assert false, 'an outside work dir must fail'
	} else {
		assert true, 'an outside work dir fails'
	}
}

fn test_cov_program_open_files_maps_program_members() {
	base := os.join_path(os.temp_dir(), 'vls_cov_progfiles_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	other_dir := os.join_path(base, 'other')
	interop_test_must_mkdir_all(other_dir)
	defer {
		os.rmdir_all(base) or {}
	}
	main_file := os.join_path(base, 'main.v')
	other_file := os.join_path(base, 'other.v')
	far_file := os.join_path(other_dir, 'far.v')
	for path in [main_file, other_file, far_file] {
		interop_test_must_write_file(path, 'module main\n')
	}
	main_uri := path_to_uri(main_file)
	other_uri := path_to_uri(other_file)
	far_uri := path_to_uri(far_file)
	mut app := &App{
		open_files: {
			main_uri:  'module main\n'
			other_uri: 'module main\n'
			far_uri:   'module main\n'
		}
	}
	overlay := CompilationOverlay{
		source_root:      normalize_overlay_path(base)
		temp_work_dir:    normalize_overlay_path(base)
		source_work_dir:  normalize_overlay_path(base)
		temp_source_file: normalize_overlay_path(main_file)
	}
	got := app.program_open_files(normalize_overlay_path(main_file), overlay)
	assert got.len == 1, 'only the other program file is mapped, got ${got.len}'
	assert got[normalized_index_path(normalize_overlay_path(other_file))] == other_uri, 'the other file maps to its uri'
}

fn test_cov_split_check_errors_single_and_program_paths() {
	base := os.join_path(os.temp_dir(), 'vls_cov_split_${os.getpid()}')
	src := os.join_path(base, 'src')
	overlay_root := os.join_path(base, 'overlay')
	interop_test_must_mkdir_all(src)
	interop_test_must_mkdir_all(overlay_root)
	defer {
		os.rmdir_all(base) or {}
	}
	main_src := os.join_path(src, 'main.v')
	other_src := os.join_path(src, 'other.v')
	interop_test_must_write_file(main_src, 'module main\n')
	interop_test_must_write_file(other_src, 'module main\n')
	main_tmp := os.join_path(overlay_root, 'main.v')
	other_tmp := os.join_path(overlay_root, 'other.v')
	interop_test_must_write_file(main_tmp, 'module main\n')
	interop_test_must_write_file(other_tmp, 'module main\n')
	single_out := '${main_src}:2:3: error: boom\n'
	single := split_check_errors(single_out, src, main_src, false, CompilationOverlay{}, main_src, map[string]string{},
		src)
	assert single.file.len == 1, 'single-file output keeps its diagnostic'
	assert single.parsed == 1, 'single-file parsed counts the diagnostic'
	assert single.file[0].message == 'boom', 'single-file message is kept'
	overlay := CompilationOverlay{
		source_root:         normalize_overlay_path(src)
		source_display_root: normalize_overlay_path(src)
		temp_root:           normalize_overlay_path(overlay_root)
		source_work_dir:     normalize_overlay_path(src)
		temp_work_dir:       normalize_overlay_path(overlay_root)
		temp_source_file:    normalize_overlay_path(main_tmp)
	}
	other_uri := 'file:///other.v'
	program_uris := {
		normalized_index_path(normalize_overlay_path(other_src)): other_uri
	}
	multi_out := '${main_tmp}:2:3: error: boom\n${other_tmp}:4:1: warning: slow\n'
	multi := split_check_errors(multi_out, overlay_root, main_tmp, true, overlay, main_src,
		program_uris, overlay_root)
	assert multi.parsed == 2, 'program output parses both diagnostics, got ${multi.parsed}'
	assert multi.file.len == 1, 'only the requested file is kept, got ${multi.file.len}'
	assert multi.file[0].path == main_src, 'kept errors point at the real path'
	assert multi.program[other_uri].len == 1, 'the other program file gets its diagnostic'
	assert multi.program[other_uri][0].level == 'warning', 'levels survive the split'
}

fn test_cov_new_overlay_copy_budget_and_try_reserve() {
	mut budget := new_overlay_copy_budget()
	assert budget.max_files == 4096, 'the file cap is 4096'
	assert budget.max_bytes == u64(64 * 1024 * 1024), 'the byte cap is 64MiB'
	base := os.join_path(os.temp_dir(), 'vls_cov_budget_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	small := os.join_path(base, 'small.v')
	content := 'module main\n'
	interop_test_must_write_file(small, content)
	assert budget.try_reserve(small), 'a small file fits the budget'
	assert budget.files == 1, 'the file count moves'
	assert budget.bytes == u64(content.len), 'the byte count moves'
	mut tiny := OverlayCopyBudget{
		max_files: 1
		max_bytes: 1024
	}
	assert tiny.try_reserve(small), 'one file fits a cap of one'
	assert !tiny.try_reserve(small), 'a second file breaks the file cap'
	mut bytes := OverlayCopyBudget{
		max_files: 10
		max_bytes: 4
	}
	assert !bytes.try_reserve(small), 'an over-size file breaks the byte cap'
	assert bytes.bytes == 0, 'a refused reservation moves nothing'
}

fn test_cov_overlay_path_in_and_has_descendant_wrappers() {
	assert overlay_path_in('src/main.v', ['src/main.v']), 'an exact path is in the set'
	assert !overlay_path_in('src/other.v', ['src/main.v']), 'another path is not in the set'
	assert overlay_path_has_descendant('src', ['src/main.v']), 'a parent has a descendant in the set'
	assert !overlay_path_has_descendant('src/main.v', ['src']), 'a file has no descendant in a parent set'
	assert !overlay_path_in('src/main.v', []), 'an empty set contains nothing'
}

fn test_cov_create_links_and_materialize_overlay_file() {
	base := os.join_path(os.temp_dir(), 'vls_cov_links_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	source := os.join_path(base, 'source.v')
	interop_test_must_write_file(source, 'module main\n')
	linked := os.join_path(base, 'linked.v')
	create_overlay_symlink(source, linked) or {
		// Symlinks need privileges on some machines; the fallback below is the
		// portable assertion.
		return
	}
	assert os.exists(linked), 'a symlinked overlay entry exists'
	hard := os.join_path(base, 'hard.v')
	create_overlay_hard_link(source, hard) or {
		assert false, 'a hard link must be created: ${err}'
		return
	}
	assert os.is_file(hard), 'a hard-linked overlay entry is a file'
	mut budget := new_overlay_copy_budget()
	materialized := materialize_overlay_file(source, os.join_path(base, 'mat.v'), mut budget) or {
		assert false, 'materialize must succeed: ${err}'
		return
	}
	assert materialized, 'a linkable file materializes'
	assert budget.files == 0, 'a linked file costs no budget'
	mut empty := OverlayCopyBudget{
		max_files: 0
		max_bytes: 0
	}
	denied := materialize_overlay_file_with_linker(source, os.join_path(base, 'denied.v'), deny_overlay_symlink, mut
		empty) or {
		assert false, 'an exhausted budget must not fail: ${err}'
		return
	}
	assert !denied, 'an exhausted budget skips the file'
	assert !os.exists(os.join_path(base, 'denied.v')), 'a skipped file is not written'
}

fn test_cov_local_import_rel_dirs_closure() {
	base := os.join_path(os.temp_dir(), 'vls_cov_imports_${os.getpid()}')
	root := os.join_path(base, 'proj')
	interop_test_must_mkdir_all(os.join_path(root, 'mathutil', 'inner'))
	defer {
		os.rmdir_all(base) or {}
	}
	main_content := 'module main\n\nimport mathutil\n'
	interop_test_must_write_file(os.join_path(root, 'main.v'), main_content)
	interop_test_must_write_file(os.join_path(root, 'mathutil', 'mathutil.v'), 'module mathutil\n\nimport mathutil.inner\n')
	interop_test_must_write_file(os.join_path(root, 'mathutil', 'inner', 'inner.v'), 'module inner\n')
	main_uri := path_to_uri(os.join_path(root, 'main.v'))
	tracked := {
		main_uri: main_content
	}
	got := local_import_rel_dirs(normalize_overlay_path(root), normalize_overlay_path(root), tracked)
	assert 'mathutil' in got, 'a directly imported module is found: ${got}'
	assert 'mathutil/inner' in got, 'a transitively imported module is found: ${got}'
	empty := local_import_rel_dirs(normalize_overlay_path(root), normalize_overlay_path(root), map[string]string{})
	assert empty.len == 0, 'no buffers means no imports'
}

fn test_cov_parse_embed_and_vmodroot_paths() {
	content := 'module main\n\nconst a = \$embed_file(\'assets/a.json\')\nconst b = \$embed_file( "assets/b.txt" )\nconst c = \$embed_file(r\'assets/c.dat\')\n'
	embed := parse_embed_file_literal_paths(content)
	assert embed == ['assets/a.json', 'assets/b.txt', 'assets/c.dat'], 'quoted embed paths are read: ${embed}'
	assert parse_embed_file_literal_paths('no marker here') == [], 'missing markers give nothing'
	assert parse_embed_file_literal_paths('\$embed_file without a call') == [], 'a bare marker gives nothing'
	flagged := "module main\n#flag -I @VMODROOT/thirdparty/native\n// uses @VMODROOT/thirdparty/lib/lib.h\nconst x = \$embed_file('thirdparty/native/embedded.json')"
	thirdparty := parse_vmodroot_thirdparty_paths(flagged)
	assert thirdparty == ['@VMODROOT/thirdparty/native', '@VMODROOT/thirdparty/lib/lib.h'], 'vmodroot references are read: ${thirdparty}'
	assert parse_vmodroot_thirdparty_paths('nothing here') == [], 'missing vmodroot markers give nothing'
}

fn test_cov_resolve_thirdparty_overlay_reference_cases() {
	base := os.join_path(os.temp_dir(), 'vls_cov_third_${os.getpid()}')
	root := os.join_path(base, 'proj')
	lib := os.join_path(root, 'thirdparty', 'lib')
	interop_test_must_mkdir_all(lib)
	defer {
		os.rmdir_all(base) or {}
	}
	header := os.join_path(lib, 'lib.h')
	interop_test_must_write_file(header, '#define X 1\n')
	source_file := os.join_path(root, 'main.v')
	interop_test_must_write_file(source_file, 'module main\n')
	if got := resolve_thirdparty_overlay_reference('@VMODROOT/thirdparty/lib/lib.h', source_file, normalize_overlay_path(root)) {
		assert got == 'thirdparty/lib/lib.h', 'vmodroot references resolve, got ${got}'
	} else {
		assert false, 'a present thirdparty file must resolve'
	}
	if got := resolve_thirdparty_overlay_reference('thirdparty/lib/lib.h', source_file, normalize_overlay_path(root)) {
		assert got == 'thirdparty/lib/lib.h', 'relative references resolve from the source dir, got ${got}'
	} else {
		assert false, 'a relative thirdparty file must resolve'
	}
	if _ := resolve_thirdparty_overlay_reference('@VMODROOT/thirdparty/lib/missing.h', source_file, normalize_overlay_path(root)) {
		assert false, 'a missing thirdparty file must be none'
	} else {
		assert true, 'a missing thirdparty file is none'
	}
	if _ := resolve_thirdparty_overlay_reference('/abs/thirdparty/lib/lib.h', source_file, normalize_overlay_path(root)) {
		assert false, 'an absolute reference must be none'
	} else {
		assert true, 'an absolute reference is none'
	}
	if _ := resolve_thirdparty_overlay_reference('@VEXEROOT/thirdparty/lib/lib.h', source_file, normalize_overlay_path(root)) {
		assert false, 'a vexeroot reference must be none'
	} else {
		assert true, 'a vexeroot reference is none'
	}
	interop_test_must_write_file(os.join_path(root, 'plain.v'), 'module main\n')
	if _ := resolve_thirdparty_overlay_reference('plain.v', source_file, normalize_overlay_path(root)) {
		assert false, 'a non-thirdparty reference must be none'
	} else {
		assert true, 'a non-thirdparty reference is none'
	}
}

fn test_cov_referenced_thirdparty_rel_paths_collects() {
	base := os.join_path(os.temp_dir(), 'vls_cov_refthird_${os.getpid()}')
	root := os.join_path(base, 'proj')
	lib := os.join_path(root, 'thirdparty', 'lib')
	interop_test_must_mkdir_all(lib)
	defer {
		os.rmdir_all(base) or {}
	}
	interop_test_must_write_file(os.join_path(lib, 'embedded.json'), '{}\n')
	main_content := "module main\n#flag -I @VMODROOT/thirdparty/lib\nconst x = \$embed_file('thirdparty/lib/embedded.json')\n"
	main_file := os.join_path(root, 'main.v')
	interop_test_must_write_file(main_file, main_content)
	got := referenced_thirdparty_rel_paths(normalize_overlay_path(root), normalize_overlay_path(root), {
		path_to_uri(main_file): main_content
	}, []string{})
	assert got.contains('thirdparty/lib/embedded.json'), 'embed references are collected: ${got}'
	assert got == got.clone().sorted(), 'references are sorted'
}

fn test_cov_is_overlay_compilation_file_suffixes() {
	assert is_overlay_compilation_file('v.mod'), 'the manifest is a compilation file'
	assert is_overlay_compilation_file('main.v'), '.v is a compilation file'
	assert is_overlay_compilation_file('run.vsh'), '.vsh is a compilation file'
	assert is_overlay_compilation_file('native.h'), '.h is a compilation file'
	assert is_overlay_compilation_file('lib.a'), '.a is a compilation file'
	assert !is_overlay_compilation_file('notes.txt'), '.txt is an asset'
	assert !is_overlay_compilation_file('data.json'), '.json is an asset'
	assert !is_overlay_compilation_file('README.md'), '.md is an asset'
}

fn test_cov_copy_bounded_overlay_entry_pass_cycle_and_filter() {
	base := os.join_path(os.temp_dir(), 'vls_cov_pass_${os.getpid()}')
	src := os.join_path(base, 'src')
	dst := os.join_path(base, 'dst')
	interop_test_must_mkdir_all(os.join_path(src, '.git'))
	interop_test_must_mkdir_all(dst)
	defer {
		os.rmdir_all(base) or {}
	}
	interop_test_must_write_file(os.join_path(src, 'main.v'), 'module main\n')
	interop_test_must_write_file(os.join_path(src, 'notes.txt'), 'asset\n')
	interop_test_must_write_file(os.join_path(src, '.git', 'hidden.v'), 'module hidden\n')
	mut budget := new_overlay_copy_budget()
	mut visited := map[string]bool{}
	compilation := copy_bounded_overlay_entry_pass(src, dst, true, mut budget, mut visited) or {
		assert false, 'the compilation pass must succeed: ${err}'
		return
	}
	assert compilation == 1, 'only the .v file copies in the compilation pass, got ${compilation}'
	assert os.is_file(os.join_path(dst, 'main.v')), 'the compilation file lands'
	assert !os.exists(os.join_path(dst, '.git', 'hidden.v')), 'excluded dirs never copy'
	again := copy_bounded_overlay_entry_pass(src, dst, true, mut budget, mut visited) or {
		assert false, 'a repeated pass must succeed: ${err}'
		return
	}
	assert again == 0, 'visited dirs and existing targets copy nothing, got ${again}'
	mut assets_visited := map[string]bool{}
	assets := copy_bounded_overlay_entry_pass(src, os.join_path(base, 'assets'), false, mut budget, mut
		assets_visited) or {
		assert false, 'the asset pass must succeed: ${err}'
		return
	}
	assert assets == 1, 'only the asset copies in the asset pass, got ${assets}'
}

fn test_cov_materialize_referenced_thirdparty_inputs_copies() {
	base := os.join_path(os.temp_dir(), 'vls_cov_matthird_${os.getpid()}')
	src := os.join_path(base, 'src')
	dst := os.join_path(base, 'dst')
	lib := os.join_path(src, 'thirdparty', 'lib')
	interop_test_must_mkdir_all(lib)
	interop_test_must_mkdir_all(dst)
	defer {
		os.rmdir_all(base) or {}
	}
	interop_test_must_write_file(os.join_path(lib, 'lib.v'), 'module lib\n')
	interop_test_must_write_file(os.join_path(lib, 'notes.txt'), 'asset\n')
	mut budget := new_overlay_copy_budget()
	materialize_referenced_thirdparty_inputs(normalize_overlay_path(src), os.join_path(dst, ''), [
		'thirdparty/lib',
	], mut budget) or {
		assert false, 'materialize must succeed: ${err}'
		return
	}
	assert os.is_file(os.join_path(dst, 'thirdparty', 'lib', 'lib.v')), 'referenced compilation inputs copy'
	assert !os.exists(os.join_path(dst, 'thirdparty', 'lib', 'notes.txt')), 'assets do not copy for dir references'
}

fn test_cov_own_overlay_dirs_creates_missing_chain() {
	base := os.join_path(os.temp_dir(), 'vls_cov_own_${os.getpid()}')
	src := os.join_path(base, 'src')
	tmp := os.join_path(base, 'tmp')
	interop_test_must_mkdir_all(os.join_path(src, 'a', 'b'))
	interop_test_must_mkdir_all(tmp)
	defer {
		os.rmdir_all(base) or {}
	}
	mut budget := new_overlay_copy_budget()
	owned := own_overlay_dirs(normalize_overlay_path(src), tmp, 'a/b', mut budget) or {
		assert false, 'own must succeed: ${err}'
		return
	}
	assert owned.len == 0, 'created dirs need no link replacement, got ${owned}'
	assert os.is_dir(os.join_path(tmp, 'a', 'b')), 'the missing chain is created'
}

fn test_cov_compiler_hover_augments_and_falls_back() {
	payload := '{"contents":{"kind":"markdown","value":"fn helper()"}}'
	payload_hover := compiler_hover(payload, '')
	assert payload_hover is Hover, 'a compiler payload answers hover'
	augmented := compiler_hover(payload, 'extra docs')
	assert augmented is Hover, 'augmented hover stays hover'
	if augmented is Hover {
		assert (augmented as Hover).contents.value.contains('fn helper()'), 'the compiler value is kept'
		assert (augmented as Hover).contents.value.contains('extra docs'), 'missing docs are appended'
	}
	unchanged := compiler_hover(payload, 'fn helper()')
	assert unchanged is Hover, 'unchanged hover stays hover'
	if unchanged is Hover {
		assert !(unchanged as Hover).contents.value.contains('\n\nfn helper()'), 'present docs are not duplicated'
	}
	doc_only := compiler_hover('{}', 'vdoc comment')
	assert doc_only is Hover, 'docs alone answer hover'
	if doc_only is Hover {
		assert (doc_only as Hover).contents.value == 'vdoc comment', 'docs alone answer hover'
	}
	assert compiler_hover('', '') == ResponseResult('null'), 'no payload and no docs answer null'
}

fn test_cov_line_info_result_branches() {
	base := os.join_path(os.temp_dir(), 'vls_cov_lires_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	source := os.join_path(base, 'main.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	interop_test_must_write_file(source, content)
	uri := path_to_uri(source)
	mut app := &App{
		open_files: {
			uri: content
		}
	}
	overlay := CompilationOverlay{}
	completion := app.line_info_result(.completion, uri, '6:1', '{"details":[{"label":"println","kind":3},{"label":"+op","kind":3}]}',
		false, '', overlay, '')
	if completion is []Detail {
		assert (completion as []Detail).len == 1, 'operator completions are filtered'
		assert (completion as []Detail)[0].label == 'println', 'code completions are kept'
	} else {
		assert false, 'completion must decode to details'
	}
	assert app.line_info_result(.signature_help, uri, '1:1', '{"signatures":[]}', false, '', overlay,
		'') == ResponseResult('null'), 'an empty signature answers null'
	sig := app.line_info_result(.signature_help, uri, '1:1', '{"signatures":[{"label":"fn f()","parameters":[]}],"activeSignature":0}',
		false, '', overlay, '')
	assert sig is SignatureHelp, 'a found signature answers help'
	hover := app.line_info_result(.hover, uri, '4:hv^1', '{"contents":{"kind":"markdown","value":"fn helper()"}}',
		false, '', overlay, '')
	assert hover is Hover, 'a compiler hover answers hover'
	assert app.line_info_result(.inlay_hint, uri, '1:1', '', false, '', overlay, '') == ResponseResult('null'), 'an empty inlay answer is null'
	hints := app.line_info_result(.inlay_hint, uri, '1:1', '{"inlay_hints":[{"line":0,"col":1,"label":": int","kind":1,"tooltip":""}]}',
		false, '', overlay, '')
	assert hints is []InlayHint, 'inlay payload decodes to hints'
	assert app.line_info_result(.definition, uri, '1:1', '', false, '', overlay, '') == ResponseResult('null'), 'an empty definition is null'
	definition := app.line_info_result(.definition, uri, '1:1', '${source}:3:5', false, '', overlay,
		'')
	assert definition is Location, 'a definition maps to a location'
	if definition is Location {
		assert (definition as Location).uri == uri, 'the definition reuses the open uri'
		assert (definition as Location).range.start.line == 2, 'definition lines are zero-based'
	}
}

fn test_cov_run_v_argv_cancelled_branches() {
	cancelled := run_v_argv_cancelled(['-check', '.'], '', fn () bool {
		return true
	})
	assert cancelled.exit_code == diagnostics_check_cancelled, 'a cancelled check reports cancellation'
	missing_dir := os.join_path(os.temp_dir(), 'vls_cov_nodir_${os.getpid()}')
	missing := run_v_argv_cancelled(['-check', '.'], missing_dir, fn () bool {
		return false
	})
	assert missing.exit_code != 0, 'a missing work dir fails'
	assert missing.output.contains('Working dir does not exist'), 'a missing work dir is reported'
	previous := os.getenv('VLS_V_COMMAND')
	defer {
		restore_v_command(previous)
	}
	os.setenv('VLS_V_COMMAND', os.join_path(os.temp_dir(), 'vls_cov_no_compiler_${os.getpid()}'), true)
	base := os.join_path(os.temp_dir(), 'vls_cov_argv_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	gone := run_v_argv_cancelled(['-check', '.'], base, fn () bool {
		return false
	})
	assert gone.exit_code != 0, 'a missing compiler fails'
	assert gone.output.contains('not found'), 'a missing compiler is reported: ${gone.output}'
}

fn test_cov_run_v_line_info_once_singlefile_via_stub() {
	$if windows {
		// The stand-in compiler is a POSIX shell script.
		return
	}
	previous := os.getenv('VLS_V_COMMAND')
	mut app, uri, root := line_info_stub_app('vls_cov_once', compat_matrix_modern_direct_stub)
	defer {
		restore_v_command(previous)
		os.rmdir_all(root) or {}
	}
	work_dir := os.dir(uri_to_path(uri))
	result := app.run_v_line_info_once(.hover, uri, '6:hv^4', work_dir)
	assert app.line_info_mode == .direct, 'a direct compiler probes direct'
	assert result is Hover, 'a direct single-file lookup answers hover'
	if result is Hover {
		assert (result as Hover).contents.value.contains('fn helper()'), 'the stub payload is kept'
	}
}

fn test_cov_run_v_line_info_pooled_returns_none_without_pool() {
	mut compat_app := App{
		line_info_mode: .compat
	}
	if _ := compat_app.run_v_line_info_pooled(.hover, 'file:///tmp/x.v', '1:hv^1') {
		assert false, 'compat mode never uses the pool'
	} else {
		assert true, 'compat mode skips the pool'
	}
	mut missing_app := App{
		line_info_mode: .missing
	}
	if _ := missing_app.run_v_line_info_pooled(.hover, 'file:///tmp/x.v', '1:hv^1') {
		assert false, 'missing mode never uses the pool'
	} else {
		assert true, 'missing mode skips the pool'
	}
}

fn test_cov_names_a_local_detects_locals() {
	content := 'module main\n\nfn main() {\n\tx := 1\n\tprintln(x)\n}\n'
	line := '\tprintln(x)'
	mut app := App{}
	at_use := Position{
		line: 4
		char: 10
	}
	assert app.names_a_local(content, line, 'x', at_use), 'a use names its local'
	assert !app.names_a_local(content, line, 'zzz', at_use), 'an unknown name is not a local'
	params := 'module main\n\nfn greet(name string) {\n\tprintln(name)\n}\n'
	param_line := '\tprintln(name)'
	param_pos := Position{
		line: 3
		char: 14
	}
	assert app.names_a_local(params, param_line, 'name', param_pos), 'a use names its parameter'
}

fn test_cov_diag_cache_base_dir_override_and_default() {
	previous := os.getenv('VLS_DIAG_CACHE_DIR')
	defer {
		restore_diag_cache_dir(previous)
	}
	custom := os.join_path(os.temp_dir(), 'vls_cov_cachebase_${os.getpid()}')
	os.setenv('VLS_DIAG_CACHE_DIR', custom, true)
	assert diag_cache_base_dir() == custom, 'an override wins'
	os.unsetenv('VLS_DIAG_CACHE_DIR')
	assert diag_cache_base_dir() == os.join_path(os.cache_dir(), 'vls', 'check-diag'), 'the default joins the cache dir'
}

fn test_cov_code_lens_complete_utf8_prefix_len_boundaries() {
	assert code_lens_complete_utf8_prefix_len('') == 0, 'empty input gives 0'
	assert code_lens_complete_utf8_prefix_len('abc') == 3, 'ascii is complete'
	full := 'abé'
	assert code_lens_complete_utf8_prefix_len(full) == full.len, 'a complete multi-byte tail is kept'
	truncated := full[..full.len - 1]
	assert code_lens_complete_utf8_prefix_len(truncated) == 2, 'a split multi-byte tail is cut, got ${code_lens_complete_utf8_prefix_len(truncated)}'
	emoji := 'a🙂'
	assert code_lens_complete_utf8_prefix_len(emoji) == emoji.len, 'a complete emoji is kept'
	cut_emoji := emoji[..emoji.len - 1]
	assert code_lens_complete_utf8_prefix_len(cut_emoji) == 1, 'a split emoji is cut'
}

fn test_cov_v_source_code_mask_hides_strings_and_comments() {
	mask := v_source_code_mask('a "b" c')
	mask_str := mask.bytestr()
	assert mask.len == 'a "b" c'.len, 'the mask keeps the length'
	assert mask_str[0..1] == 'a', 'code before a string is kept'
	assert mask_str[6..7] == 'c', 'code after a string is kept'
	assert mask_str[2..5] == '   ', 'string contents are hidden: ${mask_str}'
	line_mask := v_source_code_mask('code // comment\nnext')
	line_str := line_mask.bytestr()
	assert line_str.contains('code'), 'code before a comment is kept'
	assert !line_str.contains('comment'), 'line comments are hidden: ${line_str}'
	assert line_str.contains('\n'), 'newlines survive the mask'
	block_mask := v_source_code_mask('/* hidden */ code')
	block_str := block_mask.bytestr()
	assert block_str.ends_with('code'), 'code after a block comment is kept'
	assert !block_str.contains('hidden'), 'block comments are hidden: ${block_str}'
	interp_mask := v_source_code_mask("'\${x}y'")
	interp_str := interp_mask.bytestr()
	assert interp_str.contains('x'), 'interpolations stay visible: ${interp_str}'
}

fn test_cov_code_lens_mask_token_and_hash_directive() {
	source := 'println(@FILE) @FILEX'
	mask := v_source_code_mask(source)
	at := source.index('@FILE') or { -1 }
	assert at >= 0, 'the fixture contains @FILE'
	assert code_lens_mask_has_at_token(mask, at, '@FILE'), '@FILE matches at its position'
	assert !code_lens_mask_has_at_token(mask, at + 1, '@FILE'), '@FILE does not match off by one'
	assert !code_lens_mask_has_at_token(mask, mask.len - 2, '@FILE'), 'a token past the end never matches'
	second := source.last_index('@FILE') or { -1 }
	assert !code_lens_mask_has_at_token(mask, second, '@FILE'), '@FILEX is not @FILE'
	hash_source := '#flag -I @VMODROOT/x\nprintln(@FILE)'
	hash_mask := v_source_code_mask(hash_source)
	hash_at := hash_source.index('@VMODROOT') or { -1 }
	plain_at := hash_source.index('@FILE') or { -1 }
	assert code_lens_token_is_in_hash_directive(hash_mask, hash_at), 'a flag token sits in a hash directive'
	assert !code_lens_token_is_in_hash_directive(hash_mask, plain_at), 'a call token is not a directive'
}

fn test_cov_code_lens_run_target_and_executable_and_args() {
	base := os.join_path(os.temp_dir(), 'vls_cov_target_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	path := os.join_path(base, 'main.v')
	interop_test_must_write_file(path, 'module main\n')
	holder := App{}
	mut main_job := CodeLensRunJob{
		kind:        .main
		title:       'Run Main'
		uri:         path_to_uri(path)
		path:        path
		open_files:  map[string]string{}
		write_mutex: holder.write_mutex
	}
	main_target := code_lens_run_target(main_job)
	assert main_target.starts_with('main:'), 'main jobs tag main: ${main_target}'
	assert main_target.ends_with(':${main_job.fn_name}'), 'the target carries the function name'
	file_job := CodeLensRunJob{
		kind:        .test_file
		title:       'Run File'
		uri:         path_to_uri(path)
		path:        path
		open_files:  map[string]string{}
		write_mutex: holder.write_mutex
	}
	assert code_lens_run_target(file_job).starts_with('test-file:'), 'file jobs tag test-file'
	fn_job := CodeLensRunJob{
		kind:        .test_function
		title:       'Run Test'
		uri:         path_to_uri(path)
		path:        path
		fn_name:     'test_one'
		open_files:  map[string]string{}
		write_mutex: holder.write_mutex
	}
	fn_target := code_lens_run_target(fn_job)
	assert fn_target.starts_with('test-function:'), 'function jobs tag test-function: ${fn_target}'
	assert fn_target.ends_with(':test_one'), 'function targets carry the test name: ${fn_target}'
	exe := code_lens_executable_path(base)
	assert exe.contains('code_lens_program'), 'the executable is named: ${exe}'
	$if windows {
		assert exe.ends_with('.exe'), 'windows executables carry .exe: ${exe}'
	} $else {
		assert !exe.ends_with('.exe'), 'posix executables carry no .exe: ${exe}'
	}
	assert code_lens_compile_args(main_job, path, exe) == build_v_run_compile_args(exe), 'main compiles as a run'
	assert code_lens_compile_args(file_job, path, exe) == build_v_test_compile_args(path, '', exe), 'a file compiles as a test file'
	assert code_lens_compile_args(fn_job, path, exe) == build_v_test_compile_args(path, 'test_one', exe), 'a function compiles with -run-only'
	assert code_lens_display_args(main_job) == build_v_run_args(), 'main displays as a run'
	assert code_lens_display_args(file_job) == build_v_test_args(path, ''), 'a file displays as a test file'
	assert code_lens_display_args(fn_job) == build_v_test_args(path, 'test_one'), 'a function displays with -run-only'
}

fn test_cov_run_command_manager_lifecycle() {
	mut manager := new_run_command_manager()
	assert manager.next_id == 0, 'a fresh manager has no ids'
	base := os.join_path(os.temp_dir(), 'vls_cov_mgr_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	path := os.join_path(base, 'main.v')
	interop_test_must_write_file(path, 'module main\n')
	holder := App{}
	job := CodeLensRunJob{
		kind:        .main
		title:       'Run Main'
		uri:         path_to_uri(path)
		path:        path
		open_files:  map[string]string{}
		write_mutex: holder.write_mutex
	}
	target := code_lens_run_target(job)
	id, accepted := manager.begin_job(target)
	assert accepted, 'a fresh target is accepted'
	assert !manager.job_is_cancelled(id, target), 'a fresh job is not cancelled'
	manager.cancel_process_locked(id)
	assert !manager.job_is_cancelled(id, target), 'an empty cancel changes nothing'
	id2, accepted2 := manager.begin_job(target)
	assert accepted2, 'a newer run for the same target is accepted'
	assert manager.job_is_cancelled(id, target), 'the older run is cancelled'
	assert !manager.job_is_cancelled(id2, target), 'the newer run is current'
	mut dummy := os.new_process('v')
	assert !manager.register_process(999, target, dummy), 'an unknown id never registers'
	assert manager.register_process(id2, target, dummy), 'the current id registers'
	manager.unregister_process(id2)
	assert !manager.job_is_cancelled(id2, target), 'unregistering keeps the target current'
	manager.finish_job(id, target)
	manager.finish_job(id2, target)
	assert manager.job_is_cancelled(id2, target), 'a finished target reads as cancelled'
	// A stopped manager refuses every new worker without spawning anything.
	manager.cancel_all_and_wait()
	_, refused := manager.begin_job(target)
	assert !refused, 'a stopped manager refuses new jobs'
	assert !manager.launch(job), 'a stopped manager refuses launches'
	assert manager.run_sync(job) == [], 'a stopped manager runs nothing synchronously'
	assert manager.job_is_cancelled(id2, target), 'a stopped manager cancels everything'
	mut stopped_dummy := os.new_process('v')
	assert !manager.register_process(id2, target, stopped_dummy), 'a stopped manager registers nothing'
}

fn test_cov_run_managed_process_cancelled_and_missing_dir() {
	mut manager := new_run_command_manager()
	base := os.join_path(os.temp_dir(), 'vls_cov_managed_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	target := 'main:4:${base}:'
	old_id, _ := manager.begin_job(target)
	new_id, _ := manager.begin_job(target)
	stale := run_managed_process(mut manager, old_id, target, 'v', [], base)
	assert stale.cancelled, 'a replaced job is cancelled without spawning'
	assert stale.result.exit_code == 0, 'a cancelled job carries no result'
	missing := run_managed_process(mut manager, new_id, target, 'v', [], os.join_path(base, 'no-such-dir'))
	assert !missing.cancelled, 'a current job is not cancelled'
	assert missing.result.exit_code != 0, 'a missing work dir fails'
	assert missing.result.output.contains('Working dir does not exist'), 'a missing work dir is reported'
	manager.finish_job(old_id, target)
	manager.finish_job(new_id, target)
	manager.cancel_all_and_wait()
}

fn test_cov_log_code_lens_output_and_get_manager() {
	mut worker := App{
		capture_output: true
	}
	overlay := CompilationOverlay{
		source_display_root: '/src/proj'
		temp_root:           '/tmp/overlay'
	}
	log_code_lens_output(mut worker, os.Result{
		exit_code: 0
		output:    'built /tmp/overlay/main.v\n'
	}, overlay)
	assert worker.captured_output.len == 1, 'compiler output is logged'
	assert worker.captured_output[0].contains('/src/proj/main.v'), 'overlay paths map back to sources'
	assert worker.captured_output[0].contains('logMessage'), 'output goes to the log channel'
	mut quiet := App{
		capture_output: true
	}
	log_code_lens_output(mut quiet, os.Result{
		exit_code: 0
	}, overlay)
	assert quiet.captured_output.len == 0, 'empty output logs nothing'
	mut app := App{}
	first := app.get_run_command_manager()
	second := app.get_run_command_manager()
	first.cancel_all_and_wait()
	_, accepted := second.begin_job('probe')
	assert !accepted, 'both handles are the same manager'
	app.stop_run_commands()
}

fn test_cov_preserve_code_lens_overlay_rewrites_pseudos() {
	base := os.join_path(os.temp_dir(), 'vls_cov_pseudo_${os.getpid()}')
	src := os.join_path(base, 'src')
	tmp := os.join_path(base, 'tmp')
	interop_test_must_mkdir_all(src)
	interop_test_must_mkdir_all(tmp)
	defer {
		os.rmdir_all(base) or {}
	}
	source := 'module main\n\nfn main() {\n\tprintln(@FILE)\n}\n'
	source_path := os.join_path(src, 'main.v')
	interop_test_must_write_file(source_path, source)
	temp_path := os.join_path(tmp, 'main.v')
	interop_test_must_write_file(temp_path, source)
	overlay := CompilationOverlay{
		source_root:         normalize_overlay_path(src)
		source_display_root: normalize_overlay_path(src)
		temp_root:           normalize_overlay_path(tmp)
		source_work_dir:     normalize_overlay_path(src)
		temp_work_dir:       normalize_overlay_path(tmp)
		temp_source_file:    normalize_overlay_path(temp_path)
	}
	open_sources := {
		normalize_overlay_path(source_path): source
	}
	preserve_code_lens_overlay_dir(overlay, normalize_overlay_path(tmp), open_sources) or {
		assert false, 'preserve dir must succeed: ${err}'
		return
	}
	rewritten := os.read_file(temp_path) or { '' }
	assert !rewritten.contains('@FILE'), 'pseudos are rewritten: ${rewritten}'
	assert rewritten.contains('main.v'), 'the real file name survives: ${rewritten}'
	// The map form derives the same sources from open files.
	interop_test_must_write_file(temp_path, source)
	preserve_code_lens_overlay_source_paths(overlay, {
		path_to_uri(source_path): source
	}) or {
		assert false, 'preserve paths must succeed: ${err}'
		return
	}
	again := os.read_file(temp_path) or { '' }
	assert !again.contains('@FILE'), 'the map form rewrites too: ${again}'
}

fn test_cov_run_code_lens_job_cancelled_and_start_refused() {
	mut manager := new_run_command_manager()
	base := os.join_path(os.temp_dir(), 'vls_cov_codelens_${os.getpid()}')
	interop_test_must_mkdir_all(base)
	defer {
		os.rmdir_all(base) or {}
	}
	path := os.join_path(base, 'main.v')
	interop_test_must_write_file(path, 'module main\n\nfn main() {}\n')
	holder := App{}
	job := CodeLensRunJob{
		kind:           .main
		title:          'Run Main'
		uri:            path_to_uri(path)
		path:           path
		open_files:     map[string]string{}
		write_mutex:    holder.write_mutex
		capture_output: true
	}
	target := code_lens_run_target(job)
	old_id, _ := manager.begin_job(target)
	new_id, _ := manager.begin_job(target)
	out := run_code_lens_job(mut manager, old_id, target, job)
	assert out.len == 1, 'a cancelled job only keeps its start log line: ${out}'
	assert out[0].contains('Run Main'), 'the start log names the job: ${out[0]}'
	assert !out[0].contains('showMessage'), 'a cancelled job sends no show message'
	// run_code_lens_job already finished old_id; only the replacing job is left.
	manager.finish_job(new_id, target)
	// A stopping server refuses new runs with a message instead of spawning.
	mut app := App{
		capture_output: true
	}
	app.run_command_manager = new_run_command_manager()
	app.get_run_command_manager().cancel_all_and_wait()
	app.start_code_lens_run(job)
	assert app.captured_output.len == 1, 'a refused start tells the client'
	assert app.captured_output[0].contains('cannot start'), 'the refusal names the problem: ${app.captured_output[0]}'
	app.stop_run_commands()
}
