// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
import json
import os
import time

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
	tmppath := os.join_path(os.temp_dir(), os.file_name(path))
	log('WRITING FILE ${time.now()} ${path}')
	os.write_file(tmppath, app.text) or { panic(err) }
	log('running v.exe line info!')
	cmd := 'v -w -check -json-errors -nocolor -vls-mode -line-info "${tmppath}:${line_info}" ${tmppath}'
	log('cmd=${cmd}')
	x := os.execute(cmd)
	log('RUN RES ${x}')
	mut result := ResponseResult{}
	match method {
		.completion {
			result = json.decode([]Detail, x.output) or { [] }
		}
		.signature_help {
			result = json.decode(SignatureHelp, x.output) or { SignatureHelp{} }
		}
		.definition {
			result = json.decode(Location, x.output) or { Location{} }
		}
		else {}
	}
	return result
}
