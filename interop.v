// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
import json
import os
import time

fn (mut app App) run_v_check(path string, text string) []JsonError {
	tmpdir := os.temp_dir()
	name := path.all_after_last('/')
	tmppath := tmpdir + '/' + name
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

fn (mut app App) run_v_line_info(path string, line_nr int, col int) JsonVarAC {
	tmpdir := os.temp_dir()
	name := path.all_after_last('/')
	tmppath := tmpdir + '/' + name
	log('WRITING FILE ${time.now()} ${path}')
	os.write_file(tmppath, app.text) or { panic(err) }
	log('running v.exe line info!')
	cmd := 'v -check -json-errors -nocolor -vls-mode -line-info "${tmppath}:${line_nr}:${col}" ${tmppath}'
	log('cmd=${cmd}')
	x := os.execute(cmd)
	log('RUN RES ${x}')
	js := x.output
	log('js=${js}')
	json_errors := json.decode(JsonVarAC, x.output) or {
		log('failed to parse json ${err}')
		return JsonVarAC{}
	}
	log('json2:')
	log('${json_errors}')
	return json_errors
}

// In this mode V returns `/path/to/file.v:line:col`, not json
// So simply return `Location`
fn (mut app App) run_v_go_to_definition(path string, line_nr int, expr string) Location {
	tmpdir := os.temp_dir()
	name := path.all_after_last('/')
	tmppath := tmpdir + '/' + name
	log('WRITING FILE ${time.now()} ${path}')
	os.write_file(tmppath, app.text) or { panic(err) }
	log('running v.exe definition lookup!')
	// This uses the expression instead of line/col
	cmd := 'v -check -json-errors -nocolor -vls-mode -line-info "${tmppath}:${line_nr}:gd^${expr}" ${tmppath}'
	log('cmd=${cmd}')
	x := os.execute(cmd)
	log('RUN RES ${x}')
	vals := x.output.split(':')
	if vals.len != 3 {
		log('gotodef vals.len != 3 vals:${vals}')
		return Location{}
	}
	line := vals[1].int()
	col := vals[2].int()
	return Location{
		uri:   'file://' + vals[0]
		range: LSPRange{
			start: Position{
				line: line
				char: col
			}
			end:   Position{
				line: line
				char: col
			}
		}
	}
}

fn (mut app App) run_v_fn_sig(path string, line_nr int, char_pos int) SignatureHelp {
	tmpdir := os.temp_dir()
	name := path.all_after_last('/')
	tmppath := tmpdir + '/' + name
	log('WRITING FILE ${time.now()} ${path}')
	os.write_file(tmppath, app.text) or { panic(err) }
	log('running v.exe sig!')
	cmd := 'v -check -json-errors -nocolor -vls-mode -line-info "${tmppath}:${line_nr}:fn^${char_pos}" ${tmppath}'
	log('cmd=${cmd}')
	x := os.execute(cmd)
	log('RUN RES ${x}')
	s := x.output.trim_space()
	log('s=${s}')
	json_errors := json.decode(SignatureHelp, x.output) or {
		log('failed to parse json ${err}')
		return SignatureHelp{}
	}
	log('json2:')
	log('${json_errors}')
	return json_errors
}
