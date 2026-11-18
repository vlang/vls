// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os

// Tests for the "Extract function" quiet fix. Every _test.v file of this
// project shares module main, so the helpers here carry the xtr_ prefix.

fn xtr_dir(tag string) string {
	dir := os.join_path(os.temp_dir(), 'vls_xtr_${tag}_${os.getpid()}')
	os.mkdir_all(dir) or { assert false, 'mkdir failed: ${err}' }
	return dir
}

// xtr_app opens `content` in its own project directory.
fn xtr_app(tag string, content string) (&App, string) {
	dir := xtr_dir(tag)
	uri := path_to_uri(os.join_path(dir, 'main.v'))
	os.write_file(uri_to_path(uri), content) or { assert false, 'write failed: ${err}' }
	return &App{
		open_files: {
			uri: content
		}
		temp_dir:   dir
	}, uri
}

// xtr_range returns a range covering whole lines [from, to].
fn xtr_range(content string, from int, to int) LSPRange {
	lines := content.split_into_lines()
	mut last := 0
	for idx in 0 .. to + 1 {
		if idx < lines.len {
			last = lines[idx].len
		}
	}
	return LSPRange{
		start: Position{
			line: from
			char: 0
		}
		end:   Position{
			line: to
			char: last
		}
	}
}

// xtr_texts returns the new_text of the action's edits, in order.
fn xtr_texts(action CodeAction) []string {
	mut texts := []string{}
	edit := action.edit or { return texts }
	for change in edit.changes[''] or { []TextEdit{} } {
		texts << change.new_text
	}
	return texts
}

// xtr_run builds the action for whole lines [from, to] and returns its texts.
fn xtr_run(tag string, content string, from int, to int) []string {
	mut app, uri := xtr_app(tag, content)
	action := app.build_extract_function_action(uri, content, xtr_range(content, from,
		to)) or { return []string{} }
	return xtr_texts(action)
}

fn xtr_offered(tag string, content string, sel_range LSPRange) bool {
	mut app, uri := xtr_app(tag, content)
	return app.build_extract_function_action(uri, content, sel_range) != none
}

const xtr_simple_main = 'module main\n\nfn compute(a int, b int) int {\n\ttwice := a * 2\n\tprintln(b)\n\treturn twice\n}\n\nfn main() {\n\tprintln(compute(2, 3))\n}\n'

fn test_extract_function_lifts_statements_and_passes_reads() {
	// Lines 3 and 4 (`twice := ...`, `println(b)`) become a function that
	// takes `a` and `b`, and the selection is replaced by its call.
	texts := xtr_run('happy', xtr_simple_main, 3, 4)
	assert texts.len == 2, texts.str()
	assert texts[0].starts_with('fn extracted_0(a int, b int) {'), texts[0]
	assert texts[0].contains('twice := a * 2'), texts[0]
	assert texts[0].contains('println(b)'), texts[0]
	assert texts[1] == 'extracted_0(a, b)', texts[1]
}

fn test_extract_function_returns_the_single_assigned_local() {
	// `total` is a local of the enclosing function that the selection
	// reassigns, so it becomes the return value and the call site keeps its
	// assignment shape.
	content := 'module main\n\nfn run(input int) int {\n\tmut total := 0\n\tdouble(input)\n\ttotal = input * 2\n\treturn total\n}\n\nfn double(v int) {\n\tprintln(v)\n}\n'
	texts := xtr_run('ret', content, 5, 5)
	assert texts.len == 2, texts.str()
	assert texts[0].starts_with('fn extracted_0(input int) int {'), texts[0]
	assert texts[0].contains('return total'), texts[0]
	assert texts[1] == 'extracted_0(input)', texts[1]
}

fn test_extract_function_refuses_two_assigned_locals() {
	content := 'module main\n\nfn run(input int) {\n\tmut a := 0\n\tmut b := 0\n\ta = input\n\tb = input\n\tprintln(a, b)\n}\n'
	mut app, uri := xtr_app('two', content)
	assert app.build_extract_function_action(uri, content, xtr_range(content, 4, 5)) == none, 'two reassigned locals must not become two return values'
}

fn test_extract_function_refuses_a_return_of_the_enclosing_function() {
	content := 'module main\n\nfn run(a int) {\n\tif a > 0 {\n\t\treturn\n\t}\n\tprintln(a)\n}\n'
	mut app, uri := xtr_app('ret2', content)
	// Selecting the `return` itself: lifting it would change where the
	// function ends.
	assert app.build_extract_function_action(uri, content, xtr_range(content, 3, 3)) == none
}

fn test_extract_function_refuses_a_partial_line() {
	partial := LSPRange{
		start: Position{
			line: 3
			char: 2
		}
		end:   Position{
			line: 3
			char: 6
		}
	}
	assert !xtr_offered('partial', xtr_simple_main, partial)
}

fn test_extract_function_refuses_a_selection_across_blocks() {
	// From a statement inside the body to the closing brace of the fn.
	mut app, uri := xtr_app('blocks', xtr_simple_main)
	assert app.build_extract_function_action(uri, xtr_simple_main, xtr_range(xtr_simple_main,
		3, 5)) == none
}

fn test_extract_function_refuses_an_untyped_name() {
	// `value` is a local of the enclosing function whose declaration gives no
	// type, so there is nothing trustworthy to pass. The declaration itself
	// (line 3) is not selected: a name the selection declares needs no
	// parameter.
	content := 'module main\n\nfn run() {\n\tvalue := helper()\n\tprintln(value)\n}\n\nfn helper() {}\n'
	mut app, uri := xtr_app('untyped', content)
	assert app.build_extract_function_action(uri, content, xtr_range(content, 4, 4)) == none
}

fn test_extract_function_refuses_an_empty_selection() {
	empty := LSPRange{
		start: Position{
			line: 3
			char: 0
		}
		end:   Position{
			line: 3
			char: 0
		}
	}
	assert !xtr_offered('empty', xtr_simple_main, empty)
}

fn test_extract_function_refuses_outside_a_function() {
	content := 'module main\n\nstruct Point {\n\tx int\n}\n'
	mut app, uri := xtr_app('outside', content)
	assert app.build_extract_function_action(uri, content, xtr_range(content, 2, 3)) == none
}

fn test_extract_function_numbers_the_new_name() {
	content := 'module main\n\nfn extracted_0() {}\n\nfn run(a int) {\n\tprintln(a)\n}\n'
	texts := xtr_run('numbered', content, 5, 5)
	assert texts.len == 2, texts.str()
	assert texts[0].starts_with('fn extracted_1('), texts[0]
}

fn test_extract_function_skips_braces_and_comments() {
	// A brace inside a comment must not shift the enclosing depth scan.
	content := 'module main\n\nfn run(a int) {\n\t// if a { } else { }\n\tprintln(a)\n}\n'
	texts := xtr_run('braces', content, 4, 4)
	assert texts.len == 2, texts.str()
	assert texts[0].starts_with('fn extracted_0(a int) {'), texts[0]
}
