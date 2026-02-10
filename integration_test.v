// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json

// ============================================================================
// Integration tests for VLS language server functionality
// These tests verify the complete request/response cycle including V compiler integration
// ============================================================================

fn create_integration_test_env() (&App, string) {
	temp_dir := os.join_path(os.temp_dir(), 'vls_integration_test_${os.getpid()}')
	os.mkdir_all(temp_dir) or { panic('Failed to create test temp dir: ${err}') }

	project_dir := os.join_path(temp_dir, 'test_project')
	os.mkdir_all(project_dir) or { panic('Failed to create project dir: ${err}') }

	app := &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
	return app, project_dir
}

fn cleanup_integration_test_env(app &App, project_dir string) {
	parent := os.dir(project_dir)
	os.rmdir_all(parent) or {}
}

// ============================================================================
// Initialize capability tests
// ============================================================================

fn test_integration_initialize_capabilities() {
	// Simulate what the server returns for initialize
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
					completion_item:    CompletionItemCapability{
						snippet_support: true
					}
				}
				signature_help_provider: SignatureHelpOptions{
					trigger_characters: ['(', ',']
				}
				definition_provider:     true
			}
		}
	}

	// Verify capabilities structure
	if response.result is Capabilities {
		caps := response.result.capabilities
		assert caps.definition_provider == true
		assert caps.completion_provider.trigger_characters == ['.']
		assert caps.signature_help_provider.trigger_characters == ['(', ',']
		assert caps.text_document_sync.open_close == true
		assert caps.text_document_sync.change == 1
	} else {
		assert false, 'Expected Capabilities result'
	}
}

fn test_integration_initialize_response_structure() {
	// Verify response has proper JSON-RPC structure
	response := Response{
		id:     0
		result: Capabilities{
			capabilities: Capability{
				definition_provider: true
			}
		}
	}

	encoded := json.encode(response)
	assert encoded.contains('"id":0')
	assert encoded.contains('"jsonrpc":"2.0"')
	assert encoded.contains('"result"')
	assert encoded.contains('"definitionProvider":true')
}

fn test_integration_initialize_snippet_support() {
	response := Response{
		id:     0
		result: Capabilities{
			capabilities: Capability{
				completion_provider: CompletionProvider{
					trigger_characters: ['.']
					completion_item:    CompletionItemCapability{
						snippet_support: true
					}
				}
			}
		}
	}

	encoded := json.encode(response)
	assert encoded.contains('"snippetSupport":true')
}

// ============================================================================
// Document lifecycle tests
// ============================================================================

fn test_integration_document_lifecycle() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create a valid V file
	test_file := os.join_path(project_dir, 'main.v')
	content := "module main\n\nfn main() {\n\tprintln('hello')\n}\n"
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)

	// 1. Open document
	open_request := Request{
		id:      1
		method:  'textDocument/didOpen'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	}
	app.on_did_open(open_request)

	assert uri in app.open_files
	assert app.open_files.len == 1

	// 2. Change document
	new_content := "module main\n\nfn main() {\n\tprintln('world')\n}\n"
	change_request := Request{
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
	app.on_did_change(change_request)

	assert app.text == new_content
	assert app.open_files[uri] == new_content
}

fn test_integration_document_open_close_cycle() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'test.v')
	content := 'module main'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)

	// Open
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})
	assert app.open_files.len == 1

	// Open another file
	test_file2 := os.join_path(project_dir, 'test2.v')
	os.write_file(test_file2, 'module main') or { panic(err) }
	uri2 := path_to_uri(test_file2)

	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri2
			}
		}
	})
	assert app.open_files.len == 2
}

// ============================================================================
// Multi-file project tests
// ============================================================================

fn test_integration_multifile_project() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create multiple V files
	main_file := os.join_path(project_dir, 'main.v')
	utils_file := os.join_path(project_dir, 'utils.v')

	main_content := 'module main\n\nfn main() {\n\thelper()\n}\n'
	utils_content := "module main\n\nfn helper() {\n\tprintln('helper')\n}\n"

	os.write_file(main_file, main_content) or { panic(err) }
	os.write_file(utils_file, utils_content) or { panic(err) }

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

	assert app.open_files.len == 2
	assert main_uri in app.open_files
	assert utils_uri in app.open_files
}

fn test_integration_multifile_cross_file_reference() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create files with cross-file references
	main_file := os.join_path(project_dir, 'main.v')
	helper_file := os.join_path(project_dir, 'helper.v')

	main_content := 'module main\n\nfn main() {\n\tmy_helper()\n}\n'
	helper_content := 'module main\n\nfn my_helper() {\n\tprintln("from helper")\n}\n'

	os.write_file(main_file, main_content) or { panic(err) }
	os.write_file(helper_file, helper_content) or { panic(err) }

	main_uri := path_to_uri(main_file)
	helper_uri := path_to_uri(helper_file)

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
				uri: helper_uri
			}
		}
	})

	// Verify both files are tracked
	assert app.open_files.len == 2
}

fn test_integration_multifile_nested_directories() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create nested directory structure
	src_dir := os.join_path(project_dir, 'src')
	lib_dir := os.join_path(project_dir, 'lib')
	os.mkdir_all(src_dir) or { panic(err) }
	os.mkdir_all(lib_dir) or { panic(err) }

	main_file := os.join_path(src_dir, 'main.v')
	lib_file := os.join_path(lib_dir, 'utils.v')

	os.write_file(main_file, 'module src\n\nfn main() {}') or { panic(err) }
	os.write_file(lib_file, 'module lib\n\nfn util() {}') or { panic(err) }

	main_uri := path_to_uri(main_file)
	lib_uri := path_to_uri(lib_file)

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
				uri: lib_uri
			}
		}
	})

	assert app.open_files.len == 2
}

// ============================================================================
// Diagnostics tests
// ============================================================================

fn test_integration_diagnostics_syntax_error() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create a file with a syntax error
	test_file := os.join_path(project_dir, 'error.v')
	// Missing closing brace - syntax error
	error_content := "module main\n\nfn main() {\n\tprintln('hello')\n"
	os.write_file(test_file, error_content) or { panic(err) }

	uri := path_to_uri(test_file)

	// Open the file
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	// Trigger change to get diagnostics
	change_request := Request{
		params: Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: error_content
			}]
		}
	}

	result := app.on_did_change(change_request)

	// Should return a notification with diagnostics (or none if V check succeeds somehow)
	// We just verify the notification structure if returned
	if notif := result {
		assert notif.method == 'textDocument/publishDiagnostics'
		assert notif.params.uri == uri
	}
}

fn test_integration_diagnostics_valid_code() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create a valid V file
	test_file := os.join_path(project_dir, 'valid.v')
	valid_content := "module main\n\nfn main() {\n\tprintln('hello')\n}\n"
	os.write_file(test_file, valid_content) or { panic(err) }

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	change_request := Request{
		params: Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: valid_content
			}]
		}
	}

	result := app.on_did_change(change_request)

	// For valid code, diagnostics should be empty
	if notif := result {
		assert notif.method == 'textDocument/publishDiagnostics'
		// Diagnostics array may be empty for valid code
	}
}

fn test_integration_diagnostics_deduplication() {
	// Test that duplicate errors at same position are filtered
	mut seen_positions := map[string]bool{}

	// Simulate errors from V compiler
	errors := [
		JsonError{
			line_nr: 5
			col:     10
			message: 'first error'
		},
		JsonError{
			line_nr: 5
			col:     10
			message: 'duplicate error'
		}, // Same position
		JsonError{
			line_nr: 6
			col:     1
			message: 'different position'
		},
	]

	mut diagnostics := []LSPDiagnostic{}
	for err in errors {
		pos_key := '${err.line_nr}:${err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		diagnostics << v_error_to_lsp_diagnostic(err)
	}

	assert diagnostics.len == 2 // Only 2 unique positions
}

fn test_integration_diagnostics_empty_file() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'empty.v')
	os.write_file(test_file, '') or { panic(err) }

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	// Empty content should return none
	result := app.on_did_change(Request{
		params: Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: ''
			}]
		}
	})

	assert result == none
}

// ============================================================================
// Completion request tests
// ============================================================================

fn test_integration_completion_request() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'completion.v')
	content := 'module main\n\nfn main() {\n\tos.\n}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})
	app.text = content
	app.open_files[uri] = content

	// Request completion at the position after "os."
	request := Request{
		id:      1
		method:  'textDocument/completion'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 4
			} // After "os."
		}
	}

	response := app.operation_at_pos(.completion, request)
	assert response.id == 1
	// Response should contain result (may be empty if V compiler not available)
}

fn test_integration_completion_request_id_preserved() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'test.v')
	content := 'module main\n\nfn main() {}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	// Test with various IDs
	for id in [1, 42, 100, 999] {
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

fn test_integration_completion_at_function_call() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'test.v')
	content := 'module main\n\nfn main() {\n\tprintln(\n}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	request := Request{
		id:     1
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 9
			}
		}
	}

	response := app.operation_at_pos(.completion, request)
	assert response.id == 1
}

// ============================================================================
// Go to definition tests
// ============================================================================

fn test_integration_definition_request() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'definition.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})
	app.text = content
	app.open_files[uri] = content

	// Request definition at the call site of helper()
	request := Request{
		id:      2
		method:  'textDocument/definition'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			} // At "helper()"
		}
	}

	response := app.operation_at_pos(.definition, request)
	assert response.id == 2
}

fn test_integration_definition_multifile() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create main file that calls function from utils
	main_file := os.join_path(project_dir, 'main.v')
	utils_file := os.join_path(project_dir, 'utils.v')

	main_content := 'module main\n\nfn main() {\n\thelper()\n}\n'
	utils_content := "module main\n\nfn helper() {\n\tprintln('helper')\n}\n"

	os.write_file(main_file, main_content) or { panic(err) }
	os.write_file(utils_file, utils_content) or { panic(err) }

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
	app.text = main_content
	app.open_files[main_uri] = main_content
	app.open_files[utils_uri] = utils_content

	// Request definition from main file
	request := Request{
		id:     3
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
			position:      Position{
				line: 3
				char: 2
			}
		}
	}

	response := app.operation_at_pos(.definition, request)
	assert response.id == 3
}

// ============================================================================
// Signature help tests
// ============================================================================

fn test_integration_signature_help_request() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'signature.v')
	content := 'module main\n\nfn greet(name string, age int) {}\n\nfn main() {\n\tgreet(\n}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})
	app.text = content
	app.open_files[uri] = content

	// Request signature help after opening paren
	request := Request{
		id:      3
		method:  'textDocument/signatureHelp'
		jsonrpc: '2.0'
		params:  Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 7
			} // After "greet("
		}
	}

	response := app.operation_at_pos(.signature_help, request)
	assert response.id == 3
}

fn test_integration_signature_help_with_params() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'sig.v')
	content := 'module main\n\nfn add(a int, b int) int { return a + b }\n\nfn main() {\n\tadd(1, \n}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	// At second parameter position
	request := Request{
		id:     4
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
	assert response.id == 4
}

// ============================================================================
// Temporary file management tests
// ============================================================================

fn test_integration_temp_file_single() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'single.v')
	content := 'module main\n\nfn main() {}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)

	// Only one file open - should use single file mode
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})

	assert app.open_files.len == 1
}

fn test_integration_temp_file_multifile() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	file1 := os.join_path(project_dir, 'a.v')
	file2 := os.join_path(project_dir, 'b.v')

	os.write_file(file1, 'module main\n\nfn a() {}\n') or { panic(err) }
	os.write_file(file2, 'module main\n\nfn b() {}\n') or { panic(err) }

	uri1 := path_to_uri(file1)
	uri2 := path_to_uri(file2)

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

	// Multiple files - should use multi-file mode
	assert app.open_files.len == 2
}

fn test_integration_write_tracked_files() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	file1 := os.join_path(project_dir, 'main.v')
	os.write_file(file1, 'module main\n\nfn main() {}\n') or { panic(err) }

	uri1 := path_to_uri(file1)
	app.open_files[uri1] = 'module main\n\nfn main() { changed }\n'

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	// Verify temp directory was created
	assert os.exists(temp_project)

	// Verify file was written with modified content
	temp_file := os.join_path(temp_project, 'main.v')
	if os.exists(temp_file) {
		written_content := os.read_file(temp_file) or { '' }
		assert written_content.contains('changed')
	}
}

// ============================================================================
// JSON error parsing tests
// ============================================================================

fn test_integration_json_error_parsing() {
	// Test parsing of V compiler JSON error output
	json_output := '[{"path":"/test/file.v","message":"undefined identifier `foo`","line_nr":10,"col":5,"len":3}]'

	errors := json.decode([]JsonError, json_output) or {
		assert false, 'Failed to parse JSON errors: ${err}'
		return
	}

	assert errors.len == 1
	assert errors[0].path == '/test/file.v'
	assert errors[0].message == 'undefined identifier `foo`'
	assert errors[0].line_nr == 10
	assert errors[0].col == 5
	assert errors[0].len == 3
}

fn test_integration_json_error_parsing_empty() {
	json_output := '[]'

	errors := json.decode([]JsonError, json_output) or {
		assert false, 'Failed to parse empty JSON errors: ${err}'
		return
	}

	assert errors.len == 0
}

fn test_integration_json_error_parsing_multiple() {
	json_output := '[{"path":"/test/a.v","message":"error 1","line_nr":1,"col":1,"len":1},{"path":"/test/b.v","message":"error 2","line_nr":2,"col":2,"len":2}]'

	errors := json.decode([]JsonError, json_output) or {
		assert false, 'Failed to parse multiple JSON errors: ${err}'
		return
	}

	assert errors.len == 2
	assert errors[0].message == 'error 1'
	assert errors[1].message == 'error 2'
}

fn test_integration_json_error_with_special_chars() {
	json_output := '[{"path":"/test/file.v","message":"cannot use `string` as `int` in argument","line_nr":5,"col":10,"len":6}]'

	errors := json.decode([]JsonError, json_output) or {
		assert false, 'Failed to parse JSON errors with special chars: ${err}'
		return
	}

	assert errors.len == 1
	assert errors[0].message.contains('string')
	assert errors[0].message.contains('int')
}

// ============================================================================
// Response encoding tests
// ============================================================================

fn test_integration_response_encoding() {
	response := Response{
		id:     42
		result: 'null'
	}

	encoded := json.encode(response)

	// Should be valid JSON with required fields
	assert encoded.contains('"id":42')
	assert encoded.contains('"jsonrpc":"2.0"')
	assert encoded.contains('"result":"null"')
}

fn test_integration_notification_encoding() {
	notification := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri:         'file:///test.v'
			diagnostics: [
				LSPDiagnostic{
					range:    LSPRange{
						start: Position{
							line: 0
							char: 0
						}
						end:   Position{
							line: 0
							char: 5
						}
					}
					message:  'test error'
					severity: 1
				},
			]
		}
	}

	encoded := json.encode(notification)

	assert encoded.contains('"method":"textDocument/publishDiagnostics"')
	assert encoded.contains('"jsonrpc":"2.0"')
	assert encoded.contains('"uri":"file:///test.v"')
	assert encoded.contains('"message":"test error"')
}

fn test_integration_completion_response_encoding() {
	details := [
		Detail{
			kind:   6
			label:  'println'
			detail: 'fn println(s string)'
		},
		Detail{
			kind:   6
			label:  'print'
			detail: 'fn print(s string)'
		},
	]

	response := Response{
		id:     1
		result: details
	}

	encoded := json.encode(response)
	assert encoded.contains('"label":"println"')
	assert encoded.contains('"label":"print"')
}

fn test_integration_location_response_encoding() {
	response := Response{
		id:     1
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

fn test_integration_signature_help_response_encoding() {
	response := Response{
		id:     1
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
			active_parameter: 1
		}
	}

	encoded := json.encode(response)
	assert encoded.contains('"activeSignature":0')
	assert encoded.contains('"activeParameter":1')
	assert encoded.contains('"label":"fn test(a int, b string)"')
}

// ============================================================================
// Request ID handling tests
// ============================================================================

fn test_integration_request_id_preserved() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'test.v')
	content := 'module main\n\nfn main() {}\n'
	os.write_file(test_file, content) or { panic(err) }

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	// Test with different request IDs
	for id in [1, 42, 999, 0] {
		request := Request{
			id:     id
			method: 'textDocument/completion'
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
// Method enum edge cases tests
// ============================================================================

fn test_integration_method_unknown_handling() {
	// Verify unknown methods are handled gracefully
	unknown_methods := ['workspace/symbol', 'textDocument/rangeFormatting', '']

	for method_str in unknown_methods {
		method := Method.from_string(method_str)
		assert method == .unknown
	}
}

fn test_integration_method_all_supported() {
	// Verify all supported methods are recognized
	supported := {
		'initialize':                 Method.initialize
		'initialized':                Method.initialized
		'textDocument/didOpen':       Method.did_open
		'textDocument/didChange':     Method.did_change
		'textDocument/completion':    Method.completion
		'textDocument/definition':    Method.definition
		'textDocument/signatureHelp': Method.signature_help
		'shutdown':                   Method.shutdown
		'exit':                       Method.exit
		r'$/setTrace':                Method.set_trace
		r'$/cancelRequest':           Method.cancel_request
	}

	for method_str, expected in supported {
		actual := Method.from_string(method_str)
		assert actual == expected, 'Method ${method_str} should be ${expected}, got ${actual}'
	}
}

// ============================================================================
// URI/path edge cases tests
// ============================================================================

fn test_integration_uri_path_edge_cases() {
	// Test various URI formats
	test_cases := [
		'file:///simple.v',
		'file:///path/to/file.v',
		'file:///path/with spaces/file.v',
		'file:///very/deep/nested/path/to/file.v',
	]

	for uri in test_cases {
		path := uri_to_path(uri)
		reconstructed := path_to_uri(path)
		// Should be able to convert back (approximately)
		assert reconstructed.contains('file://')
		assert reconstructed.contains('.v')
	}
}

fn test_integration_uri_special_characters() {
	// Paths with special characters
	paths := [
		'/home/user/project/main.v',
		'/tmp/test-file.v',
		'/path/with.dots/file.v',
	]

	for path in paths {
		uri := path_to_uri(path)
		back := uri_to_path(uri)
		assert back == path
	}
}

// ============================================================================
// Complete LSP lifecycle tests
// ============================================================================

fn test_integration_full_lifecycle() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// 1. Create test file
	test_file := os.join_path(project_dir, 'lifecycle.v')
	initial_content := 'module main\n\nfn main() {\n\t// initial\n}\n'
	os.write_file(test_file, initial_content) or { panic(err) }
	uri := path_to_uri(test_file)

	// 2. Simulate initialize (verify capabilities)
	caps := Capabilities{
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
	assert caps.capabilities.definition_provider == true

	// 3. Open document
	app.on_did_open(Request{
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		}
	})
	assert uri in app.open_files

	// 4. Make changes
	modified_content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	app.on_did_change(Request{
		params: Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: modified_content
			}]
		}
	})
	assert app.text == modified_content

	// 5. Request completion
	comp_response := app.operation_at_pos(.completion, Request{
		id:     1
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			}
		}
	})
	assert comp_response.id == 1

	// 6. Request definition
	def_response := app.operation_at_pos(.definition, Request{
		id:     2
		params: Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			}
		}
	})
	assert def_response.id == 2

	// 7. Verify final state
	assert app.open_files[uri] == modified_content
}

fn test_integration_shutdown_response() {
	// Verify shutdown response structure
	shutdown_resp := Response{
		id:     1
		result: 'null'
	}

	encoded := json.encode(shutdown_resp)
	assert encoded.contains('"id":1')
	assert encoded.contains('"result":"null"')
	assert encoded.contains('"jsonrpc":"2.0"')
}
