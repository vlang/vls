// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json
import os
import time

fn uri_to_path(uri string) string {
	mut path := uri
	// Remove file:// or file:/// prefix
	if path.starts_with('file:///') || path.starts_with('file://') {
		path = path[7..]
	}
	if path.len > 2 && path[0] == `/` && path[2] == `:` {
		path = path[1..]
	}
	return path
}

fn path_to_uri(path string) string {
	normalized := os.to_slash(path)
	uri_header := if normalized.starts_with('/') { 'file://' } else { 'file:///' }
	return uri_header + normalized
}

fn make_singlefile_temp_path(temp_root string, real_path string, purpose string) string {
	root := if temp_root != '' { temp_root } else { os.temp_dir() }
	ext := os.file_ext(real_path)
	safe_ext := if ext == '' { '.v' } else { ext }
	tag := if purpose == '' { 'work' } else { purpose }
	return os.join_path(root, 'vls_${tag}_${os.getpid()}_${time.now().unix_nano()}${safe_ext}')
}

fn ensure_stderr_captured(cmd string) string {
	if cmd.contains('2>&1') {
		return cmd
	}
	return '${cmd} 2>&1'
}

fn shell_quote(s string) string {
	// Use double quotes for cross-platform compatibility.
	// Windows CMD does not treat single quotes as string delimiters.
	escaped := s.replace('"', '\\"')
	return '"${escaped}"'
}

fn build_v_check_cmd_single(file_to_check string) string {
	return 'v -w -vls-mode -check -json-errors -nocolor ${shell_quote(file_to_check)}'
}

fn build_v_check_cmd_multifile() string {
	return 'v -w -check -json-errors -nocolor .'
}

fn build_v_line_info_cmd_multifile(rel_file string, line_info string) string {
	return 'v -w -check -json-errors -nocolor -vls-mode -line-info ${shell_quote('${rel_file}:${line_info}')} .'
}

fn build_v_line_info_cmd_single(file_to_check string, line_info string, compile_target string) string {
	vls_flag := '-vls-mode '
	return 'v -w -check -json-errors -nocolor ${vls_flag}-line-info ${shell_quote('${file_to_check}:${line_info}')} ${shell_quote(compile_target)}'
}

fn build_v_fmt_cmd(temp_file string) string {
	return 'v fmt -inprocess -w ${shell_quote(temp_file)}'
}

fn execute_in_dir(dir string, cmd string) os.Result {
	original_dir := os.getwd()
	defer {
		os.chdir(original_dir) or {}
	}
	if dir != '' {
		os.chdir(dir) or {
			msg := 'Failed to change to working dir ${dir}: ${err}'
			log(msg)
			return os.Result{
				exit_code: 1
				output:    msg
			}
		}
	}
	return os.execute(ensure_stderr_captured(cmd))
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
	gen := app.open_files_generation
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

	mut cmd := ''
	if use_multifile {
		cmd = build_v_check_cmd_multifile()
		log('MULTIFILE CMD - compile_target=${compile_target}): ${cmd}')
	} else {
		cmd = build_v_check_cmd_single(file_to_check)
		log('SINGLEFILE CMD: ${cmd}')
	}

	exec_dir := if use_multifile { compile_target } else { working_dir }
	x := execute_in_dir(exec_dir, cmd)

	log('Check - RUN RES ${x}')

	cleanup_compilation_temp(temp_project_dir, singlefile_tmppath)

	json_errors := json.decode([]JsonError, x.output) or {
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

		// skip not in working dir
		if !normalized_real.starts_with(normalized_working) {
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

fn has_sibling_v_files(working_dir string, current_file string) bool {
	v_files := os.walk_ext(working_dir, '.v')
	for v_file in v_files {
		if v_file != current_file {
			return true
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
	params := json.decode(DidChangeWatchedFilesParams, request.params) or {
		$if debug { log('Failed to decode DidChangeWatchedFilesParams: ${err}') }
		return
	}
	for change in params.changes {
		uri := change.uri
		match change.event_type {
			3 {
				// Deleted — remove from tracking if present.
				if uri in app.open_files {
					app.open_files.delete(uri)
					app.open_files_generation++
					log('on_did_change_watched_files: removed deleted file ${uri}')
				}
			}
			1, 2 {
				// Created or Changed — reload from disk if currently tracked.
				if uri in app.open_files {
					real_path := uri_to_path(uri)
					content := os.read_file(real_path) or {
						log('on_did_change_watched_files: cannot read ${real_path}: ${err}')
						continue
					}
					app.open_files[uri] = content
					app.open_files_generation++
					log('on_did_change_watched_files: reloaded ${uri}')
				}
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
			mut wrote_temp := true
			os.write_file(singlefile_tmppath, app.text) or {
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
	mut cmd := ''

	if use_multifile {
		rel_file := os.file_name(file_to_check)
		cmd = build_v_line_info_cmd_multifile(rel_file, line_info)
		log('MULTIFILE CMD compile_target=${compile_target}: ${cmd}')
	} else {
		cmd = build_v_line_info_cmd_single(file_to_check, line_info, compile_target)
		log('SINGLEFILE CMD: ${cmd}')
	}

	exec_dir := if use_multifile { compile_target } else { working_dir }
	mut x := execute_in_dir(exec_dir, cmd)

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
		cmd_fallback := build_v_line_info_cmd_single(file_to_check, line_info, compile_target)
		log('cmd_fallback=${cmd_fallback}')
		x = execute_in_dir(working_dir, cmd_fallback)
		log('Fallback RUN RES ${x}')
	}

	cleanup_compilation_temp(temp_project_dir, singlefile_tmppath)

	log('RUN RES ${x}')
	// Default to JSON null so any unhandled method branch produces a valid LSP response.
	mut result := ResponseResult('null')
	match method {
		.completion {
			result_tmp := json.decode(JsonVarAC, x.output) or { JsonVarAC{} }
			result = result_tmp.details
		}
		.signature_help {
			sig := json.decode(SignatureHelp, x.output) or { SignatureHelp{} }
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
			hover_result := json.decode(Hover, x.output) or { Hover{} }
			// Extract vdoc comment via cross-file search as a fallback when the
			// compiler does not provide documentation.
			mut doc := ''
			file_content := app.open_files[path] or { app.text }
			file_lines := file_content.split_into_lines()
			// line_info format for hover is "${line_nr}:hv^${col}"
			info_parts := line_info.split(':')
			mut cursor_symbol := ''
			if info_parts.len >= 2 {
				cursor_line := info_parts[0].int() - 1
				cursor_col := info_parts[1].all_after('hv^').int()
				if cursor_line >= 0 && cursor_line < file_lines.len {
					cursor_symbol = get_word_at_col(file_lines[cursor_line], cursor_col)
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
				uri_header := if uri_path.starts_with('/') { 'file://' } else { 'file:///' }
				result = Location{
					uri:   uri_header + uri_path
					range: LSPRange{
						start: Position{
							line: line_nr
							char: col
						}
						end:   Position{
							line: line_nr
							char: col
						}
					}
				}
			}
		}
		else {}
	}

	return result
}
