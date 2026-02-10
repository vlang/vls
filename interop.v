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

fn (mut app App) run_v_check(path string, text string) []JsonError {
	real_path := uri_to_path(path)
	working_dir := os.dir(real_path)
	mut temp_project_dir := ''
	mut file_to_check := ''
	mut compile_target := ''
	mut use_multifile := false

	log('running v.exe check for ${real_path}')
	log('Open files count: ${app.open_files.len}')

	if app.open_files.len > 1 || has_sibling_v_files(working_dir, real_path) {
		// Write all tracked files to temp directory
		temp_project_dir = app.write_tracked_files_to_temp(working_dir) or {
			log('Failed to write tracked files: ${err}')
			''
		}

		if temp_project_dir != '' {
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
		tmppath := os.join_path(os.temp_dir(), os.file_name(real_path))
		os.write_file(tmppath, text) or { panic(err) }
		file_to_check = tmppath
		compile_target = tmppath
	}

	original_dir := os.getwd()
	mut cmd := ''
	if use_multifile {
		os.chdir(compile_target) or { log('Failed to change to compile target dir: ${err}') }
		cmd = 'v -w -check -json-errors -nocolor .'
		log('MULTIFILE CMD - compile_target=${compile_target}): ${cmd}')
	} else {
		os.chdir(working_dir) or { log('Failed to change to working dir: ${err}') }
		cmd = 'v -w -vls-mode -check -json-errors -nocolor "${file_to_check}"'
		log('SINGLEFILE CMD: ${cmd}')
	}

	x := os.execute(cmd)
	os.chdir(original_dir) or {}

	log('Check - RUN RES ${x}')

	// Clean up temp files
	if use_multifile && temp_project_dir != '' {
		os.rmdir_all(temp_project_dir) or { log('Failed to clean up temp project dir: ${err}') }
	} else if !use_multifile {
		tmppath := os.join_path(os.temp_dir(), os.file_name(real_path))
		os.rm(tmppath) or { log('Failed to remove temp file: ${err}') }
	}

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
				}
				filtered_errors << updated_err
				log('INCLUDING ERROR from err_file=${err_file}: ${err.message}')
			} else {
				log('EXLUCING ERROR from err_file=${err_file} rel_path_to_check=${rel_path_to_check}')
			}
		}

		log('FILTERED ERRORS: ${filtered_errors.len} of ${json_errors.len}')
		return filtered_errors
	}

	log('JSON ERRORS: ${json_errors.len}')
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
		mut rel_path := normalized_real.replace(normalized_working, '').trim_string_left('/').trim_string_left('\\')
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

fn (mut app App) run_v_line_info(method Method, path string, line_info string) ResponseResult {
	// Convert URI to local file path
	real_path := uri_to_path(path)
	log('real_path=${real_path}, method=${method}')

	mut working_dir := os.dir(real_path)
	mut file_to_check := real_path
	mut compile_target := real_path
	mut temp_project_dir := ''
	mut use_multifile := false

	if method == .definition {
		log('OPEN FILES COUNT: ${app.open_files.len}')
		if app.open_files.len > 1 || has_sibling_v_files(working_dir, real_path) {
			temp_project_dir = app.write_tracked_files_to_temp(working_dir) or {
				log('Failed to write tracked files: ${err}')
				''
			}

			if temp_project_dir != '' {
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
			tmppath := os.join_path(os.temp_dir(), os.file_name(real_path))
			log('WRITING FILE ${time.now()} to temp path ${tmppath}')
			os.write_file(tmppath, app.text) or { panic(err) }
			file_to_check = tmppath
			compile_target = tmppath
		}
	}

	log('running v.exe line info!')
	log('file_to_check=${file_to_check}, compile_target=${compile_target}, working_dir=${working_dir}')
	original_dir := os.getwd()
	mut cmd := ''

	if use_multifile {
		os.chdir(compile_target) or { log('Failed to change to compile target dir: ${err}') }
		rel_file := os.file_name(file_to_check)
		cmd = 'v -w -check -json-errors -nocolor -vls-mode -line-info "${rel_file}:${line_info}" .'
		log('MULTIFILE CMD compile_target=${compile_target}: ${cmd}')
	} else {
		os.chdir(working_dir) or { log('Failed to change to working dir: ${err}') }
		vls_flag := '-vls-mode '
		cmd = 'v -w -check -json-errors -nocolor ${vls_flag}-line-info "${file_to_check}:${line_info}" ${compile_target}'
		log('SINGLEFILE CMD: ${cmd}')
	}

	mut x := os.execute(cmd)
	os.chdir(original_dir) or {}

	if method == .definition && use_multifile && (x.exit_code != 0 || x.output.trim_space() == ''
		|| x.output.trim_space() == '[]') {
		if temp_project_dir != '' {
			os.rmdir_all(temp_project_dir) or { log('Failed to clean up temp project dir: ${err}') }
			temp_project_dir = ''
		}
		file_to_check = real_path
		compile_target = real_path
		cmd_fallback := 'v -w -check -json-errors -nocolor -vls-mode -line-info "${file_to_check}:${line_info}" ${compile_target}'
		log('cmd_fallback=${cmd_fallback}')
		original_dir_fallback := os.getwd()
		os.chdir(working_dir) or { log('Failed to change to working dir: ${err}') }
		x = os.execute(cmd_fallback)
		os.chdir(original_dir_fallback) or {}
		log('Fallback RUN RES ${x}')
	}

	// Clean up temp files
	if temp_project_dir != '' {
		os.rmdir_all(temp_project_dir) or { log('Failed to clean up temp project dir: ${err}') }
	} else if !use_multifile {
		tmppath := os.join_path(os.temp_dir(), os.file_name(real_path))
		os.rm(tmppath) or { log('Failed to remove temp file: ${err}') }
	}

	log('RUN RES ${x}')
	mut result := ResponseResult{}
	match method {
		.completion {
			result_tmp := json.decode(JsonVarAC, x.output) or { JsonVarAC{} }
			result = result_tmp.details
		}
		.signature_help {
			result = json.decode(SignatureHelp, x.output) or { SignatureHelp{} }
		}
		.hover {
			result_tmp := json.decode(JsonVarAC, x.output) or { JsonVarAC{} }
			if result_tmp.details.len > 0 {
				detail := result_tmp.details[0]
				mut content := '```v\n${detail.detail}\n```'
				if detail.documentation != '' {
					content += '\n\n${detail.documentation}'
				}
				result = Hover{
					contents: MarkupContent{
						kind:  'markdown'
						value: content
					}
				}
			} else {
				result = Hover{
					contents: MarkupContent{
						kind:  'plaintext'
						value: ''
					}
				}
			}
		}
		.definition {
			// file.v:line:col => Location
			fields := x.output.trim_space().split(':')
			if fields.len < 3 || x.output.trim_space() == '' {
				result = Location{}
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
