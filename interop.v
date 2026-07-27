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
	// An empty or `localhost` authority denotes the local machine (RFC 8089), so
	// the path is local: file://localhost/tmp/main.v -> /tmp/main.v. A genuine
	// remote authority is preserved as a UNC path (//server/share/...).
	if authority != '' && authority.to_lower() != 'localhost' {
		return '//' + authority + decoded
	}
	// Windows drive path: /C:/Users/... -> C:/Users/...
	if decoded.len > 2 && decoded[0] == `/` && decoded[2] == `:` {
		return decoded[1..]
	}
	return decoded
}

// path_is_within_with_case reports whether `path` lies inside `dir` using the
// requested case sensitivity. Both arguments are expected to use '/' separators.
fn path_is_within_with_case(path string, dir string, case_insensitive bool) bool {
	if dir == '' {
		return false
	}
	mut p := path
	mut d := dir.trim_right('/')
	if case_insensitive {
		p = p.to_lower()
		d = d.to_lower()
	}
	if d == '' {
		// dir was the filesystem root.
		return p.starts_with('/')
	}
	return p == d || p.starts_with(d + '/')
}

// path_is_within reports whether `path` lies inside directory `dir`, using a
// boundary-aware comparison so that e.g. /foo/barley is NOT treated as inside
// /foo/bar (P1-01). Windows filesystem paths are compared case-insensitively.
fn path_is_within(path string, dir string) bool {
	$if windows {
		return path_is_within_with_case(path, dir, true)
	}
	return path_is_within_with_case(path, dir, false)
}

// path_relative_to_with_case returns `path` relative to `dir` using the
// requested case sensitivity. It slices by the original prefix length so paths
// that differ only in casing still produce a valid relative path.
fn path_relative_to_with_case(path string, dir string, case_insensitive bool) ?string {
	if !path_is_within_with_case(path, dir, case_insensitive) {
		return none
	}
	d := dir.trim_right('/')
	if d == '' {
		return path.trim_string_left('/')
	}
	if path.len == d.len {
		return ''
	}
	return path[d.len..].trim_string_left('/')
}

// path_relative_to returns `path` relative to `dir` using platform filesystem
// case rules.
fn path_relative_to(path string, dir string) ?string {
	$if windows {
		return path_relative_to_with_case(path, dir, true)
	}
	return path_relative_to_with_case(path, dir, false)
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

struct CompilationOverlay {
	source_root         string
	source_display_root string
	temp_root           string
	source_work_dir     string
	temp_work_dir       string
	temp_source_file    string
}

// normalize_overlay_path converts native Windows separators before paths enter
// the overlay's slash-based containment and relative-path helpers.
fn normalize_overlay_path(path string) string {
	return path.replace('\\', '/')
}

// compilation_overlay_root returns the broadest source root needed to preserve
// local module imports. A v.mod project is overlaid from its root; loose modules
// retain the historical same-directory scope.
fn compilation_overlay_root(real_path string) string {
	normalized_real_path := normalize_overlay_path(real_path)
	work_dir := normalize_overlay_path(os.dir(normalized_real_path))
	project_root := find_project_root(work_dir)
	normalized_project_root := normalize_overlay_path(project_root)
	if normalized_project_root != '' && normalized_project_root != '/'
		&& path_is_within(normalized_real_path, normalized_project_root) {
		return normalize_overlay_path(os.real_path(normalized_project_root))
	}
	return normalize_overlay_path(os.real_path(work_dir))
}

// compilation_overlay_display_root retains the path spelling supplied by the
// LSP client. On macOS, canonicalizing `/tmp` to `/private/tmp` is necessary for
// containment checks but must not silently change returned document URIs.
fn compilation_overlay_display_root(real_path string) string {
	normalized_real_path := normalize_overlay_path(real_path)
	work_dir := normalize_overlay_path(os.dir(normalized_real_path))
	project_root := find_project_root(work_dir)
	normalized_project_root := normalize_overlay_path(project_root)
	if normalized_project_root != '' && normalized_project_root != '/'
		&& path_is_within(normalized_real_path, normalized_project_root) {
		return normalized_project_root
	}
	return work_dir
}

fn should_use_compilation_overlay(real_path string, open_file_count int) bool {
	work_dir := os.dir(real_path)
	return find_project_root(work_dir) != '' || open_file_count > 1
		|| has_sibling_v_files(work_dir, real_path)
}

// prepare_compilation_overlay builds a temporary project view in which every
// open buffer is materialized and unchanged project paths are symlinked back to
// disk. The compiler runs in the overlaid counterpart of the source module.
fn (mut app App) prepare_compilation_overlay(real_path string) !CompilationOverlay {
	canonical_real_path := normalize_overlay_path(os.real_path(real_path))
	source_root := compilation_overlay_root(canonical_real_path)
	source_display_root := compilation_overlay_display_root(real_path)
	source_work_dir := normalize_overlay_path(os.dir(canonical_real_path))
	temp_root_unresolved := app.write_tracked_files_to_temp(source_root)!
	temp_root := normalize_overlay_path(os.real_path(temp_root_unresolved))
	symlink_untracked_files(source_root, source_work_dir, temp_root, app.open_files) or {
		os.rmdir_all(temp_root) or {}
		return error('Failed to populate compilation overlay: ${err}')
	}

	work_rel := path_relative_to(source_work_dir, source_root) or {
		os.rmdir_all(temp_root) or {}
		return error('Source work directory is outside overlay root: ${source_work_dir}')
	}
	file_rel := path_relative_to(canonical_real_path, source_root) or {
		os.rmdir_all(temp_root) or {}
		return error('Source file is outside overlay root: ${canonical_real_path}')
	}
	temp_work_dir := if work_rel == '' {
		temp_root
	} else {
		os.join_path(temp_root, work_rel)
	}
	if !os.exists(temp_work_dir) {
		os.mkdir_all(temp_work_dir) or {
			os.rmdir_all(temp_root) or {}
			return error('Failed to create overlay work directory ${temp_work_dir}: ${err}')
		}
	}
	return CompilationOverlay{
		source_root:         source_root
		source_display_root: source_display_root
		temp_root:           temp_root
		source_work_dir:     source_work_dir
		temp_work_dir:       temp_work_dir
		temp_source_file:    os.join_path(temp_root, file_rel)
	}
}

// source_path_from_overlay maps compiler paths in the temporary project back to
// their original source paths.
fn source_path_from_overlay(reported_path string, overlay CompilationOverlay) string {
	mut candidate := normalize_overlay_path(reported_path)
	if candidate.starts_with('./') || candidate.starts_with('.\\') {
		candidate = os.join_path(overlay.temp_work_dir, candidate[2..])
	} else if !os.is_abs_path(candidate) {
		candidate = os.join_path(overlay.temp_work_dir, candidate)
	}
	if path_is_within(candidate, overlay.temp_root) {
		rel := path_relative_to(candidate, overlay.temp_root) or { return candidate }
		return os.join_path(overlay.source_display_root, rel)
	}
	return candidate
}

fn (mut app App) run_v_check(path string, text string) []JsonError {
	real_path := uri_to_path(path)
	working_dir := os.dir(real_path)
	mut temp_project_dir := ''
	mut file_to_check := ''
	mut compile_target := ''
	mut use_multifile := false
	mut singlefile_tmppath := ''
	mut overlay := CompilationOverlay{}

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

	if should_use_compilation_overlay(real_path, app.open_files.len) {
		overlay = app.prepare_compilation_overlay(real_path) or {
			log('Failed to prepare compilation overlay: ${err}')
			CompilationOverlay{}
		}
		if overlay.temp_root != '' {
			temp_project_dir = overlay.temp_root
			file_to_check = overlay.temp_source_file
			compile_target = overlay.temp_work_dir
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

		for err in json_errors {
			err_file := source_path_from_overlay(err.path, overlay)
			if normalized_index_path(err_file) == normalized_index_path(real_path) {
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
				log('EXCLUDING ERROR from err_file=${err_file} real_path=${real_path}')
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
	temp_project_dir := os.join_path(app.temp_dir, 'project_${time.now().unix_nano()}')
	os.mkdir_all(temp_project_dir) or { return error('Failed to create temp project dir: ${err}') }

	// write file structure
	for uri, content in app.open_files {
		real_path := normalize_overlay_path(os.real_path(uri_to_path(uri)))

		// Normalize slashes for comparison
		normalized_real := normalize_overlay_path(real_path)
		normalized_working := normalize_overlay_path(os.real_path(working_dir))

		// Skip files outside the working dir. On Windows the containment check is
		// case-insensitive, while the returned path preserves its original case.
		mut rel_path := path_relative_to(normalized_real, normalized_working) or {
			log('SKIPPING FILE: ${real_path}')
			continue
		}

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

type OverlayLinkFn = fn (string, string) !

const overlay_copy_excluded_dirs = ['.git', '.hg', '.svn', '.cache', '.idea', '.vscode', '.vmodules',
	'node_modules', '_build', 'build', 'target']

fn create_overlay_symlink(source_path string, target_path string) ! {
	os.symlink(source_path, target_path)!
}

fn symlink_untracked_files(source_root string, source_module_dir string, temp_dir string, tracked_files map[string]string) ! {
	symlink_untracked_files_with_linker(source_root, source_module_dir, temp_dir, tracked_files,
		create_overlay_symlink)!
}

fn symlink_untracked_files_with_linker(source_root string, source_module_dir string, temp_dir string, tracked_files map[string]string, link_fn OverlayLinkFn) ! {
	log('SYMLINKING FROM ${source_root} TO ${temp_dir}')
	mut tracked_rel_paths := []string{}
	canonical_source_root := normalize_overlay_path(os.real_path(source_root))
	canonical_module_dir := normalize_overlay_path(os.real_path(source_module_dir))
	for uri, _ in tracked_files {
		real_path := normalize_overlay_path(os.real_path(uri_to_path(uri)))
		if rel := path_relative_to(real_path, canonical_source_root) {
			tracked_rel_paths << normalize_overlay_path(rel)
		}
	}
	local_import_dirs := local_import_rel_dirs(canonical_source_root, canonical_module_dir,
		tracked_files)
	symlink_untracked_tree(canonical_source_root, canonical_source_root, temp_dir, '',
		tracked_rel_paths, local_import_dirs, link_fn)!
}

// local_import_rel_dirs returns project-local module directories imported by
// tracked buffers, including their local import closure. These directories must
// be real directories in the overlay: the V checker resolves symlinked local
// module files back outside the temporary project and gd^ can then stop at the
// import declaration instead of the requested symbol.
fn local_import_rel_dirs(source_root string, source_module_dir string, tracked_files map[string]string) []string {
	mut pending := []string{}
	for _, content in tracked_files {
		pending << parse_imports(content)
	}
	mut seen_modules := map[string]bool{}
	mut seen_dirs := map[string]bool{}
	mut result := []string{}
	for pending.len > 0 {
		module_path := pending.pop()
		if module_path == '' || module_path in seen_modules {
			continue
		}
		seen_modules[module_path] = true
		rel_dir := module_path.replace('.', '/')
		mut module_dir := os.join_path(source_module_dir, rel_dir)
		if !os.is_dir(module_dir) {
			module_dir = os.join_path(source_root, rel_dir)
		}
		if !os.is_dir(module_dir) {
			continue
		}
		normalized_module_dir := normalize_overlay_path(os.real_path(module_dir))
		normalized_rel := path_relative_to(normalized_module_dir, source_root) or { continue }
		if normalized_rel == '' || normalized_rel in seen_dirs {
			continue
		}
		seen_dirs[normalized_rel] = true
		result << normalized_rel
		for entry in os.ls(module_dir) or { [] } {
			if !entry.ends_with('.v') || entry.ends_with('_test.v') {
				continue
			}
			content := os.read_file(os.join_path(module_dir, entry)) or { continue }
			pending << parse_imports(content)
		}
	}
	return result
}

// copy_bounded_overlay_entry is the fallback for hosts where directory symlinks
// are unavailable. It preserves regular project files, including embedded
// assets, while pruning metadata, dependency caches, and build-output trees.
fn copy_bounded_overlay_entry(source_path string, target_path string, source_root string, mut visited map[string]bool) !int {
	real_path := normalize_overlay_path(os.real_path(source_path))
	if !path_is_within(real_path, source_root) {
		return 0
	}
	if os.is_dir(source_path) {
		name := os.file_name(source_path)
		if name in overlay_copy_excluded_dirs || real_path in visited {
			return 0
		}
		visited[real_path] = true
		mut copied := 0
		for entry in os.ls(source_path)! {
			copied += copy_bounded_overlay_entry(os.join_path(source_path, entry), os.join_path(target_path,
				entry), source_root, mut visited)!
		}
		return copied
	}
	if !os.is_file(source_path) {
		return 0
	}
	os.mkdir_all(os.dir(target_path))!
	os.cp(source_path, target_path)!
	return 1
}

fn symlink_untracked_tree(source_root string, source_dir string, target_dir string, relative_dir string, tracked_rel_paths []string, local_import_dirs []string, link_fn OverlayLinkFn) ! {
	entries := os.ls(source_dir)!
	for entry in entries {
		source_path := os.join_path(source_dir, entry)
		relative_path := if relative_dir == '' {
			entry
		} else {
			relative_dir + '/' + entry
		}
		target_path := os.join_path(target_dir, entry)
		if relative_path in tracked_rel_paths {
			continue
		}

		mut has_tracked_descendant := false
		prefix := relative_path + '/'
		for tracked_path in tracked_rel_paths {
			if tracked_path.starts_with(prefix) {
				has_tracked_descendant = true
				break
			}
		}
		mut materialize_dir := relative_path in local_import_dirs
		if !materialize_dir {
			for import_dir in local_import_dirs {
				if import_dir.starts_with(relative_path + '/') {
					materialize_dir = true
					break
				}
			}
		}
		if os.is_dir(source_path) && (has_tracked_descendant || materialize_dir) {
			if !os.exists(target_path) {
				os.mkdir_all(target_path)!
			}
			symlink_untracked_tree(source_root, source_path, target_path, relative_path,
				tracked_rel_paths, local_import_dirs, link_fn)!
			continue
		}
		if os.exists(target_path) || os.is_link(target_path) {
			continue
		}
		if relative_dir in local_import_dirs && source_path.ends_with('.v')
			&& os.is_file(source_path) {
			os.link(source_path, target_path) or { os.cp(source_path, target_path)! }
			log('Materialized local module file: ${source_path} -> ${target_path}')
			continue
		}
		link_fn(source_path, target_path) or {
			log('Failed to symlink ${source_path}; using bounded overlay copy: ${err}')
			mut visited := map[string]bool{}
			copied :=
				copy_bounded_overlay_entry(source_path, target_path, source_root, mut visited)!
			log('Copied ${copied} project files from ${source_path} into the overlay')
			continue
		}
		log('Symlinked untracked path: ${source_path} -> ${target_path}')
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
	open_uris_by_path := app.open_index_uris_by_path()
	for change in params.changes {
		event_uri := change.uri
		uri := open_uris_by_path[normalized_index_path(uri_to_path(event_uri))] or { event_uri }
		// A watcher may spell an open document URI differently from the client
		// (for example file:///tmp/a.v versus file://localhost/tmp/a.v). Remove
		// any disk-backed alias and keep all subsequent work on the authoritative
		// editor-owned URI.
		if event_uri != uri {
			app.drop_index_uri(event_uri)
			app.index_skipped_uris.delete(event_uri)
			app.diag_cache.delete(event_uri)
		}
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
	mut overlay := CompilationOverlay{}

	log('COMPILER OVERLAY for method=${method}, open files=${app.open_files.len}')
	if should_use_compilation_overlay(real_path, app.open_files.len) {
		overlay = app.prepare_compilation_overlay(real_path) or {
			log('Failed to prepare compilation overlay: ${err}')
			CompilationOverlay{}
		}
		if overlay.temp_root != '' {
			temp_project_dir = overlay.temp_root
			file_to_check = overlay.temp_source_file
			compile_target = overlay.temp_work_dir
			use_multifile = true
			log('temp_project_dir=${temp_project_dir}, file_to_check=${file_to_check}, compile_target=${compile_target}')
		}
	}

	if !use_multifile {
		if method == .definition || method == .declaration || method == .type_definition
			|| method == .implementation {
			log('Using single file compilation from disk')
			file_to_check = real_path
			compile_target = real_path
		} else {
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
						imported_module := imported_module_at_symbol(file_lines[cursor_line],
							cursor_col, file_content)
						doc = app.find_doc_comment_for_symbol(cursor_symbol, file_lines, path,
							imported_module)
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
					uri_path = source_path_from_overlay(uri_path, overlay)
					log('MAPPED TO uri_path=${uri_path}')
				}
				// Build a proper percent-encoded DocumentUri so paths containing
				// spaces, `#`, `%`, or Unicode are valid and match the client's URI
				// keys (P0-10). The compiler reports a byte column; convert it to
				// the client's encoding using the target file's line (P0-01).
				result = app.compiler_location(uri_path, line_nr, col)
			}
		}
		else {}
	}

	return result
}

// compiler_location maps a compiler-reported filesystem path back to the
// original URI of an equivalent open document before converting its byte
// column. This keeps both the URI spelling and position based on the
// authoritative unsaved buffer.
fn (app &App) compiler_location(path string, line int, byte_col int) Location {
	target_uri := index_uri_for_path(path, app.open_index_uris_by_path())
	client_col := app.byte_col_to_client_col(target_uri, line, byte_col)
	return Location{
		uri:   target_uri
		range: LSPRange{
			start: Position{
				line: line
				char: client_col
			}
			end:   Position{
				line: line
				char: client_col
			}
		}
	}
}
