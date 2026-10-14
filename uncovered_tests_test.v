// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

const coverage_report_json = '{
	"files": [
		{
			"file": "/w/app/parser.v",
			"function_points": 3,
			"function_covered": 1,
			"functions": [
				{"name": "parse_text", "line": 3, "covered": true, "hits": 12},
				{"name": "parse_heading", "line": 14, "covered": false, "hits": 0},
				{"name": "parse_list", "line": 31, "covered": false, "hits": 0}
			]
		},
		{
			"file": "/w/app/other.v",
			"function_points": 1,
			"function_covered": 1,
			"functions": [
				{"name": "other", "line": 1, "covered": true, "hits": 4}
			]
		}
	]
}'

fn test_untested_functions_of_reads_only_the_uncovered_ones_of_one_file() {
	report := json2.decode[CoverageJsonReport](coverage_report_json) or {
		assert false, 'the fixture report must decode'
		return
	}
	functions := untested_functions_of(report, '/w/app/parser.v')
	assert functions.len == 2
	assert functions[0].name == 'parse_heading'
	// The line is what an editor addresses, so it is one less than the source's.
	assert functions[0].line == 13
	assert functions[1].name == 'parse_list'
	assert functions[1].line == 30
}

fn test_untested_functions_of_reports_nothing_for_a_file_with_no_gaps() {
	report := json2.decode[CoverageJsonReport](coverage_report_json) or {
		assert false, 'the fixture report must decode'
		return
	}
	assert untested_functions_of(report, '/w/app/other.v') == []
}

fn test_untested_functions_of_reports_nothing_for_a_file_the_report_lacks() {
	report := json2.decode[CoverageJsonReport](coverage_report_json) or {
		assert false, 'the fixture report must decode'
		return
	}
	assert untested_functions_of(report, '/w/app/missing.v') == []
}

fn test_untested_functions_of_matches_a_path_spelled_with_backslashes() {
	// The compiler spells a Windows path with backslashes, and the report is
	// read from the file the editor named, so both spellings must land on it.
	report := json2.decode[CoverageJsonReport](coverage_report_json) or {
		assert false, 'the fixture report must decode'
		return
	}
	functions := untested_functions_of(report, '\\w\\app\\parser.v')
	assert functions.len == 2
	assert functions[0].name == 'parse_heading'
}

fn test_coverage_report_survives_an_unknown_field() {
	// A report written by a newer compiler carries keys this build does not
	// know. They are dropped rather than failing the decode, because a coverage
	// report is an extra and never a reason a code action breaks.
	raw := '{"files":[{"file":"/w/app/a.v","functions":[],"branch_points":4}]}'
	report := json2.decode[CoverageJsonReport](raw) or {
		assert false, 'an unknown field must not fail the decode: ${err}'
		return
	}
	assert report.files.len == 1
	assert report.files[0].file == '/w/app/a.v'
}

fn test_read_untested_functions_reports_nothing_without_a_directory() {
	// No coverage directory configured means no action, and never a crash.
	assert read_untested_functions('', '/w/app/parser.v') == []
	assert read_untested_functions(os.join_path(os.temp_dir(), 'vls_no_such_cov_dir'),
		'/w/app/parser.v') == []
}

fn test_range_contains_line_selects_the_declaration_line() {
	declared := LSPRange{
		start: Position{ line: 13, char: 0 }
		end:   Position{ line: 13, char: 3 }
	}
	assert range_contains_line(declared, 13)
	assert !range_contains_line(declared, 12)
	assert !range_contains_line(declared, 14)
	// A selection spanning several lines selects every one of them.
	block := LSPRange{
		start: Position{ line: 12, char: 4 }
		end:   Position{ line: 15, char: 0 }
	}
	assert range_contains_line(block, 13)
	assert range_contains_line(block, 14)
}

fn test_coverage_missing_message_names_the_settings_key() {
	message := coverage_missing_message()
	assert message.contains('vls.coverageDirectory')
	assert message.contains('vls.json')
}

// cov_test_app returns an App of its own with one workspace root and no
// configuration inherited from elsewhere. Every _test.v file of this program is
// `module main`, but a test runner compiles each file on its own, so a helper
// defined in another file is not visible here.
fn cov_test_app(root string) &App {
	mut store := vls_config_store()
	store.set_editor_settings(EditorSettings{})
	store.drop_config(root)
	return &App{
		temp_dir:        root
		open_files:      map[string]string{}
		workspace_roots: [root]
	}
}

fn cov_test_project(tag string) string {
	root := os.join_path(os.temp_dir(), 'vls_cov_${tag}_${os.getpid()}')
	os.mkdir_all(root) or {
		assert false, 'cannot make ${root}'
		return ''
	}
	os.write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'covtest'\n}\n") or {
		assert false, 'cannot write v.mod'
	}
	return root
}

// build_untested_test_actions offers nothing without a coverage directory: the
// action reads a run that has not happened, and offering it anyway would only
// produce a message.
fn test_no_test_action_without_a_coverage_directory() {
	root := cov_test_project('absent')
	defer {
		os.rmdir_all(root) or {}
	}
	source := os.join_path(root, 'main.v')
	os.write_file(source, 'module main\n\nfn main() {}\n') or {
		assert false, 'cannot write ${source}'
	}
	app := cov_test_app(root)
	actions := app.build_untested_test_actions('file:///tmp/x.v', source, LSPRange{
		start: Position{ line: 0, char: 0 }
		end:   Position{ line: 0, char: 0 }
	})
	assert actions.len == 0, 'no coverage directory means no action, got ${actions.len}'
}

// With a directory that holds no report, the tool reports nothing, so no action
// is offered. A directory that does not exist gives the same answer.
fn test_no_test_action_for_a_directory_without_a_report() {
	root := cov_test_project('noreport')
	defer {
		os.rmdir_all(root) or {}
	}
	coverage := os.join_path(root, 'vcov')
	os.mkdir_all(coverage) or { assert false, 'cannot make ${coverage}' }
	source := os.join_path(root, 'main.v')
	os.write_file(source, 'module main\n\nfn main() {}\n') or {
		assert false, 'cannot write ${source}'
	}
	mut app := cov_test_app(root)
	app.apply_editor_configuration('{"settings":{"vls":{"coverageDirectory":"' + coverage.replace('\\',
		'\\\\') + '"}}}')
	assert app.coverage_directory_for_path(source) == coverage, 'the configured directory reaches the action'
	actions := app.build_untested_test_actions('file:///tmp/x.v', source, LSPRange{
		start: Position{ line: 0, char: 0 }
		end:   Position{ line: 0, char: 0 }
	})
	assert actions.len == 0, 'a directory without a report offers no action, got ${actions.len}'
}

// An action is offered for a function on the line the cursor is on, and for no
// other, so the lightbulb answers the question the cursor asked.
fn test_an_action_covers_the_line_the_cursor_is_on() {
	report := CoverageJsonReport{
		files: [
			CoverageJsonFile{
				file:      '/w/app/parser.v'
				functions: [
					CoverageFunction{
						name:    'parse_heading'
						line:    14
						covered: false
					},
					CoverageFunction{
						name:    'parse_list'
						line:    31
						covered: false
					},
				]
			},
		]
	}
	functions := untested_functions_of(report, '/w/app/parser.v')
	assert functions.len == 2
	on_first := LSPRange{
		start: Position{ line: 13, char: 0 }
		end:   Position{ line: 13, char: 3 }
	}
	assert range_contains_line(on_first, functions[0].line)
	assert !range_contains_line(on_first, functions[1].line)
	// A selection spanning both offers both.
	spanning := LSPRange{
		start: Position{ line: 13, char: 0 }
		end:   Position{ line: 31, char: 0 }
	}
	assert range_contains_line(spanning, functions[0].line)
	assert range_contains_line(spanning, functions[1].line)
}
