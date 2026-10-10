// Tests for the layered configuration (vls_config.v): the defines a check runs
// with, and the switches a project may set for itself.
//
// Every helper here is named with a `config_test_` prefix of its own. All
// _test.v files of this program are module main, so a helper sharing a name
// with one in another file would not compile.
module main

import os
import time

// config_test_vmod is a `v.mod` a project root needs to be one. Its content does
// not matter to VLS: find_project_root only asks whether the file is there.
const config_test_vmod = "Module {\n\tname: 'configtest'\n\tdescription: ''\n\tversion: '0.0.1'\n\tlicense: 'MIT'\n}\n"

// config_test_project returns a fresh project root under the system temp dir.
fn config_test_project(tag string) string {
	root := os.join_path(os.temp_dir(), 'vls_config_${tag}_${os.getpid()}_${time.now().unix_nano()}')
	config_test_must_mkdir_all(root)
	config_test_write(os.join_path(root, 'v.mod'), config_test_vmod)
	return root
}

fn config_test_must_mkdir_all(path string) {
	os.mkdir_all(path) or {
		assert false, 'config test: cannot create ${path}: ${err}'
		return
	}
}

fn config_test_write(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'config test: cannot write ${path}: ${err}'
	}
}

// config_test_app returns an App whose only workspace root is `root`, with the
// configuration store emptied, so no earlier test leaves a tier behind.
fn config_test_app(root string) &App {
	mut store := vls_config_store()
	store.set_editor_settings(EditorSettings{})
	store.drop_config(root)
	return &App{
		temp_dir:        root
		workspace_roots: [root]
	}
}

// config_test_diag_cache_dir points the diagnostics cache at a folder of its
// own and returns the previous value, so a test never writes to the real one.
fn config_test_diag_cache_dir() string {
	dir := os.join_path(os.temp_dir(), 'vls_config_diagcache_${os.getpid()}_${time.now().unix_nano()}')
	config_test_must_mkdir_all(dir)
	previous := os.getenv('VLS_DIAG_CACHE_DIR')
	os.setenv('VLS_DIAG_CACHE_DIR', dir, true)
	return previous
}

fn config_test_restore_diag_cache_dir(previous string) {
	if previous == '' {
		os.unsetenv('VLS_DIAG_CACHE_DIR')
	} else {
		os.setenv('VLS_DIAG_CACHE_DIR', previous, true)
	}
}

// config_test_forget_env_defines drops VLS_DEFINES for the test and returns
// what it was, so the last tier never leaks into another one.
fn config_test_forget_env_defines() string {
	previous := os.getenv_opt(vls_defines_env_var) or { '' }
	os.unsetenv(vls_defines_env_var)
	return previous
}

fn config_test_restore_env_defines(previous string) {
	if previous == '' {
		os.unsetenv(vls_defines_env_var)
	} else {
		os.setenv(vls_defines_env_var, previous, true)
	}
}

fn test_config_define_args_accepts_every_spelling() {
	assert define_args(['-d', 'bespin']) == ['-d', 'bespin'], 'two entries stay a pair'
	assert define_args(['-dbespin']) == ['-d', 'bespin'], 'a joined entry splits into a pair'
	assert define_args(['-d=bespin']) == ['-d', 'bespin'], 'an `=` between flag and name is dropped'
	assert define_args(['-d', 'a', '-db', 'c']) == ['-d', 'a', '-d', 'b'], 'a pair consumes only its own name'
	assert define_args(['', '-d', 'x']) == ['-d', 'x'], 'empty entries are dropped'
	assert define_args(['-cc', 'gcc']).len == 0, 'a flag that is not a define is dropped'
	assert define_args(['-d']).len == 0, 'a lone -d carries no name'
	assert define_args([]).len == 0, 'no entries make no pairs'
}

fn test_config_project_file_is_the_second_tier() {
	root := config_test_project('file')
	defer {
		os.rmdir_all(root) or {}
	}
	config_test_write(os.join_path(root, 'vls.json'), '{"defines":["-dbespin"],"inlayHints":false}')
	mut app := config_test_app(root)
	config := app.project_config_for_root(root)
	assert config.defines == ['-d', 'bespin'], 'the file defines the configuration, got ${config.defines}'
	if enabled := config.inlay_hints {
		assert !enabled, 'the file inlayHints reaches the configuration'
	} else {
		assert false, 'the file inlayHints was not read'
	}
	assert config.diagnostics == none, 'a key the file does not set says nothing'
}

fn test_config_missing_or_malformed_file_contributes_nothing() {
	root := config_test_project('nofile')
	defer {
		os.rmdir_all(root) or {}
	}
	mut missing := config_test_app(root)
	empty := missing.project_config_for_root(root)
	assert empty.defines.len == 0, 'a project without vls.json defines nothing'
	broken := config_test_project('malformed')
	defer {
		os.rmdir_all(broken) or {}
	}
	config_test_write(os.join_path(broken, 'vls.json'), '{"defines": [')
	mut app := config_test_app(broken)
	assert app.project_config_for_root(broken).defines.len == 0, 'a malformed vls.json defines nothing'
	assert app.project_config_for_root(broken).inlay_hints == none, 'a malformed vls.json says nothing about the switches'
}

fn test_config_editor_settings_win_over_the_project_file() {
	root := config_test_project('editor')
	defer {
		os.rmdir_all(root) or {}
	}
	config_test_write(os.join_path(root, 'vls.json'), '{"defines":["-d","bespin"],"diagnostics":false}')
	mut app := config_test_app(root)
	// The editor's own settings are the top tier...
	app.apply_editor_configuration('{"settings":{"vls":{"defines":["-d","naboo"],"diagnostics":true}}}')
	config := app.project_config_for_root(root)
	assert config.defines == ['-d', 'naboo'], 'the editor overrides the project file, got ${config.defines}'
	assert app.diagnostics_enabled, 'the editor re-enables the switch the file turned off'
	// ... and a payload that does not carry the key unset it, which leaves the
	// project file to decide what a check runs with.
	app.apply_editor_configuration('{"settings":{"vls":{"diagnostics":true}}}')
	assert app.project_config_for_root(root).defines == ['-d', 'bespin'], 'an unset defines falls back to the file'
}

fn test_config_defines_at_the_top_level_of_the_settings() {
	root := config_test_project('flat')
	defer {
		os.rmdir_all(root) or {}
	}
	mut app := config_test_app(root)
	// Some clients send the settings object without a `vls` section.
	app.apply_editor_configuration('{"settings":{"defines":["-dbespin"]}}')
	assert app.project_config_for_root(root).defines == ['-d', 'bespin'], 'the flat defines are read too'
}

fn test_config_environment_is_the_last_tier() {
	root := config_test_project('env')
	defer {
		os.rmdir_all(root) or {}
	}
	saved := config_test_forget_env_defines()
	defer {
		config_test_restore_env_defines(saved)
	}
	os.setenv(vls_defines_env_var, '-dbespin', true)
	mut app := config_test_app(root)
	assert app.project_config_for_root(root).defines == ['-d', 'bespin'], 'VLS_DEFINES is the last tier'
	config_test_write(os.join_path(root, 'vls.json'), '{"defines":["-d","naboo"]}')
	mut store := vls_config_store()
	store.drop_config(root)
	assert app.project_config_for_root(root).defines == ['-d', 'naboo'], 'the project file beats the environment'
}

fn test_config_project_file_is_cached_for_the_ttl() {
	root := config_test_project('ttl')
	defer {
		os.rmdir_all(root) or {}
	}
	mut store := vls_config_store()
	mut app := config_test_app(root)
	assert app.project_config_for_root(root).defines.len == 0, 'no file defines nothing'
	config_test_write(os.join_path(root, 'vls.json'), '{"defines":["-d","bespin"]}')
	assert app.project_config_for_root(root).defines.len == 0, 'the cached configuration is reused inside the ttl'
	store.drop_config(root)
	assert app.project_config_for_root(root).defines == ['-d', 'bespin'], 'a dropped entry is read again'
}

fn test_config_a_changed_file_drops_the_diagnostics_of_its_root() {
	root := config_test_project('filechange')
	defer {
		os.rmdir_all(root) or {}
	}
	config_test_write(os.join_path(root, 'vls.json'), '{"defines":["-d","bespin"]}')
	source := os.join_path(root, 'main.v')
	content := 'module main\n\nfn main() {}\n'
	config_test_write(source, content)
	uri := path_to_uri(source)
	mut app := config_test_app(root)
	assert app.check_defines(source) == ['-d', 'bespin'], 'the file defines the check of its own project'
	app.diag_cache[uri] = DiagCacheEntry{
		fingerprint: 'seeded'
		errors:      []
	}
	// The file changed on disk and the configuration with it.
	config_test_write(os.join_path(root, 'vls.json'), '{"defines":["-d","naboo"]}')
	app.forget_config_file(os.join_path(root, 'vls.json'))
	assert uri !in app.diag_cache, 'a changed configuration drops the cached diagnostics'
	assert app.check_defines(source) == ['-d', 'naboo'], 'the new file defines the check'
}

fn test_config_a_watched_file_that_is_not_the_config_is_left_alone() {
	root := config_test_project('otherfile')
	defer {
		os.rmdir_all(root) or {}
	}
	config_test_write(os.join_path(root, 'vls.json'), '{"defines":["-d","bespin"]}')
	mut app := config_test_app(root)
	assert app.project_config_for_root(root).defines == ['-d', 'bespin'], 'the file is read once'
	app.forget_config_file(os.join_path(root, 'main.v'))
	assert app.project_config_for_root(root).defines == ['-d', 'bespin'], 'a change of another file forgets nothing'
}

fn test_config_a_changed_editor_defines_value_drops_every_cached_diagnostic() {
	root := config_test_project('diag')
	defer {
		os.rmdir_all(root) or {}
	}
	other := config_test_project('diag_other')
	defer {
		os.rmdir_all(other) or {}
	}
	source := os.join_path(root, 'main.v')
	content := 'module main\n\nfn main() {}\n'
	config_test_write(source, content)
	uri := path_to_uri(source)
	mut app := config_test_app(root)
	app.diag_cache[uri] = DiagCacheEntry{
		fingerprint: 'seeded'
		errors:      []
	}
	app.apply_editor_configuration('{"settings":{"vls":{"defines":["-d","bespin"]}}}')
	assert uri !in app.diag_cache, 'a new defines value drops the cached diagnostics of every file'
}

fn test_config_the_project_switches_are_applied_to_the_app() {
	root := config_test_project('switch')
	defer {
		os.rmdir_all(root) or {}
	}
	config_test_write(os.join_path(root, 'vls.json'), '{"inlayHints":false,"diagnostics":false}')
	mut app := config_test_app(root)
	app.apply_editor_configuration('{}')
	assert !app.inlay_hints_enabled, 'the project file turns inlay hints off'
	assert !app.diagnostics_enabled, 'the project file turns diagnostics off'
	// The editor's own settings win again once it says something.
	app.apply_editor_configuration('{"settings":{"vls":{"inlayHints":true}}}')
	assert app.inlay_hints_enabled, 'the editor turns inlay hints back on'
	assert !app.diagnostics_enabled, 'a key the editor did not send keeps the project value'
}

fn test_config_the_defines_reach_only_the_check_argument_vector() {
	base := build_v_check_args_multifile(false)
	assert check_args_with_defines(base, []).len == base.len, 'no defines leave the vector alone'
	with_defines := check_args_with_defines(base, ['-d', 'bespin'])
	mut expected := base.clone()
	expected << ['-d', 'bespin']
	assert with_defines == expected, 'the defines are appended to the check vector'
	assert with_defines.len == base.len + 2, 'each define is one flag and one name'
	assert build_v_fmt_args('x.v').all(it != '-d'), 'the formatter never takes a define'
	assert build_v_line_info_args_multifile('x.v', '1:1').all(it != '-d'), 'the questions never take a define'
}

fn test_config_the_defines_make_the_compiler_check_the_gated_code() {
	assert compiler_is_available(), 'a V compiler must be reachable to check the gated fixture'
	saved_cache := config_test_diag_cache_dir()
	defer {
		config_test_restore_diag_cache_dir(saved_cache)
	}
	saved_defines := config_test_forget_env_defines()
	defer {
		config_test_restore_env_defines(saved_defines)
	}
	root := config_test_project('gated')
	defer {
		os.rmdir_all(root) or {}
	}
	work := os.join_path(root, 'work')
	config_test_must_mkdir_all(work)
	content := 'module main\n\nfn main() {\n\t$if bespin ? {\n\t\tundef_fn_bespin_probe()\n\t}\n}\n'
	source := os.join_path(root, 'main.v')
	config_test_write(source, content)
	uri := path_to_uri(source)
	mut app := &App{
		temp_dir:        work
		open_files:      {
			uri: content
		}
		workspace_roots: [root]
	}
	// Without a define the gated body is not compiled, so it is not checked.
	assert app.run_v_check(uri, content).len == 0, 'no define checks no gated code'
	// The project file supplies the define, and the check then finds the error.
	config_test_write(os.join_path(root, 'vls.json'), '{"defines":["-dbespin"]}')
	mut store := vls_config_store()
	store.drop_config(root)
	gated := app.run_v_check(uri, content)
	assert gated.any(it.message.contains('undef_fn_bespin_probe')), 'the define made the compiler check the gated code: ${gated}'
}
