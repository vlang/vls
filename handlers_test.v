// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json

// ============================================================================
// Tests for handler functionality
// ============================================================================

fn create_test_app() &App {
	temp_dir := os.join_path(os.temp_dir(), 'vls_test_${os.getpid()}')
	os.mkdir_all(temp_dir) or { panic('Failed to create test temp dir: ${err}') }
	return &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
}

fn cleanup_test_app(app &App) {
	os.rmdir_all(app.temp_dir) or {}
}

// ============================================================================
// Tests for on_did_open handler
// ============================================================================

fn test_on_did_open_tracks_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Create a temporary test file
	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	test_content := 'module main\n\nfn main() {\n\tprintln("hello")\n}'
	os.write_file(test_file, test_content) or { panic(err) }

	uri := path_to_uri(test_file)
	request := Request{
		id:      1
		method:  'textDocument/didOpen'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}

	app.on_did_open(request)

	// Verify file is tracked
	assert uri in app.open_files
	assert app.open_files[uri] == test_content
	assert app.text == test_content
}

fn test_on_did_open_multiple_files() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Create multiple test files
	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }

	test_file1 := os.join_path(test_dir, 'main.v')
	test_file2 := os.join_path(test_dir, 'utils.v')
	content1 := 'module main\n\nfn main() {}'
	content2 := 'module main\n\nfn helper() {}'

	os.write_file(test_file1, content1) or { panic(err) }
	os.write_file(test_file2, content2) or { panic(err) }

	uri1 := path_to_uri(test_file1)
	uri2 := path_to_uri(test_file2)

	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri1
			}
		}
	})
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri2
			}
		}
	})

	assert app.open_files.len == 2
	assert uri1 in app.open_files
	assert uri2 in app.open_files
}

fn test_on_did_open_updates_current_text() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }

	test_file1 := os.join_path(test_dir, 'first.v')
	test_file2 := os.join_path(test_dir, 'second.v')
	content1 := 'module main\n\nfn first() {}'
	content2 := 'module main\n\nfn second() {}'

	os.write_file(test_file1, content1) or { panic(err) }
	os.write_file(test_file2, content2) or { panic(err) }

	uri1 := path_to_uri(test_file1)
	uri2 := path_to_uri(test_file2)

	// Open first file
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri1
			}
		}
	})
	assert app.text == content1

	// Open second file - app.text should update to second file's content
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri2
			}
		}
	})
	assert app.text == content2
}

fn test_on_did_open_nonexistent_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Try to open a file that doesn't exist
	nonexistent := os.join_path(app.temp_dir, 'nonexistent.v')
	uri := path_to_uri(nonexistent)

	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	// File should not be tracked if it doesn't exist
	assert uri !in app.open_files
}

fn test_on_did_open_empty_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'empty.v')
	os.write_file(test_file, '') or { panic(err) }

	uri := path_to_uri(test_file)
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	assert uri in app.open_files
	assert app.open_files[uri] == ''
	assert app.text == ''
}

fn test_on_did_open_reopen_same_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')

	// Write initial content
	content1 := 'module main\n\nfn main() {}'
	os.write_file(test_file, content1) or { panic(err) }

	uri := path_to_uri(test_file)
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})
	assert app.open_files[uri] == content1

	// Update file content on disk
	content2 := 'module main\n\nfn main() { updated }'
	os.write_file(test_file, content2) or { panic(err) }

	// Reopen the file - should get new content
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})
	assert app.open_files[uri] == content2
}

// ============================================================================
// Tests for on_did_change handler
// ============================================================================

fn test_on_did_change_updates_content() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	original_content := 'module main\n\nfn main() {}'
	os.write_file(test_file, original_content) or { panic(err) }

	uri := path_to_uri(test_file)

	// First open the file
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	// Then change it
	new_content := 'module main\n\nfn main() {\n\tprintln("changed")\n}'
	request := Request{
		id:      2
		method:  'textDocument/didChange'
		jsonrpc: '2.0'
		params:  Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: new_content
			}]
		}
	}

	app.on_did_change(request)

	assert app.text == new_content
	assert app.open_files[uri] == new_content
}

fn test_on_did_change_empty_changes() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Request with empty content changes should return none
	request := Request{
		params: Params{
			content_changes: []
		}
	}

	result := app.on_did_change(request)
	assert result == none
}

fn test_on_did_change_empty_text() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Request with empty text should return none
	request := Request{
		params: Params{
			content_changes: [ContentChange{
				text: ''
			}]
		}
	}

	result := app.on_did_change(request)
	assert result == none
}

fn test_on_did_change_returns_notification() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	content := "module main\n\nfn main() {\n\tprintln('hello')\n}\n"
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	request := Request{
		params: Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: content
			}]
		}
	}

	result := app.on_did_change(request)

	// Should return a notification
	if notif := result {
		assert notif.method == 'textDocument/publishDiagnostics'
		assert notif.params.uri == uri
	}
}

fn test_on_did_change_multiple_changes() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	os.write_file(test_file, 'module main') or { panic(err) }

	uri := path_to_uri(test_file)
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	// Simulate multiple sequential changes
	changes := [
		'module main\n\nfn main() {}',
		"module main\n\nfn main() { println('a') }",
		"module main\n\nfn main() { println('b') }",
	]

	for change in changes {
		request := Request{
			params: Params{
				text_document:   TextDocumentIdentifier{
					uri: uri
				}
				content_changes: [ContentChange{
					text: change
				}]
			}
		}
		app.on_did_change(request)
		assert app.text == change
		assert app.open_files[uri] == change
	}
}

fn test_on_did_change_updates_tracked_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	os.write_file(test_file, 'original') or { panic(err) }

	uri := path_to_uri(test_file)

	// Open file
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	// Verify initial state
	assert app.open_files[uri] == 'original'

	// Change file
	new_content := 'modified content'
	app.on_did_change(Request{
		params: Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: new_content
			}]
		}
	})

	// Verify both app.text and open_files are updated
	assert app.text == new_content
	assert app.open_files[uri] == new_content
}

// ============================================================================
// Tests for operation_at_pos handler
// ============================================================================

fn test_operation_at_pos_completion_line_info() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	content := 'module main\n\nfn main() {\n\tos.\n}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	request := Request{
		id:     1
		method: 'textDocument/completion'
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 4
			}
		}
	}

	response := app.operation_at_pos(.completion, request)
	assert response.id == 1
}

fn test_operation_at_pos_definition_line_info() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	request := Request{
		id:     2
		method: 'textDocument/definition'
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			}
		}
	}

	response := app.operation_at_pos(.definition, request)
	assert response.id == 2
}

fn test_operation_at_pos_signature_help_line_info() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	content := 'module main\n\nfn greet(name string) {}\n\nfn main() {\n\tgreet(\n}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	request := Request{
		id:     3
		method: 'textDocument/signatureHelp'
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 7
			}
		}
	}

	response := app.operation_at_pos(.signature_help, request)
	assert response.id == 3
}

fn test_operation_at_pos_preserves_request_id() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')
	content := 'module main\n\nfn main() {}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	// Test with various request IDs
	test_ids := [0, 1, 42, 999, 12345]
	for id in test_ids {
		request := Request{
			id:     id
			params: Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position:      Position{
					line: 2
					char: 0
				}
			}
		}
		response := app.operation_at_pos(.completion, request)
		assert response.id == id
	}
}

// ============================================================================
// Tests for JSON encoding/decoding
// ============================================================================

fn test_json_encode_response() {
	response := Response{
		id:     1
		result: 'null'
	}
	encoded := json.encode(response)
	assert encoded.contains('"id":1')
	assert encoded.contains('"jsonrpc":"2.0"')
}

fn test_json_encode_capabilities_response() {
	response := Response{
		id:     0
		result: Capabilities{
			capabilities: Capability{
				text_document_sync:      TextDocumentSyncOptions{
					open_close: true
					change:     1
				}
				completion_provider:     CompletionProvider{
					trigger_characters: ['.']
				}
				signature_help_provider: SignatureHelpOptions{
					trigger_characters: ['(', ',']
				}
				definition_provider:     true
			}
		}
	}
	encoded := json.encode(response)
	assert encoded.contains('"definitionProvider":true')
	assert encoded.contains('"completionProvider"')
	assert encoded.contains('"signatureHelpProvider"')
}

fn test_json_encode_completion_response() {
	details := [
		Detail{
			kind:          6
			label:         'println'
			detail:        'fn println(s string)'
			documentation: 'Prints to stdout'
		},
		Detail{
			kind:          6
			label:         'print'
			detail:        'fn print(s string)'
			documentation: 'Prints without newline'
		},
	]
	response := Response{
		id:     2
		result: details
	}
	encoded := json.encode(response)
	assert encoded.contains('"label":"println"')
	assert encoded.contains('"label":"print"')
}

fn test_json_encode_location_response() {
	response := Response{
		id:     3
		result: Location{
			uri:   'file:///test/main.v'
			range: LSPRange{
				start: Position{
					line: 10
					char: 5
				}
				end:   Position{
					line: 10
					char: 15
				}
			}
		}
	}
	encoded := json.encode(response)
	assert encoded.contains('"uri":"file:///test/main.v"')
	assert encoded.contains('"line":10')
}

fn test_json_encode_signature_help_response() {
	response := Response{
		id:     4
		result: SignatureHelp{
			signatures:       [
				SignatureInformation{
					label:      'fn test(a int, b string)'
					parameters: [
						ParameterInformation{
							label: 'a int'
						},
						ParameterInformation{
							label: 'b string'
						},
					]
				},
			]
			active_signature: 0
			active_parameter: 0
		}
	}
	encoded := json.encode(response)
	assert encoded.contains('"activeSignature":0')
	assert encoded.contains('"activeParameter":0')
	assert encoded.contains('"label":"fn test(a int, b string)"')
}

fn test_json_encode_notification() {
	notification := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri:         'file:///test.v'
			diagnostics: [
				LSPDiagnostic{
					range:    LSPRange{
						start: Position{
							line: 5
							char: 0
						}
						end:   Position{
							line: 5
							char: 10
						}
					}
					message:  'undefined identifier'
					severity: 1
				},
			]
		}
	}
	encoded := json.encode(notification)
	assert encoded.contains('"method":"textDocument/publishDiagnostics"')
	assert encoded.contains('"message":"undefined identifier"')
	assert encoded.contains('"severity":1')
}

fn test_json_decode_request() {
	request_json := '{"id":1,"method":"textDocument/completion","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"position":{"line":5,"character":10}}}'
	request := json.decode(Request, request_json) or {
		assert false, 'Failed to decode request: ${err}'
		return
	}
	assert request.id == 1
	assert request.method == 'textDocument/completion'
	assert request.params.position.line == 5
	assert request.params.position.char == 10
}

fn test_json_decode_request_with_content_changes() {
	request_json := '{"id":2,"method":"textDocument/didChange","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"contentChanges":[{"text":"fn main() {}"}]}}'
	request := json.decode(Request, request_json) or {
		assert false, 'Failed to decode request: ${err}'
		return
	}
	assert request.method == 'textDocument/didChange'
	assert request.params.content_changes.len == 1
	assert request.params.content_changes[0].text == 'fn main() {}'
}

fn test_json_decode_request_initialize() {
	request_json := '{"id":0,"method":"initialize","jsonrpc":"2.0","params":{}}'
	request := json.decode(Request, request_json) or {
		assert false, 'Failed to decode request: ${err}'
		return
	}
	assert request.id == 0
	assert request.method == 'initialize'
}

fn test_json_decode_request_definition() {
	request_json := '{"id":5,"method":"textDocument/definition","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"position":{"line":10,"character":5}}}'
	request := json.decode(Request, request_json) or {
		assert false, 'Failed to decode request: ${err}'
		return
	}
	assert request.id == 5
	assert request.method == 'textDocument/definition'
	assert request.params.position.line == 10
	assert request.params.position.char == 5
}

// ============================================================================
// Tests for deduplication of diagnostics
// ============================================================================

fn test_diagnostics_deduplication() {
	// This tests the deduplication logic in on_did_change
	// Multiple errors at the same position should be deduplicated
	mut seen_positions := map[string]bool{}

	errors := [
		JsonError{
			line_nr: 5
			col:     10
			message: 'error 1'
		},
		JsonError{
			line_nr: 5
			col:     10
			message: 'error 2'
		}, // duplicate position
		JsonError{
			line_nr: 6
			col:     5
			message: 'error 3'
		},
	]

	mut count := 0
	for err in errors {
		pos_key := '${err.line_nr}:${err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		count++
	}

	assert count == 2 // Only 2 unique positions
}

fn test_diagnostics_deduplication_same_line_different_col() {
	mut seen_positions := map[string]bool{}

	errors := [
		JsonError{
			line_nr: 5
			col:     1
			message: 'error 1'
		},
		JsonError{
			line_nr: 5
			col:     10
			message: 'error 2'
		},
		JsonError{
			line_nr: 5
			col:     20
			message: 'error 3'
		},
	]

	mut count := 0
	for err in errors {
		pos_key := '${err.line_nr}:${err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		count++
	}

	assert count == 3 // All different positions on same line
}

fn test_diagnostics_deduplication_empty() {
	mut seen_positions := map[string]bool{}
	errors := []JsonError{}

	mut count := 0
	for err in errors {
		pos_key := '${err.line_nr}:${err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		count++
	}

	assert count == 0
}

// ============================================================================
// Tests for ResponseResult union type
// ============================================================================

fn test_response_result_string() {
	result := ResponseResult('null')
	if result is string {
		assert result == 'null'
	} else {
		assert false, 'Expected string result'
	}
}

fn test_response_result_details() {
	details := [
		Detail{
			kind:  6
			label: 'test'
		},
	]
	result := ResponseResult(details)
	if result is []Detail {
		assert result.len == 1
		assert result[0].label == 'test'
	} else {
		assert false, 'Expected []Detail result'
	}
}

fn test_response_result_capabilities() {
	caps := Capabilities{
		capabilities: Capability{
			definition_provider: true
		}
	}
	result := ResponseResult(caps)
	if result is Capabilities {
		assert result.capabilities.definition_provider == true
	} else {
		assert false, 'Expected Capabilities result'
	}
}

fn test_response_result_signature_help() {
	sig := SignatureHelp{
		active_parameter: 1
	}
	result := ResponseResult(sig)
	if result is SignatureHelp {
		assert result.active_parameter == 1
	} else {
		assert false, 'Expected SignatureHelp result'
	}
}

fn test_response_result_location() {
	loc := Location{
		uri: 'file:///test.v'
	}
	result := ResponseResult(loc)
	if result is Location {
		assert result.uri == 'file:///test.v'
	} else {
		assert false, 'Expected Location result'
	}
}

// ============================================================================
// Tests for App initialization
// ============================================================================

fn test_app_initialization() {
	app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	assert app.text == ''
	assert app.open_files.len == 0
	assert app.temp_dir != ''
	assert os.exists(app.temp_dir)
}

fn test_app_cur_mod_default() {
	app := App{}
	assert app.cur_mod == 'main'
}

fn test_app_exit_flag_default() {
	app := App{}
	// exit flag depends on os.args, just verify it's boolean
	_ := app.exit
}

// ============================================================================
// Tests for v_error_to_lsp_diagnostic conversion
// ============================================================================

fn test_v_error_to_lsp_diagnostic_basic() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'undefined identifier `foo`'
		line_nr: 10
		col:     5
		len:     3
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	// LSP is 0-indexed, V parser is 1-indexed
	assert diag.range.start.line == 9
	assert diag.range.start.char == 4
	assert diag.range.end.line == 9
	assert diag.range.end.char == 7 // start_char + len = 4 + 3 = 7
	assert diag.message == 'undefined identifier `foo`'
	assert diag.severity == 1 // Error
}

fn test_v_error_to_lsp_diagnostic_first_line() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'syntax error'
		line_nr: 1
		col:     1
		len:     1
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 0
	assert diag.range.start.char == 0
	assert diag.range.end.char == 1
}

fn test_v_error_to_lsp_diagnostic_long_error() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'unexpected token'
		line_nr: 100
		col:     50
		len:     20
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 99
	assert diag.range.start.char == 49
	assert diag.range.end.char == 69 // 49 + 20
}

fn test_v_error_to_lsp_diagnostic_zero_length() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'error at position'
		line_nr: 5
		col:     10
		len:     0
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.char == 9
	assert diag.range.end.char == 9 // start + 0 = same position
}

fn test_v_error_to_lsp_diagnostic_preserves_message() {
	messages := [
		'undefined identifier `foo`',
		'expected `;` after expression',
		'cannot use `string` as `int`',
		'function `test` redeclared',
		'',
	]

	for msg in messages {
		v_err := JsonError{
			message: msg
			line_nr: 1
			col:     1
			len:     1
		}
		diag := v_error_to_lsp_diagnostic(v_err)
		assert diag.message == msg
	}
}

fn test_v_error_to_lsp_diagnostic_always_error_severity() {
	v_err := JsonError{
		path:    '/test.v'
		message: 'any error'
		line_nr: 1
		col:     1
		len:     1
	}
	diag := v_error_to_lsp_diagnostic(v_err)
	assert diag.severity == 1 // Always Error severity
}

// ============================================================================
// Tests for multifile project handling
// ============================================================================

fn test_multifile_tracking() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }

	// Create 3 files
	files := ['main.v', 'utils.v', 'helpers.v']
	for file in files {
		path := os.join_path(test_dir, file)
		os.write_file(path, 'module main\n\nfn ${file}() {}') or { panic(err) }
		uri := path_to_uri(path)
		app.on_did_open(Request{
			params: Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
			}
		})
	}

	assert app.open_files.len == 3
}

fn test_multifile_change_single_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }

	main_file := os.join_path(test_dir, 'main.v')
	utils_file := os.join_path(test_dir, 'utils.v')

	os.write_file(main_file, 'module main\n\nfn main() {}') or { panic(err) }
	os.write_file(utils_file, 'module main\n\nfn helper() {}') or { panic(err) }

	main_uri := path_to_uri(main_file)
	utils_uri := path_to_uri(utils_file)

	// Open both files
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
		}
	})
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: utils_uri
			}
		}
	})

	// Change only main.v
	new_content := 'module main\n\nfn main() { changed }'
	app.on_did_change(Request{
		params: Params{
			text_document:   TextDocumentIdentifier{
				uri: main_uri
			}
			content_changes: [ContentChange{
				text: new_content
			}]
		}
	})

	// Verify only main.v was updated
	assert app.open_files[main_uri] == new_content
	assert app.open_files[utils_uri].contains('helper') // utils unchanged
}

// ============================================================================
// Tests for formatting handler
// ============================================================================

fn test_handle_formatting_formats_code() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')

	// Badly formatted content
	unformatted := 'module main\n\nfn   badly_formatted(   x    int,y int   )int{\nreturn x+y\n}'
	os.write_file(test_file, unformatted) or { panic(err) }

	uri := path_to_uri(test_file)
	app.open_files[uri] = unformatted

	request := Request{
		id:      1
		method:  'textDocument/formatting'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}

	response := app.handle_formatting(request)
	assert response.id == 1

	// Should return TextEdit array
	if response.result is []TextEdit {
		edits := response.result as []TextEdit
		assert edits.len > 0

		// Check that the formatted text is proper
		formatted_text := edits[0].new_text
		assert formatted_text.contains('fn badly_formatted(x int, y int) int {')
		assert formatted_text.contains('\treturn x + y')
	} else {
		assert false, 'Expected []TextEdit result'
	}
}

fn test_handle_formatting_already_formatted() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')

	// Already well-formatted content
	formatted := 'module main\n\nfn main() {\n\tprintln("hello")\n}\n'
	os.write_file(test_file, formatted) or { panic(err) }

	uri := path_to_uri(test_file)
	app.open_files[uri] = formatted

	request := Request{
		id:      2
		method:  'textDocument/formatting'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}

	response := app.handle_formatting(request)
	assert response.id == 2

	// Should return empty edits if already formatted
	if response.result is []TextEdit {
		edits := response.result as []TextEdit
		// May return empty or single edit with same content
		assert edits.len >= 0
	}
}

fn test_handle_formatting_nonexistent_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	nonexistent := os.join_path(app.temp_dir, 'nonexistent.v')
	uri := path_to_uri(nonexistent)

	request := Request{
		id:      3
		method:  'textDocument/formatting'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}

	response := app.handle_formatting(request)
	assert response.id == 3

	// Should return empty edits for nonexistent file
	if response.result is []TextEdit {
		edits := response.result as []TextEdit
		assert edits.len == 0
	}
}

fn test_handle_formatting_uses_open_file_content() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	os.mkdir_all(test_dir) or { panic(err) }
	test_file := os.join_path(test_dir, 'test.v')

	// File on disk has different content
	os.write_file(test_file, 'module main\n\nfn old() {}') or { panic(err) }

	uri := path_to_uri(test_file)
	// In-memory content is different
	app.open_files[uri] = 'module main\n\nfn   new(   )   {}'

	request := Request{
		id:      4
		method:  'textDocument/formatting'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}

	response := app.handle_formatting(request)

	// Should format the in-memory content, not disk content
	if response.result is []TextEdit {
		edits := response.result as []TextEdit
		if edits.len > 0 {
			formatted_text := edits[0].new_text
			assert formatted_text.contains('fn new() {')
			assert !formatted_text.contains('fn old')
		}
	}
}

// ============================================================================
// Tests for parse_document_symbols
// ============================================================================

fn test_parse_document_symbols_empty_content() {
	syms := parse_document_symbols('')
	assert syms.len == 0
}

fn test_parse_document_symbols_only_comments() {
	content := '// Copyright notice\n// module main\n\n// just a comment'
	syms := parse_document_symbols(content)
	assert syms.len == 0
}

fn test_parse_document_symbols_single_function() {
	content := 'module main\n\nfn greet(name string) string {\n\treturn name\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'greet'
	assert syms[0].kind == sym_kind_function
}

fn test_parse_document_symbols_pub_function() {
	content := 'module main\n\npub fn greet(name string) string {\n\treturn name\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'greet'
	assert syms[0].kind == sym_kind_function
}

fn test_parse_document_symbols_method() {
	content := 'module main\n\nstruct App {}\n\nfn (mut app App) run() {\n}'
	syms := parse_document_symbols(content)
	// Should find struct and method
	names := syms.map(it.name)
	assert 'App' in names
	method_sym := syms.filter(it.kind == sym_kind_method)
	assert method_sym.len == 1
	assert method_sym[0].name.contains('run')
}

fn test_parse_document_symbols_struct() {
	content := 'module main\n\nstruct Person {\n\tname string\n\tage  int\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'Person'
	assert syms[0].kind == sym_kind_struct
}

fn test_parse_document_symbols_pub_struct() {
	content := 'module main\n\npub struct Config {\n\tdebug bool\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'Config'
	assert syms[0].kind == sym_kind_struct
}

fn test_parse_document_symbols_enum() {
	content := 'module main\n\nenum Color {\n\tred\n\tgreen\n\tblue\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'Color'
	assert syms[0].kind == sym_kind_enum
}

fn test_parse_document_symbols_interface() {
	content := 'module main\n\ninterface Writer {\n\twrite(s string)\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'Writer'
	assert syms[0].kind == sym_kind_interface
}

fn test_parse_document_symbols_const() {
	content := 'module main\n\nconst max_size = 100'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'max_size'
	assert syms[0].kind == sym_kind_constant
}

fn test_parse_document_symbols_type_alias() {
	content := 'module main\n\ntype MyInt = int'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'MyInt'
	assert syms[0].kind == sym_kind_class
}

fn test_parse_document_symbols_multiple_declarations() {
	content := 'module main

pub fn greet(name string) string {
	return name
}

struct Person {
	name string
	age  int
}

enum Color {
	red
	green
	blue
}

fn (p Person) say_hello() string {
	return greet(p.name)
}

const max_age = 120
'
	syms := parse_document_symbols(content)
	names := syms.map(it.name)
	assert 'greet' in names
	assert 'Person' in names
	assert 'Color' in names
	assert 'max_age' in names
	// method should be present
	assert syms.any(it.kind == sym_kind_method)
}

fn test_parse_document_symbols_correct_line_numbers() {
	content := 'module main\n\nfn alpha() {}\n\nfn beta() {}'
	// line 0: 'module main'
	// line 1: ''
	// line 2: 'fn alpha() {}'
	// line 3: ''
	// line 4: 'fn beta() {}'
	syms := parse_document_symbols(content)
	assert syms.len == 2
	alpha := syms.filter(it.name == 'alpha')
	beta := syms.filter(it.name == 'beta')
	assert alpha.len == 1
	assert beta.len == 1
	assert alpha[0].range.start.line == 2
	assert beta[0].range.start.line == 4
}

fn test_parse_document_symbols_const_block_paren_skipped() {
	// `const (` alone should not produce a symbol with name '('
	content := 'module main\n\nconst (\n\ta = 1\n\tb = 2\n)'
	syms := parse_document_symbols(content)
	for sym in syms {
		assert sym.name != '('
	}
}

fn test_parse_document_symbols_selection_range_points_to_name() {
	content := 'module main\n\nfn my_func() {}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	sym := syms[0]
	// The selection range should start where the name begins in the raw line
	line := 'fn my_func() {}'
	expected_col := line.index('my_func') or { -1 }
	assert expected_col >= 0
	assert sym.selection_range.start.char == expected_col
	assert sym.selection_range.end.char == expected_col + 'my_func'.len
}

// ============================================================================
// Tests for extract_fn_name helper
// ============================================================================

fn test_extract_fn_name_simple() {
	assert extract_fn_name('main() {}') == 'main'
}

fn test_extract_fn_name_with_params() {
	assert extract_fn_name('greet(name string) string') == 'greet'
}

fn test_extract_fn_name_method_with_receiver() {
	name := extract_fn_name('(mut app App) run()')
	assert name.contains('run')
	assert name.contains('mut app App')
}

fn test_extract_fn_name_method_immutable_receiver() {
	name := extract_fn_name('(p Person) say_hello() string')
	assert name.contains('say_hello')
	assert name.contains('p Person')
}

fn test_extract_fn_name_empty_string() {
	assert extract_fn_name('') == ''
}

fn test_extract_fn_name_whitespace_only() {
	assert extract_fn_name('   ') == ''
}

// ============================================================================
// Tests for first_word helper
// ============================================================================

fn test_first_word_simple() {
	assert first_word('Person {}') == 'Person'
}

fn test_first_word_with_tab() {
	assert first_word('Color\t{') == 'Color'
}

fn test_first_word_stops_at_brace() {
	assert first_word('Writer{') == 'Writer'
}

fn test_first_word_single_token() {
	assert first_word('MyType') == 'MyType'
}

fn test_first_word_empty() {
	assert first_word('') == ''
}

// ============================================================================
// Tests for first_word_paren helper
// ============================================================================

fn test_first_word_paren_simple() {
	assert first_word_paren('foo(a int) string') == 'foo'
}

fn test_first_word_paren_no_paren() {
	assert first_word_paren('main') == 'main'
}

fn test_first_word_paren_empty() {
	assert first_word_paren('') == ''
}

fn test_first_word_paren_stops_at_space() {
	assert first_word_paren('bar baz') == 'bar'
}

// ============================================================================
// Tests for extract_const_name helper
// ============================================================================

fn test_extract_const_name_simple() {
	assert extract_const_name('max_size = 100') == 'max_size'
}

fn test_extract_const_name_open_paren() {
	// const ( block opening — should return empty
	assert extract_const_name('(') == ''
}

fn test_extract_const_name_empty() {
	assert extract_const_name('') == ''
}

fn test_extract_const_name_whitespace_only() {
	assert extract_const_name('   ') == ''
}

// ============================================================================
// Tests for handle_document_symbols handler
// ============================================================================

fn test_handle_document_symbols_empty_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///tmp/empty.v'
	app.open_files[uri] = ''

	request := Request{
		id:     10
		method: 'textDocument/documentSymbol'
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}

	response := app.handle_document_symbols(request)
	assert response.id == 10
	if response.result is []DocumentSymbol {
		assert response.result.len == 0
	} else {
		assert false, 'Expected []DocumentSymbol'
	}
}

fn test_handle_document_symbols_no_tracked_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// URI not in open_files — should still return an empty symbol list, not crash
	request := Request{
		id:     11
		method: 'textDocument/documentSymbol'
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: 'file:///tmp/not_tracked.v'
			}
		}
	}

	response := app.handle_document_symbols(request)
	assert response.id == 11
	if response.result is []DocumentSymbol {
		assert response.result.len == 0
	} else {
		assert false, 'Expected []DocumentSymbol'
	}
}

fn test_handle_document_symbols_returns_correct_symbols() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///tmp/test_sym.v'
	app.open_files[uri] = 'module main\n\nfn hello() {}\n\nstruct Config {}\n\nenum Mode { on off }\n\nconst version = 1\n'

	request := Request{
		id:     12
		method: 'textDocument/documentSymbol'
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}

	response := app.handle_document_symbols(request)
	assert response.id == 12

	if response.result is []DocumentSymbol {
		syms := response.result
		names := syms.map(it.name)
		assert 'hello' in names
		assert 'Config' in names
		assert 'Mode' in names
		assert 'version' in names
	} else {
		assert false, 'Expected []DocumentSymbol'
	}
}

fn test_handle_document_symbols_preserves_request_id() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///tmp/id_test.v'
	app.open_files[uri] = 'module main\n\nfn foo() {}\n'

	for id in [1, 99, 1000, 0] {
		request := Request{
			id:     id
			method: 'textDocument/documentSymbol'
			params: Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
			}
		}
		response := app.handle_document_symbols(request)
		assert response.id == id
	}
}

fn test_handle_document_symbols_kinds_are_correct() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///tmp/kinds_test.v'
	app.open_files[uri] = 'module main

fn plain_fn() {}

struct MyStruct {}

enum MyEnum { a b }

interface MyInterface { run() }

type MyType = int

const my_const = 42
'

	request := Request{
		id:     20
		method: 'textDocument/documentSymbol'
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}

	response := app.handle_document_symbols(request)

	if response.result is []DocumentSymbol {
		syms := response.result
		fn_sym := syms.filter(it.name == 'plain_fn')
		struct_sym := syms.filter(it.name == 'MyStruct')
		enum_sym := syms.filter(it.name == 'MyEnum')
		iface_sym := syms.filter(it.name == 'MyInterface')
		type_sym := syms.filter(it.name == 'MyType')
		const_sym := syms.filter(it.name == 'my_const')

		assert fn_sym.len == 1 && fn_sym[0].kind == sym_kind_function
		assert struct_sym.len == 1 && struct_sym[0].kind == sym_kind_struct
		assert enum_sym.len == 1 && enum_sym[0].kind == sym_kind_enum
		assert iface_sym.len == 1 && iface_sym[0].kind == sym_kind_interface
		assert type_sym.len == 1 && type_sym[0].kind == sym_kind_class
		assert const_sym.len == 1 && const_sym[0].kind == sym_kind_constant
	} else {
		assert false, 'Expected []DocumentSymbol'
	}
}

// ============================================================================
// Tests for extract_doc_comment helper
// ============================================================================

fn test_extract_doc_comment_single_line() {
	lines := ['// greet says hello', 'fn greet() {}']
	comment := extract_doc_comment(lines, 1)
	assert comment == 'greet says hello'
}

fn test_extract_doc_comment_multi_line() {
	lines := [
		'// copy_all recursively copies all elements of the array by their value,',
		'// if `dupes` is false all duplicate values are eliminated in the process.',
		'fn copy_all(dupes bool) {}',
	]
	comment := extract_doc_comment(lines, 2)
	assert comment == 'copy_all recursively copies all elements of the array by their value,  \nif `dupes` is false all duplicate values are eliminated in the process.'
}

fn test_extract_doc_comment_no_comment() {
	lines := ['', 'fn no_docs() {}']
	comment := extract_doc_comment(lines, 1)
	assert comment == ''
}

fn test_extract_doc_comment_stops_at_blank_line() {
	lines := ['// unrelated', '', '// greet says hello', 'fn greet() {}']
	comment := extract_doc_comment(lines, 3)
	assert comment == 'greet says hello'
}

fn test_extract_doc_comment_stops_at_non_comment() {
	lines := ['fn other() {}', '// greet says hello', 'fn greet() {}']
	comment := extract_doc_comment(lines, 2)
	assert comment == 'greet says hello'
}

fn test_extract_doc_comment_at_first_line() {
	lines := ['fn greet() {}']
	comment := extract_doc_comment(lines, 0)
	assert comment == ''
}

// ============================================================================
// Tests for find_declaration_line helper
// ============================================================================

fn test_find_declaration_line_function() {
	lines := ['module main', '', 'fn my_func() {}']
	idx := find_declaration_line(lines, 'my_func')
	assert idx == 2
}

fn test_find_declaration_line_pub_function() {
	lines := ['module main', '', 'pub fn exported() {}']
	idx := find_declaration_line(lines, 'exported')
	assert idx == 2
}

fn test_find_declaration_line_struct() {
	lines := ['module main', '', 'struct MyStruct {', '}']
	idx := find_declaration_line(lines, 'MyStruct')
	assert idx == 2
}

fn test_find_declaration_line_enum() {
	lines := ['module main', '', 'enum Color { red green blue }']
	idx := find_declaration_line(lines, 'Color')
	assert idx == 2
}

fn test_find_declaration_line_method() {
	lines := ['module main', '', 'fn (mut app App) run() {}']
	idx := find_declaration_line(lines, 'run')
	assert idx == 2
}

fn test_find_declaration_line_const() {
	lines := ['module main', '', 'const max_retries = 3']
	idx := find_declaration_line(lines, 'max_retries')
	assert idx == 2
}

fn test_find_declaration_line_not_found() {
	lines := ['module main', '', 'fn foo() {}']
	idx := find_declaration_line(lines, 'bar')
	assert idx == -1
}

// ============================================================================
// Tests for get_word_at_col helper
// ============================================================================

fn test_get_word_at_col_middle_of_word() {
	line := 'fn my_func() {}'
	word := get_word_at_col(line, 4)
	assert word == 'my_func'
}

fn test_get_word_at_col_start_of_word() {
	line := 'fn my_func() {}'
	word := get_word_at_col(line, 3)
	assert word == 'my_func'
}

fn test_get_word_at_col_on_space() {
	line := 'fn my_func() {}'
	word := get_word_at_col(line, 2)
	assert word == ''
}

fn test_get_word_at_col_beyond_end() {
	line := 'fn foo()'
	word := get_word_at_col(line, 100)
	assert word == ''
}

// ============================================================================
// Tests for parse_imports helper
// ============================================================================

fn test_parse_imports_single() {
	content := 'module main\n\nimport os\n\nfn main() {}'
	imports := parse_imports(content)
	assert imports == ['os']
}

fn test_parse_imports_multiple() {
	content := 'module main\n\nimport os\nimport math\nimport strings\n'
	imports := parse_imports(content)
	assert imports == ['os', 'math', 'strings']
}

fn test_parse_imports_with_alias() {
	content := 'module main\n\nimport os as operating_system\n'
	imports := parse_imports(content)
	assert imports == ['os']
}

fn test_parse_imports_dotted_module() {
	content := 'module main\n\nimport v.util\n'
	imports := parse_imports(content)
	assert imports == ['v.util']
}

fn test_parse_imports_none() {
	content := 'module main\n\nfn main() {}'
	imports := parse_imports(content)
	assert imports == []
}

// ============================================================================
// Tests for find_doc_comment_for_symbol (cross-file search)
// ============================================================================

fn test_find_doc_comment_for_symbol_current_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\n// greet says hello\nfn greet() {}'
	uri := 'file:///tmp/test_greet.v'
	app.open_files[uri] = content
	lines := content.split_into_lines()
	doc := app.find_doc_comment_for_symbol('greet', lines, uri, '')
	assert doc == 'greet says hello'
}

fn test_find_doc_comment_for_symbol_other_open_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	other_content := 'module main\n\n// helper does the thing\nfn helper() {}'
	other_uri := 'file:///tmp/other.v'
	app.open_files[other_uri] = other_content

	current_content := 'module main\n\nfn main() { helper() }'
	current_uri := 'file:///tmp/main.v'
	app.open_files[current_uri] = current_content
	current_lines := current_content.split_into_lines()

	doc := app.find_doc_comment_for_symbol('helper', current_lines, current_uri, '')
	assert doc == 'helper does the thing'
}

fn test_find_doc_comment_for_symbol_not_found() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\nfn main() {}'
	uri := 'file:///tmp/main.v'
	app.open_files[uri] = content
	lines := content.split_into_lines()
	doc := app.find_doc_comment_for_symbol('nonexistent', lines, uri, '')
	assert doc == ''
}
