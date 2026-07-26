// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os
import strings
import time

// v_compiler_exe is the absolute path to the V compiler executable, resolved
// once at startup. Using an absolute path (instead of relying on PATH at exec
// time) makes child-process invocation deterministic and shell-free.
const v_compiler_exe = resolve_v_compiler_exe()

fn resolve_v_compiler_exe() string {
	return os.find_abs_path_of_executable('v') or { 'v' }
}

// compiler_is_available reports whether the V compiler was resolved to a real
// executable path at startup. When false, compiler-backed features cannot work
// and the failure should be surfaced to the user rather than masked as empty
// results (P1-03).
fn compiler_is_available() bool {
	return v_compiler_exe != 'v' && os.exists(v_compiler_exe)
}

// hex_nibble returns the numeric value of a single hex digit, or none.
fn hex_nibble(c u8) ?u8 {
	return match c {
		`0`...`9` { u8(c - `0`) }
		`a`...`f` { u8(c - `a` + 10) }
		`A`...`F` { u8(c - `A` + 10) }
		else { none }
	}
}

// percent_decode decodes %XX escapes in a URI path component into raw bytes.
// Invalid escapes are left untouched so the function never fails on odd input.
fn percent_decode(s string) string {
	if !s.contains('%') {
		return s
	}
	mut out := []u8{cap: s.len}
	mut i := 0
	for i < s.len {
		c := s[i]
		if c == `%` && i + 2 < s.len {
			hi := hex_nibble(s[i + 1]) or {
				out << c
				i++
				continue
			}
			lo := hex_nibble(s[i + 2]) or {
				out << c
				i++
				continue
			}
			out << u8(hi * 16 + lo)
			i += 3
			continue
		}
		out << c
		i++
	}
	return out.bytestr()
}

// path_needs_escape reports whether a byte must be percent-encoded in a URI
// path. Unreserved characters (RFC 3986) plus the path separators '/' are kept.
fn path_byte_needs_escape(c u8) bool {
	return match c {
		`a`...`z`, `A`...`Z`, `0`...`9`, `-`, `.`, `_`, `~`, `/`, `:` { false }
		else { true }
	}
}

// percent_encode_path percent-encodes a filesystem path for use in a file URI,
// preserving '/' separators and drive-letter colons.
fn percent_encode_path(s string) string {
	mut sb := strings.new_builder(s.len + 8)
	for c in s.bytes() {
		if path_byte_needs_escape(c) {
			sb.write_string('%')
			sb.write_string(c.hex().to_upper())
		} else {
			sb.write_u8(c)
		}
	}
	return sb.str()
}

// uri_to_path converts a `file:` DocumentUri to a local filesystem path.
// It percent-decodes the path component, strips an empty authority, drops any
// query/fragment, and normalizes Windows drive paths (/C:/... -> C:/...).
// Non-`file:` URIs and bare paths are returned unchanged.
fn uri_to_path(uri string) string {
	if uri == '' {
		return ''
	}
	if !uri.starts_with('file:') {
		return uri
	}
	mut rest := uri[5..] // strip 'file:'
	mut authority := ''
	if rest.starts_with('//') {
		rest = rest[2..]
		if slash := rest.index('/') {
			authority = rest[..slash]
			rest = rest[slash..]
		} else {
			// Authority only, no path component.
			authority = rest
			rest = ''
		}
	}
	// Strip fragment then query (these are only meaningful when unescaped).
	if hash := rest.index('#') {
		rest = rest[..hash]
	}
	if q := rest.index('?') {
		rest = rest[..q]
	}
	decoded := percent_decode(rest)
	if authority != '' {
		// Preserve UNC authority: //server/share/...
		return '//' + authority + decoded
	}
	// Windows drive path: /C:/Users/... -> C:/Users/...
	if decoded.len > 2 && decoded[0] == `/` && decoded[2] == `:` {
		return decoded[1..]
	}
	return decoded
}

// path_is_within reports whether `path` lies inside directory `dir`, using a
// boundary-aware comparison so that e.g. /foo/barley is NOT treated as inside
// /foo/bar (P1-01). Both arguments are expected to use '/' separators.
fn path_is_within(path string, dir string) bool {
	if dir == '' {
		return false
	}
	d := dir.trim_right('/')
	if d == '' {
		// dir was the filesystem root.
		return path.starts_with('/')
	}
	return path == d || path.starts_with(d + '/')
}

// path_to_uri converts a local filesystem path to a `file:` DocumentUri,
// percent-encoding characters that are not allowed unescaped in a URI path.
fn path_to_uri(path string) string {
	if path == '' {
		return 'file:///'
	}
	mut normalized := os.to_slash(path)
	// Windows drive letter: C:/Users/... -> /C:/Users/... so the URI keeps a
	// leading slash before the authority-less path.
	if normalized.len >= 2 && normalized[1] == `:` {
		normalized = '/' + normalized
	}
	encoded := percent_encode_path(normalized)
	if encoded.starts_with('/') {
		return 'file://' + encoded
	}
	return 'file:///' + encoded
}

// make_unique_temp_path returns a collision-resistant temp file path in the
// system temp dir, tagged with the caller's purpose, the pid, and a nanosecond
// timestamp, so concurrent requests for same-named files never overwrite one
// another (P1-12).
fn make_unique_temp_path(tag string, real_path string) string {
	ext := os.file_ext(real_path)
	safe_ext := if ext == '' { '.v' } else { ext }
	name := os.file_name(real_path)
	base := if name.contains('.') { name.all_before_last('.') } else { name }
	return os.join_path(os.temp_dir(),
		'${tag}_${os.getpid()}_${time.now().unix_nano()}_${base}${safe_ext}')
}

fn make_singlefile_temp_path(temp_root string, real_path string, purpose string) string {
	root := if temp_root != '' { temp_root } else { os.temp_dir() }
	ext := os.file_ext(real_path)
	safe_ext := if ext == '' { '.v' } else { ext }
	tag := if purpose == '' { 'work' } else { purpose }
	return os.join_path(root, 'vls_${tag}_${os.getpid()}_${time.now().unix_nano()}${safe_ext}')
}

// Argument-vector builders for the V compiler. Every value is passed as a
// separate argv element to os.Process, so no shell metacharacter (spaces,
// `$()`, backticks, quotes, `;`, `&`, `|`, `%`, ...) in a filename or path can
// alter the executed command. There is no shell involved at any point.
fn build_v_check_args_single(file_to_check string) []string {
	return ['-w', '-vls-mode', '-check', '-json-errors', '-nocolor', file_to_check]
}

fn build_v_check_args_multifile() []string {
	return ['-w', '-check', '-json-errors', '-nocolor', '.']
}

fn build_v_line_info_args_multifile(rel_file string, line_info string) []string {
	return ['-w', '-check', '-json-errors', '-nocolor', '-vls-mode', '-line-info',
		'${rel_file}:${line_info}', '.']
}

fn build_v_line_info_args_single(file_to_check string, line_info string, compile_target string) []string {
	return ['-w', '-check', '-json-errors', '-nocolor', '-vls-mode', '-line-info',
		'${file_to_check}:${line_info}', compile_target]
}

fn build_v_fmt_args(temp_file string) []string {
	return ['fmt', '-inprocess', '-w', temp_file]
}

// Sentinel exit code returned when a compiler invocation is killed for
// exceeding compiler_timeout_ms. 124 matches the coreutils `timeout` convention.
const compiler_exit_timeout = 124

// compiler_timeout_ms bounds how long any single compiler/formatter invocation
// may run before it is force-killed, so a hung or runaway `v` process can never
// freeze the server indefinitely (partial P0-04). Overridable via VLS_TIMEOUT_MS.
const compiler_timeout_ms = resolve_compiler_timeout_ms()

fn resolve_compiler_timeout_ms() i64 {
	env := os.getenv('VLS_TIMEOUT_MS')
	if env != '' {
		n := env.i64()
		if n > 0 {
			return n
		}
	}
	return 30_000
}

// run_v_argv executes the V compiler with the given argument vector in
// `work_folder` (set on the child process, never via a process-global chdir).
// stdout and stderr are merged into one combined buffer because the compiler
// writes its `-json-errors` / `-line-info` output to STDERR; returning stdout
// alone would silently drop every diagnostic. The child is killed if it exceeds
// compiler_timeout_ms. This is the single, shell-free entry point for all
// compiler invocations.
fn run_v_argv(args []string, work_folder string) os.Result {
	if work_folder != '' && !os.is_dir(work_folder) {
		msg := 'Working dir does not exist: ${work_folder}'
		log(msg)
		return os.Result{
			exit_code: 1
			output:    msg
		}
	}
	mut p := os.new_process(v_compiler_exe)
	p.set_args(args)
	if work_folder != '' {
		p.set_work_folder(work_folder)
	}
	p.set_redirect_stdio()
	p.run()
	// The V compiler writes its `-json-errors` / `-line-info` output to STDERR,
	// so both streams are captured into one combined buffer (equivalent to the
	// shell `2>&1` the previous implementation relied on). Returning stdout alone
	// would silently drop every diagnostic.
	mut out := strings.new_builder(1024)
	start_ms := time.now().unix_milli()
	mut timed_out := false
	// Drain both pipes on every iteration and enforce the deadline. `pipe_read`
	// is non-blocking (it polls the fd and returns none immediately when no data
	// is pending), so a child that writes only to stderr, or one that hangs
	// silently, never wedges this loop: the stderr drain still runs so a large
	// payload cannot fill the pipe and deadlock the child, and the timeout check
	// below still fires to kill a stuck process.
	for p.is_alive() {
		mut got_data := false
		if chunk := p.pipe_read(.stdout) {
			out.write_string(chunk)
			got_data = true
		}
		if chunk := p.pipe_read(.stderr) {
			out.write_string(chunk)
			got_data = true
		}
		if time.now().unix_milli() - start_ms > compiler_timeout_ms {
			log('v invocation exceeded ${compiler_timeout_ms}ms; killing child')
			p.signal_kill()
			timed_out = true
			break
		}
		if !got_data {
			// Avoid busy-spinning while the child is compiling.
			time.sleep(time.millisecond)
		}
	}
	out.write_string(p.stdout_slurp())
	out.write_string(p.stderr_slurp())
	p.wait()
	code := p.code
	p.close()
	if timed_out {
		return os.Result{
			exit_code: compiler_exit_timeout
			output:    ''
		}
	}
	return os.Result{
		exit_code: code
		output:    out.str()
	}
}

fn cleanup_compilation_temp(temp_project_dir string, singlefile_tmppath string) {
	if temp_project_dir != '' {
		os.rmdir_all(temp_project_dir) or { log('Failed to clean up temp project dir: ${err}') }
	} else if singlefile_tmppath != '' {
		os.rm(singlefile_tmppath) or { log('Failed to remove temp file: ${err}') }
	}
}

fn (mut app App) run_v_check(path string, text string) []JsonError {
	real_path := uri_to_path(path)
	working_dir := os.dir(real_path)
	mut temp_project_dir := ''
	mut file_to_check := ''
	mut compile_target := ''
	mut use_multifile := false
	mut singlefile_tmppath := ''

	// Check the diagnostics cache before invoking the compiler.
	content_hash := text.hash()
	gen := app.project_generation(path)
	if cached := app.diag_cache[path] {
		if cached.content_hash == content_hash && cached.generation == gen {
			log('Returning cached diagnostics for ${path}')
			return cached.errors
		}
	}

	log('running v.exe check for ${real_path}')
	log('Open files count: ${app.open_files.len}')

	if app.open_files.len > 1 || has_sibling_v_files(working_dir, real_path) {
		// Write all tracked files to temp directory
		temp_project_dir = app.write_tracked_files_to_temp(working_dir) or {
			log('Failed to write tracked files: ${err}')
			''
		}

		if temp_project_dir != '' {
			// Resolve symlinks so compiler output paths (e.g. /private/tmp on macOS)
			// match temp_project_dir when remapping paths back to real locations.
			temp_project_dir = os.real_path(temp_project_dir)
			symlink_untracked_files(working_dir, temp_project_dir, app.open_files) or {
				log('Failed to symlink untracked files: ${err}')
			}
			rel_path := real_path.replace(working_dir, '').trim_left('/')
			file_to_check = os.join_path(temp_project_dir, rel_path)
			compile_target = temp_project_dir
			use_multifile = true
			log('temp_project_dir=${temp_project_dir}, file_to_check=${file_to_check}, compile_target=${compile_target}')
		}
	}

	if !use_multifile {
		log('USING SINGLEFILE')
		singlefile_tmppath = make_singlefile_temp_path(app.temp_dir, real_path, 'check')
		os.write_file(singlefile_tmppath, text) or {
			log('Failed to write temp file ${singlefile_tmppath}: ${err}')
			return []
		}
		file_to_check = singlefile_tmppath
		compile_target = singlefile_tmppath
	}

	mut cmd_args := []string{}
	if use_multifile {
		cmd_args = build_v_check_args_multifile()
		log('MULTIFILE CMD - compile_target=${compile_target}): v ${cmd_args.join(' ')}')
	} else {
		cmd_args = build_v_check_args_single(file_to_check)
		log('SINGLEFILE CMD: v ${cmd_args.join(' ')}')
	}

	exec_dir := if use_multifile { compile_target } else { working_dir }
	x := run_v_argv(cmd_args, exec_dir)

	log('Check - RUN RES ${x}')

	cleanup_compilation_temp(temp_project_dir, singlefile_tmppath)

	json_errors := json2.decode[[]JsonError](x.output) or {
		log('failed to parse json ${err}')
		return []
	}

	// error filtlering
	if use_multifile {
		mut filtered_errors := []JsonError{}
		rel_path_to_check := real_path.replace(working_dir, '').trim_string_left('/')

		for err in json_errors {
			err_file := match true {
				err.path.starts_with(temp_project_dir) {
					err.path.replace(temp_project_dir, '').trim_string_left('/')
				}
				err.path.starts_with('./') || err.path.starts_with('.\\') {
					err.path[2..]
				}
				else {
					err.path
				}
			}

			if err_file == rel_path_to_check || err_file == os.file_name(real_path) {
				updated_err := JsonError{
					path:    real_path
					message: err.message
					line_nr: err.line_nr
					col:     err.col
					len:     err.len
					level:   err.level
				}
				filtered_errors << updated_err
				log('INCLUDING ERROR from err_file=${err_file}: ${err.message}')
			} else {
				log('EXLUCING ERROR from err_file=${err_file} rel_path_to_check=${rel_path_to_check}')
			}
		}

		log('FILTERED ERRORS: ${filtered_errors.len} of ${json_errors.len}')
		app.diag_cache[path] = DiagCacheEntry{
			content_hash: content_hash
			generation:   gen
			errors:       filtered_errors
		}
		return filtered_errors
	}

	log('JSON ERRORS: ${json_errors.len}')
	app.diag_cache[path] = DiagCacheEntry{
		content_hash: content_hash
		generation:   gen
		errors:       json_errors
	}
	return json_errors
}

fn (mut app App) write_tracked_files_to_temp(working_dir string) !string {
	log('WRITING ${app.open_files.len} tracked files to temp directory')

	// create subdir
	temp_project_dir := os.join_path(app.temp_dir, 'project_${time.now().unix_milli()}')
	os.mkdir_all(temp_project_dir) or { return error('Failed to create temp project dir: ${err}') }

	// write file structure
	for uri, content in app.open_files {
		real_path := uri_to_path(uri)

		// Normalize slashes for comparison
		normalized_real := real_path.replace('\\', '/')
		normalized_working := working_dir.replace('\\', '/')

		// skip not in working dir (boundary-aware: /foo/barley is not in /foo/bar)
		if !path_is_within(normalized_real, normalized_working) {
			log('SKIPPING FILE: ${real_path}')
			continue
		}

		// calc rel path
		mut rel_path :=
			normalized_real.replace(normalized_working, '').trim_string_left('/').trim_string_left('\\')
		if rel_path == '' {
			rel_path = os.file_name(real_path)
		}
		temp_file_path := os.join_path(temp_project_dir, rel_path)

		// create parent dir
		temp_file_dir := os.dir(temp_file_path)
		os.mkdir_all(temp_file_dir) or {
			log('Failed to create dir ${temp_file_dir}: ${err}')
			continue
		}

		// write file
		os.write_file(temp_file_path, content) or {
			log('Failed to write ${temp_file_path}: ${err}')
			continue
		}
		log('WROTE FILE: ${temp_file_path}')
	}

	return temp_project_dir
}

// has_sibling_v_files reports whether the directory of the current file holds
// another `.v` file, i.e. the file is part of a multi-file V module. This uses a
// shallow directory listing rather than a full recursive tree walk: V modules
// are per-directory, and recursively walking (e.g. a huge workspace or /tmp) on
// every diagnostics cycle was a major, unnecessary cost.
fn has_sibling_v_files(working_dir string, current_file string) bool {
	cur_name := os.file_name(current_file)
	entries := os.ls(working_dir) or { return false }
	for entry in entries {
		if entry == cur_name {
			continue
		}
		if entry.ends_with('.v') {
			full := os.join_path(working_dir, entry)
			if os.is_file(full) {
				return true
			}
		}
	}
	return false
}

fn symlink_untracked_files(working_dir string, temp_dir string, tracked_files map[string]string) ! {
	log('SYMLINKING FROM ${working_dir} TO ${temp_dir}')

	v_files := os.walk_ext(working_dir, '.v')
	for v_file in v_files {
		// skip if tracked
		file_uri := path_to_uri(v_file)
		if file_uri in tracked_files {
			continue
		}

		// calc rel path
		mut rel_path := v_file.replace(working_dir, '').trim_string_left('/')
		if rel_path == '' {
			rel_path = os.file_name(v_file)
		}
		temp_file_path := os.join_path(temp_dir, rel_path)

		// create parent dir
		temp_file_dir := os.dir(temp_file_path)
		os.mkdir_all(temp_file_dir) or {
			log('Failed to create dir ${temp_file_dir}: ${err}')
			continue
		}

		// create symlink
		os.symlink(v_file, temp_file_path) or {
			log('Failed to symlink ${v_file} to ${temp_file_path}: ${err}')
			continue
		}
		log('Symlinked untracked file: ${v_file} -> ${temp_file_path}')
	}
}

// on_did_change_watched_files handles workspace/didChangeWatchedFiles.
// When an externally tracked file is created, changed, or deleted on disk,
// this notification keeps the in-memory open_files map consistent.
fn (mut app App) on_did_change_watched_files(request Request) {
	params := json2.decode[DidChangeWatchedFilesParams](request.params) or {
		$if debug { log('Failed to decode DidChangeWatchedFilesParams: ${err}') }
		return
	}
	for change in params.changes {
		uri := change.uri
		match change.event_type {
			3 {
				// Deleted on disk. Invalidate cached diagnostics, but do NOT drop
				// an open editor buffer: the editor still owns the in-memory
				// document even if the on-disk file was removed (P0-07 item 8).
				if uri in app.diag_cache {
					app.diag_cache.delete(uri)
				}
				app.bump_generation(uri)
				// Re-index from disk when no editor buffer owns the URI (the file
				// was removed, so this drops the entry).
				if uri !in app.open_files {
					app.reindex_uri(uri)
				}
				log('on_did_change_watched_files: disk delete for ${uri}')
			}
			1, 2 {
				// Created or Changed on disk. The editor buffer is authoritative
				// for any open document, so we must never overwrite open_files
				// with disk content — doing so would erase unsaved edits (P0-07
				// item 8). We only invalidate caches so future checks re-read
				// non-open files from disk.
				if uri in app.open_files {
					log('on_did_change_watched_files: ignoring disk change for open buffer ${uri}')
				} else {
					// Re-read this file from disk into the index.
					app.reindex_uri(uri)
				}
				if uri in app.diag_cache {
					app.diag_cache.delete(uri)
				}
				app.bump_generation(uri)
			}
			else {}
		}
	}
}

fn (mut app App) run_v_line_info(method Method, path string, line_info string) ResponseResult {
	// Convert URI to local file path
	real_path := uri_to_path(path)
	log('real_path=${real_path}, method=${method}')

	mut working_dir := os.dir(real_path)
	mut file_to_check := real_path
	mut compile_target := real_path
	mut temp_project_dir := ''
	mut use_multifile := false
	mut singlefile_tmppath := ''

	if method == .definition || method == .declaration || method == .type_definition
		|| method == .implementation {
		log('OPEN FILES COUNT: ${app.open_files.len}')
		if app.open_files.len > 1 || has_sibling_v_files(working_dir, real_path) {
			temp_project_dir = app.write_tracked_files_to_temp(working_dir) or {
				log('Failed to write tracked files: ${err}')
				''
			}

			if temp_project_dir != '' {
				// Resolve symlinks so compiler output paths (e.g. /private/tmp on macOS)
				// match temp_project_dir when remapping paths back to real locations.
				temp_project_dir = os.real_path(temp_project_dir)
				symlink_untracked_files(working_dir, temp_project_dir, app.open_files) or {
					log('Failed to symlink untracked files: ${err}')
				}
				rel_path := real_path.replace(working_dir, '').trim_left('/')
				file_to_check = os.join_path(temp_project_dir, rel_path)
				compile_target = temp_project_dir
				use_multifile = true
				log('temp_project_dir=${temp_project_dir}, file_to_check=${file_to_check}, compile_target=${compile_target}')
			}
		}
		if !use_multifile {
			log('Using single file compilation from disk')
			file_to_check = real_path
			compile_target = real_path
		}
	} else {
		log('MULTIFILE for method=${method}')
		log('OPEN FILES COUNT: ${app.open_files.len}')

		if app.open_files.len > 1 || has_sibling_v_files(working_dir, real_path) {
			temp_project_dir = app.write_tracked_files_to_temp(working_dir) or {
				log('Failed to write tracked files: ${err}')
				''
			}
			if temp_project_dir != '' {
				// Resolve symlinks so compiler output paths (e.g. /private/tmp on macOS)
				// match temp_project_dir when remapping paths back to real locations.
				temp_project_dir = os.real_path(temp_project_dir)
				symlink_untracked_files(working_dir, temp_project_dir, app.open_files) or {
					log('Failed to symlink untracked files: ${err}')
				}
				rel_path := real_path.replace(working_dir, '').trim_left('/')
				file_to_check = os.join_path(temp_project_dir, rel_path)
				compile_target = temp_project_dir
				use_multifile = true
				log('temp_project_dir=${temp_project_dir}, file_to_check=${file_to_check}, compile_target=${compile_target}')
			}
		}

		if !use_multifile {
			log('SINGLEFILE method=${method}')
			singlefile_tmppath = make_singlefile_temp_path(app.temp_dir, real_path, 'lineinfo')
			log('WRITING FILE ${time.now()} to temp path ${singlefile_tmppath}')
			// Overlay the requested document's open buffer, never a global
			// "last touched" field, so a request for one URI can't compile the
			// buffer of another (P1-02). Fall back to this exact file on disk, or
			// empty — never to another document's content.
			request_content := app.open_files[path] or { os.read_file(real_path) or { '' } }
			mut wrote_temp := true
			os.write_file(singlefile_tmppath, request_content) or {
				wrote_temp = false
				log('Failed to write temp file ${singlefile_tmppath}: ${err}')
				// Fall back to reading from disk instead of crashing.
				file_to_check = real_path
				compile_target = real_path
				use_multifile = false
			}
			if wrote_temp {
				file_to_check = singlefile_tmppath
				compile_target = singlefile_tmppath
			}
		}
	}

	log('running v.exe line info!')
	log('file_to_check=${file_to_check}, compile_target=${compile_target}, working_dir=${working_dir}')
	mut cmd_args := []string{}

	if use_multifile {
		rel_file := os.file_name(file_to_check)
		cmd_args = build_v_line_info_args_multifile(rel_file, line_info)
		log('MULTIFILE CMD compile_target=${compile_target}: v ${cmd_args.join(' ')}')
	} else {
		cmd_args = build_v_line_info_args_single(file_to_check, line_info, compile_target)
		log('SINGLEFILE CMD: v ${cmd_args.join(' ')}')
	}

	exec_dir := if use_multifile { compile_target } else { working_dir }
	mut x := run_v_argv(cmd_args, exec_dir)

	if (method == .definition || method == .declaration || method == .type_definition
		|| method == .implementation) && use_multifile
		&& (x.exit_code != 0 || x.output.trim_space() == ''
		|| x.output.trim_space() == '[]') {
		if temp_project_dir != '' {
			os.rmdir_all(temp_project_dir) or { log('Failed to clean up temp project dir: ${err}') }
			temp_project_dir = ''
		}
		file_to_check = real_path
		compile_target = real_path
		cmd_fallback := build_v_line_info_args_single(file_to_check, line_info, compile_target)
		log('cmd_fallback=v ${cmd_fallback.join(' ')}')
		x = run_v_argv(cmd_fallback, working_dir)
		log('Fallback RUN RES ${x}')
	}

	cleanup_compilation_temp(temp_project_dir, singlefile_tmppath)

	log('RUN RES ${x}')
	// Default to JSON null so any unhandled method branch produces a valid LSP response.
	mut result := ResponseResult('null')
	match method {
		.completion {
			result_tmp := json2.decode[JsonVarAC](x.output) or { JsonVarAC{} }
			result = result_tmp.details
		}
		.signature_help {
			sig := json2.decode[SignatureHelp](x.output) or { SignatureHelp{} }
			// Return null when the compiler found no active signature so editors do not show
			// empty signature popups (LSP spec: SignatureHelp | null).
			if sig.signatures.len == 0 {
				result = 'null'
			} else {
				result = sig
			}
		}
		.hover {
			// Decode the Hover JSON emitted by the compiler's hv^ mode.
			hover_result := json2.decode[Hover](x.output) or { Hover{} }
			// Extract vdoc comment via cross-file search as a fallback when the
			// compiler does not provide documentation.
			mut doc := ''
			// Use the requested document's buffer, else this exact file from disk
			// — never a global last-touched buffer (P1-02).
			file_content := app.open_files[path] or { os.read_file(real_path) or { '' } }
			file_lines := file_content.split_into_lines()
			// line_info format for hover is "${line_nr}:hv^${col}"
			info_parts := line_info.split(':')
			mut cursor_symbol := ''
			if info_parts.len >= 2 {
				cursor_line := info_parts[0].int() - 1
				// cursor_col comes from the compiler line-info, which is a byte
				// column, so treat it as a byte offset (utf8) here.
				cursor_col := info_parts[1].all_after('hv^').int()
				if cursor_line >= 0 && cursor_line < file_lines.len {
					cursor_symbol = get_word_at_col(file_lines[cursor_line], cursor_col, .utf8)
					if cursor_symbol != '' {
						doc = app.find_doc_comment_for_symbol(cursor_symbol, file_lines, path)
					}
				}
			}
			if hover_result.contents.value != '' {
				mut value := hover_result.contents.value
				// Augment with doc comment if the compiler didn't include one
				if doc != '' && !value.contains(doc) {
					value += '\n\n' + doc
				}
				result = Hover{
					contents: MarkupContent{
						kind:  'markdown'
						value: value
					}
				}
			} else if doc != '' {
				// Compiler returned no info but we found a vdoc comment
				result = Hover{
					contents: MarkupContent{
						kind:  'markdown'
						value: doc
					}
				}
			} else {
				// Compiler returned no info and no vdoc comment — return null per LSP spec
				// so editors do not show empty hover popups.
				result = 'null'
			}
		}
		.definition, .declaration, .type_definition, .implementation {
			// file.v:line:col => Location
			fields := x.output.trim_space().split(':')
			if fields.len < 3 || x.output.trim_space() == '' {
				// No definition found — return null so the client does not navigate anywhere.
				result = 'null'
			} else {
				line_nr := fields[fields.len - 2].int() - 1
				col := fields[fields.len - 1].int()
				mut uri_path := os.to_slash(fields[..fields.len - 2].join(':'))
				if use_multifile && temp_project_dir != '' {
					uri_path = match true {
						uri_path.starts_with(temp_project_dir) {
							rel_path := uri_path.replace(temp_project_dir, '').trim_left('/')
							os.join_path(working_dir, rel_path)
						}
						uri_path.starts_with('./') || uri_path.starts_with('.\\') {
							os.join_path(working_dir, uri_path[2..])
						}
						!os.is_abs_path(uri_path) {
							os.join_path(working_dir, uri_path)
						}
						else {
							uri_path
						}
					}

					log('MAPPED TO uri_path=${uri_path}')
				}
				// Build a proper percent-encoded DocumentUri so paths containing
				// spaces, `#`, `%`, or Unicode are valid and match the client's URI
				// keys (P0-10). The compiler reports a byte column; convert it to
				// the client's encoding using the target file's line (P0-01).
				target_uri := path_to_uri(uri_path)
				client_col := app.byte_col_to_client_col(target_uri, line_nr, col)
				result = Location{
					uri:   target_uri
					range: LSPRange{
						start: Position{
							line: line_nr
							char: client_col
						}
						end:   Position{
							line: line_nr
							char: client_col
						}
					}
				}
			}
		}
		else {}
	}

	return result
}
