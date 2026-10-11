// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import io
import json2
import os

// --- pull diagnostics: what the published set answers without a compiler ---

const pd_main_source = 'module main

fn main() {
	x := 1
	y := 2
}
'

// pd_fixed_source is the same file after the edit that fixed one of the errors
// the last check reported.
const pd_fixed_source = 'module main

fn main() {
	x := 1
	y := 2
	z := 3
}
'

// pd_project makes a folder of its own for one test, writes the file into it and
// returns the folder, the file's URI and the text it holds.
fn pd_project(tag string, text string) (string, string, string) {
	dir := os.join_path(os.temp_dir(), 'vls_pd_${os.getpid()}_${tag}')
	os.mkdir_all(dir) or {
		assert false, 'Failed to create ${dir}: ${err}'
	}
	path := os.join_path(dir, 'main.v')
	os.write_file(path, text) or {
		assert false, 'Failed to write ${path}: ${err}'
	}
	return dir, path_to_uri(path), text
}

// pd_cleanup removes the folder of one test.
fn pd_cleanup(dir string) {
	os.rmdir_all(dir) or {}
}

// pd_seed records the errors of the last check of `uri`: what the push
// published, and what a pull must answer from.
fn pd_seed(mut app App, uri string, errors []JsonError) {
	app.diag_cache[uri] = DiagCacheEntry{
		fingerprint: 'pd'
		errors:      errors
	}
}

// pd_errors builds `n` errors on their own lines, as a compiler cascade reports.
fn pd_errors(n int) []JsonError {
	mut errors := []JsonError{}
	for i in 1 .. n + 1 {
		errors << JsonError{
			message: 'error ${i}'
			line_nr: i
			col:     1
			len:     1
			level:   'error'
		}
	}
	return errors
}

// pd_pull asks for the diagnostics of `uri`, echoing `previous_result_id` when
// the caller holds one.
fn pd_pull(mut app App, uri string, previous_result_id string) Response {
	mut previous := ?string(none)
	if previous_result_id != '' {
		previous = previous_result_id
	}
	return app.handle_pull_diagnostic(Request{
		id:     1
		method: 'textDocument/diagnostic'
		params: json2.encode(DocumentDiagnosticParams{
			text_document:      TextDocumentIdentifier{
				uri: uri
			}
			previous_result_id: previous
		})
	})
}

// pd_report decodes the full report of a pull response.
fn pd_report(response Response) FullDocumentDiagnosticReport {
	return response.result as DocumentDiagnosticReport as FullDocumentDiagnosticReport
}

// pd_unchanged decodes the unchanged report of a pull response.
fn pd_unchanged(response Response) UnchangedDocumentDiagnosticReport {
	return response.result as DocumentDiagnosticReport as UnchangedDocumentDiagnosticReport
}

// pd_published is the item list the push carries, for the same errors.
fn pd_published(mut app App, uri string, text string, errors []JsonError) []LSPDiagnostic {
	return app.diagnostics_notification_for(uri, text, errors).params.diagnostics
}

// A pull answers the items the push published, byte for byte, and no compiler
// runs to answer it: the messages here are ones no compiler could have emitted.
fn test_pull_diagnostic_returns_the_items_the_push_published() {
	dir, uri, text := pd_project('pd_push_match', pd_main_source)
	defer {
		pd_cleanup(dir)
	}
	mut app := App{}
	app.open_files[uri] = text
	errors := pd_errors(3)
	pd_seed(mut app, uri, errors)
	pushed := pd_published(mut app, uri, text, errors)

	report := pd_report(pd_pull(mut app, uri, ''))

	assert report.kind == 'full'
	assert report.items.len == pushed.len
	assert json2.encode(report.items) == json2.encode(pushed)
	assert report.items[0].message == 'error 1'
	assert report.items[2].message == 'error 3'
	assert report.items[0].severity == 1
	assert (report.items[0].source or { '' }) == 'vlang'
	assert (report.result_id or { '' }).len > 0
}

// The id a pull issues is stable while nothing changed: asking again with it
// answers unchanged and sends no items back.
fn test_pull_diagnostic_with_the_matching_result_id_is_unchanged() {
	dir, uri, _ := pd_project('pd_unchanged', pd_main_source)
	defer {
		pd_cleanup(dir)
	}
	mut app := App{}
	app.open_files[uri] = pd_main_source
	pd_seed(mut app, uri, pd_errors(3))
	first := pd_report(pd_pull(mut app, uri, ''))
	result_id := first.result_id or {
		assert false, 'a full report always names its result'
		return
	}

	unchanged := pd_unchanged(pd_pull(mut app, uri, result_id))

	assert unchanged.kind == 'unchanged'
	assert unchanged.result_id == result_id
	encoded := encode_response_payload(pd_pull(mut app, uri, result_id))
	assert encoded.contains('"kind":"unchanged"')
	assert !encoded.contains('"items"')
}

// An edit that the next check answers for moves both the items and the id, so a
// client holding the old id is re-sent the list instead of being told unchanged.
fn test_pull_diagnostic_after_an_edit_returns_new_items_with_a_new_result_id() {
	dir, uri, _ := pd_project('pd_after_edit', pd_main_source)
	defer {
		pd_cleanup(dir)
	}
	mut app := App{}
	app.open_files[uri] = pd_main_source
	pd_seed(mut app, uri, pd_errors(3))
	first := pd_report(pd_pull(mut app, uri, ''))
	first_id := first.result_id or {
		assert false, 'a full report always names its result'
		return
	}

	app.open_files[uri] = pd_fixed_source
	pd_seed(mut app, uri, pd_errors(2))
	second := pd_report(pd_pull(mut app, uri, ''))
	second_id := second.result_id or {
		assert false, 'a full report always names its result'
		return
	}

	assert second_id != first_id, 'a re-check must name a different result'
	assert second.items.len == 2
	after_edit_with_the_old_id := pd_report(pd_pull(mut app, uri, first_id))
	assert after_edit_with_the_old_id.items.len == 2
	unchanged := pd_unchanged(pd_pull(mut app, uri, second_id))
	assert unchanged.result_id == second_id
}

// The cap is the push's own helper, and a pull goes through the same function,
// so a cascading file is capped once — the same constant, the same marker — and
// the id that names the capped list is the id that answers unchanged.
fn test_pull_diagnostic_applies_the_cap_helper_of_the_push() {
	dir, uri, text := pd_project('pd_cap', 'x\n'.repeat(150))
	defer {
		pd_cleanup(dir)
	}
	mut app := App{}
	app.open_files[uri] = text
	errors := pd_errors(150)
	pd_seed(mut app, uri, errors)
	pushed := pd_published(mut app, uri, text, errors)

	report := pd_report(pd_pull(mut app, uri, ''))

	assert report.items.len == pushed.len
	assert report.items.len == max_published_diagnostics + 1
	assert report.items[99].message == 'error 100'
	assert report.items[100].message == '... and 50 more'
	assert report.items[100].severity == 3
	assert json2.encode(report.items) == json2.encode(pushed)
	result_id := report.result_id or {
		assert false, 'a full report always names its result'
		return
	}
	capped_unchanged := pd_unchanged(pd_pull(mut app, uri, result_id))
	assert capped_unchanged.kind == 'unchanged'
}

// A document no check has answered for answers an empty list with a result id,
// never an error.
fn test_pull_diagnostic_of_a_document_never_checked_answers_empty() {
	dir, uri, text := pd_project('pd_never_checked', pd_main_source)
	defer {
		pd_cleanup(dir)
	}
	mut app := App{}
	app.open_files[uri] = text

	response := pd_pull(mut app, uri, '')
	report := pd_report(response)

	assert response.id == 1
	assert report.kind == 'full'
	assert report.items.len == 0
	result_id := report.result_id or {
		assert false, 'a full report always names its result'
		return
	}
	empty_unchanged := pd_unchanged(pd_pull(mut app, uri, result_id))
	assert empty_unchanged.kind == 'unchanged'
	assert empty_unchanged.result_id == result_id
}

// initialize advertises the pull capability in the response the real handshake
// writes, with both of its flags false.
fn test_pull_diagnostic_capability_is_advertised_in_initialize() {
	dir, uri, _ := pd_project('pd_capabilities', pd_main_source)
	defer {
		pd_cleanup(dir)
	}
	mut app := App{}
	app.open_files[uri] = pd_main_source
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
	input_path := os.join_path(dir, 'initialize.txt')
	os.write_file(input_path, 'Content-Length: ${payload.len}\r\n\r\n${payload}') or {
		assert false, 'Failed to write ${input_path}: ${err}'
	}
	mut input := os.open(input_path) or {
		assert false, 'Failed to open ${input_path}: ${err}'
		return
	}
	defer {
		input.close()
	}
	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)
	initialize := app.captured_output.join('')

	assert initialize.contains('"diagnosticProvider"'), 'pull diagnostics is advertised'
	assert initialize.contains('"interFileDependencies":false')
	assert initialize.contains('"workspaceDiagnostics":false')
}
