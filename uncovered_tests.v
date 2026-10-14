// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// One function of a source file, as `v cover --json` reports it.
struct CoverageFunction {
	name    string
	line    int
	covered bool
	hits    u64
}

// One file of a `v cover --json` report.
struct CoverageJsonFile {
	file             string
	functions        []CoverageFunction
	function_points  int
	function_covered int
}

// The whole `v cover --json` report. Only the fields a code action needs are
// declared, so a report written by a newer compiler decodes instead of failing.
struct CoverageJsonReport {
	files []CoverageJsonFile
}

// UntestedFunction is a function no run entered, with where it is declared.
struct UntestedFunction {
	name string
	line int
}

// read_untested_functions asks `v cover` which functions a coverage run never
// entered, for one source file.
//
// The reading is one invocation of the tool over a directory that already holds
// a run's counters, so it compiles nothing. `path` is the source file to answer
// for, and `directory` the coverage directory the report is read from.
fn read_untested_functions(directory string, path string) []UntestedFunction {
	if directory == '' || !os.is_dir(directory) {
		return []
	}
	report_path := os.join_path(os.temp_dir(), 'vls_cover_${os.getpid()}.json')
	defer {
		os.rm(report_path) or {}
	}
	// The report is written for absolute paths, which is how the compiler spells
	// a source file, so the path is asked for unchanged.
	ran := run_v_argv(['cover', directory, '--json', report_path, '-P', 'false', '-A'],
		os.dir(path))
	if ran.exit_code != 0 {
		return []
	}
	raw := os.read_file(report_path) or { return [] }
	report := json2.decode[CoverageJsonReport](raw) or { return [] }
	return untested_functions_of(report, path)
}

// untested_functions_of returns the functions of `path` that no run entered,
// in source order. `path` is the file the report was written for, spelled the
// way the compiler spelled it, so the caller passes it unchanged.
fn untested_functions_of(report CoverageJsonReport, path string) []UntestedFunction {
	mut target := path.replace('\\', '/')
	mut functions := []UntestedFunction{}
	for file in report.files {
		if file.file.replace('\\', '/') != target {
			continue
		}
		for function in file.functions {
			if function.covered {
				continue
			}
			functions << UntestedFunction{
				name: function.name
				line: function.line - 1
			}
		}
	}
	functions.sort(a.line < b.line)
	return functions
}

// coverage_missing_message is what a user is told when a test-generation
// action cannot run. Both cases are the same fix, so they read as one.
fn coverage_missing_message() string {
	return 'vls: no coverage run is recorded for this project. Run the tests with a ' +
		'coverage directory, then set `vls.coverageDirectory` (or `coverageDirectory` in vls.json) to it.'
}

// build_untested_test_actions offers one action per function the coverage run
// never entered, plus one for the whole file.
//
// The actions carry a command rather than an edit: the test body is written by
// `v cover --write-tests`, which is the one tool that generates it, so the
// server only points at the function. `path` is the source file being edited and
// `range` the selection, so an action inside one function offers only that one.
fn (mut app App) build_untested_test_actions(uri string, path string, range LSPRange) []CodeAction {
	directory := app.coverage_directory_for_path(path)
	if directory == '' {
		return []
	}
	functions := read_untested_functions(directory, path)
	if functions.len == 0 {
		return []
	}
	mut selected := []UntestedFunction{}
	for function in functions {
		if range_contains_line(range, function.line) {
			selected << function
		}
	}
	mut actions := []CodeAction{}
	for function in selected {
		actions << CodeAction{
			title:   "Generate test for '${function.name}'"
			kind:    code_action_kind_quickfix
			command: Command{
				title:     'Generate test'
				command:   'vls.generateTest'
				arguments: [uri]
			}
		}
	}
	// One function is its own action, so a second, file-wide action is only
	// offered when there is more than one to write.
	if selected.len > 1 {
		actions << CodeAction{
			title:   'Generate ${selected.len} untested test functions'
			kind:    code_action_kind_quickfix
			command: Command{
				title:     'Generate tests'
				command:   'vls.generateTest'
				arguments: [uri]
			}
		}
	}
	return actions
}

// range_contains_line reports whether a range covers a line, which is how a
// declaration is selected: the cursor anywhere on it selects it.
fn range_contains_line(range LSPRange, line int) bool {
	return line >= range.start.line && line <= range.end.line
}

// write_tests_for_file asks `v cover` to write the test functions `path` is
// missing, and reports what it wrote. The tool writes beside the source, so the
// directory it needs is the one the coverage run recorded into.
fn write_tests_for_file(directory string, path string) !string {
	ran := run_v_argv(['cover', directory, '--write-tests', '--filter', path, '-P', 'false'],
		os.dir(path))
	if ran.exit_code != 0 {
		return error('v cover failed: ${ran.output}')
	}
	return ran.output
}
