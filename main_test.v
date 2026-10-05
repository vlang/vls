// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time

fn main_test_temp_dir(tag string) string {
	dir := os.join_path(os.temp_dir(), 'vls_find_v_dir_${tag}_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(dir) or {
		assert false, 'Failed to create ${dir}: ${err}'
		return dir
	}
	return os.real_path(dir)
}

fn main_test_write(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'Failed to write ${path}: ${err}'
	}
}

// The plain case: the executable sits directly beside vlib.
fn test_find_v_dir_from_exe_beside_vlib() {
	root := main_test_temp_dir('beside')
	defer {
		os.rmdir_all(root) or {}
	}
	main_test_write(os.join_path(root, 'v.exe'), 'binary')
	os.mkdir_all(os.join_path(root, 'vlib')) or {
		assert false, 'Failed to create vlib: ${err}'
		return
	}

	assert find_v_dir_from_exe(os.join_path(root, 'v.exe')) == root
}

// The regression case. V's Windows launcher is a `.bat` wrapper kept in `.bin/`
// that forwards to the real `v.exe` in the parent, so the executable's own
// directory has no vlib. Trusting it made every vlib lookup resolve to nothing.
fn test_find_v_dir_from_exe_wrapper_script_in_bin_dir() {
	root := main_test_temp_dir('wrapper')
	defer {
		os.rmdir_all(root) or {}
	}
	main_test_write(os.join_path(root, 'v.exe'), 'binary')
	os.mkdir_all(os.join_path(root, 'vlib')) or {
		assert false, 'Failed to create vlib: ${err}'
		return
	}
	bin_dir := os.join_path(root, '.bin')
	os.mkdir_all(bin_dir) or {
		assert false, 'Failed to create .bin: ${err}'
		return
	}
	wrapper := os.join_path(bin_dir, 'v.bat')
	// The wrapper's own contents do not matter, only that it is a file that is
	// not the real compiler.
	main_test_write(wrapper, '@echo off\r\ncall v.exe %*\r\n')

	assert find_v_dir_from_exe(wrapper) == root
}

// A wrapper nested one level deeper still resolves, because the walk is bounded
// by the number of levels between the launcher and the V root rather than by one.
fn test_find_v_dir_from_exe_deeply_nested_wrapper() {
	root := main_test_temp_dir('nested')
	defer {
		os.rmdir_all(root) or {}
	}
	main_test_write(os.join_path(root, 'v.exe'), 'binary')
	os.mkdir_all(os.join_path(root, 'vlib')) or {
		assert false, 'Failed to create vlib: ${err}'
		return
	}
	nested := os.join_path(root, '.bin', 'shims')
	os.mkdir_all(nested) or {
		assert false, 'Failed to create nested shim dir: ${err}'
		return
	}
	wrapper := os.join_path(nested, 'v.bat')
	main_test_write(wrapper, '@echo off\r\n')

	assert find_v_dir_from_exe(wrapper) == root
}

// A directory that holds no vlib anywhere on the way up reports nothing found,
// instead of returning a directory whose vlib path does not exist.
fn test_find_v_dir_from_exe_without_any_vlib() {
	root := main_test_temp_dir('novlib')
	defer {
		os.rmdir_all(root) or {}
	}
	exe := os.join_path(root, 'v.exe')
	main_test_write(exe, 'binary')

	assert find_v_dir_from_exe(exe) == ''
}

fn test_find_v_dir_from_exe_rejects_unresolved_name() {
	assert find_v_dir_from_exe('v') == ''
}

fn test_find_v_dir_from_exe_rejects_missing_file() {
	assert find_v_dir_from_exe(os.join_path(os.temp_dir(), 'vls_no_such_v_exe_9f3a')) == ''
}
