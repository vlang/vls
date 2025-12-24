// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
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

fn (mut app App) run_v_check(path string, text string) []JsonError {
	tmppath := os.join_path(os.temp_dir(), os.file_name(path))
	log('WRITING FILE ${time.now()} ${path}')
	os.write_file(tmppath, text) or { panic(err) }
	log('running v.exe check')
	cmd := 'v -w -vls-mode -check -json-errors "${tmppath}"'
	log('cmd=${cmd}')
	x := os.execute(cmd)
	log('RUN RES ${x}')
	js := x.output
	log('js=${js}')
	json_errors := json.decode([]JsonError, x.output) or {
		log('failed to parse json ${err}')
		return []
	}
	log('json2:')
	log('${json_errors}')
	return json_errors
}

fn (mut app App) run_v_line_info(method Method, path string, line_info string) ResponseResult {
	// Convert URI to local file path
	real_path := uri_to_path(path)
	log('Real path: ${real_path}')
	log('Method: ${method}')

	// Go to defintion on zed requires the real path
	mut file_to_check := real_path
	mut working_dir := os.dir(real_path)
	tmppath := os.join_path(os.temp_dir(), os.file_name(real_path))
	if method == .definition {
		log('WRITING FILE ${time.now()} to real path ${real_path}')
		os.write_file(real_path, app.text) or {
			log('Failed to write to real path: ${err}')
			os.write_file(tmppath, app.text) or { panic(err) }
			file_to_check = tmppath
			working_dir = os.temp_dir()
		}
	} else {
		log('WRITING FILE ${time.now()} to temp path ${tmppath}')
		os.write_file(tmppath, app.text) or { panic(err) }
		file_to_check = tmppath
		working_dir = os.temp_dir()
	}

	log('running v.exe line info!')
	log('file_to_check=${file_to_check}')
	log('working_dir=${working_dir}')
	cmd := 'v -w -check -json-errors -nocolor -vls-mode -line-info "${file_to_check}:${line_info}" ${file_to_check}'
	log('cmd=${cmd}')

	// Change to the working directory to preserve project context
	original_dir := os.getwd()
	os.chdir(working_dir) or { log('Failed to change to working dir: ${err}') }
	x := os.execute(cmd)
	os.chdir(original_dir) or {}

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
		.definition {
			// file.v:line:col => Location
			fields := x.output.trim_space().split(':')
			if fields.len < 3 {
				result = Location{}
			} else {
				line_nr := fields[fields.len - 2].int() - 1
				col := fields[fields.len - 1].int()
				uri_path := os.to_slash(fields[..fields.len - 2].join(':'))
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
