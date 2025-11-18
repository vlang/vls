// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
import json
import os
import time

fn (mut app App) run_v_check(path string, text string) []JsonError {
	workspace := app.get_workspace_for_file(path)
	tmppath := os.join_path(os.temp_dir(), os.file_name(path))
	log('WRITING FILE ${time.now()} ${path}')
	os.write_file(tmppath, text) or { panic(err) }
	log('running v.exe check')
	cmd := 'v -w -vls-mode -check -json-errors "${workspace}"'
	log('cmd=${cmd}')
	x := os.execute(cmd)
	log('RUN RES ${x}')
	js := x.output
	log('js=${js}')
	json_errors := json.decode([]JsonError, x.output) or {
		log('failed to parse json ${err}')
		return []
	}
	has_multiple_mains := json_errors.any(it.message.contains('multiple `main` functions detected'))
	if has_multiple_mains {
		cmd_single := 'v -w -vls-mode -check -json-errors "${tmppath}"'
		x_single := os.execute(cmd_single)
		json_errors_single := json.decode([]JsonError, x_single.output) or {
			log('failed to parse json ${err}')
			return []
		}
		return json_errors_single
	}
	original_path := path.replace('file://', '').replace('file:///', '/')
	filtered_errors := json_errors.filter(it.path == os.file_name(original_path)
		|| it.path == original_path)
	log('json2:')
	log('${filtered_errors}')
	return filtered_errors
}

fn (mut app App) run_v_line_info(method Method, path string, line_info string) ResponseResult {
	workspace := app.get_workspace_for_file(path)
	tmppath := os.join_path(os.temp_dir(), os.file_name(path))
	log('WRITING FILE ${time.now()} ${path}')
	os.write_file(tmppath, app.text) or { panic(err) }
	log('running v.exe line info!')
	cmd := 'v -w -check -json-errors -nocolor -vls-mode -line-info "${tmppath}:${line_info}" ${workspace}'
	log('cmd=${cmd}')
	x := os.execute(cmd)
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
