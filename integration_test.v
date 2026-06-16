// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json
import io

fn integration_test_must_mkdir_all(path string) {
	os.mkdir_all(path) or {
		assert false, 'Failed to create directory ${path}: ${err}'
		return
	}
}

fn integration_test_must_write_file(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'Failed to write file ${path}: ${err}'
		return
	}
}

fn integration_test_frame_message(payload string) string {
	return 'Content-Length: ${payload.len}\r\n\r\n${payload}'
}

fn create_integration_test_env() (&App, string) {
	temp_dir := os.join_path(os.temp_dir(), 'vls_integration_test_${os.getpid()}')
	integration_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'test_project')
	integration_test_must_mkdir_all(project_dir)

	app := &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
	return app, project_dir
}

fn cleanup_integration_test_env(_ &App, project_dir string) {
	parent := os.dir(project_dir)
	os.rmdir_all(parent) or {}
}

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
	assert !encoded.contains('"snippetSupport"')
}

fn test_integration_initialize_does_not_advertise_client_snippet_support() {
	response := Response{
		id:     0
		result: Capabilities{
			capabilities: Capability{
				completion_provider: CompletionProvider{
					trigger_characters: ['.']
				}
			}
		}
	}

	encoded := json.encode(response)
	assert !encoded.contains('"snippetSupport"')
}

fn test_integration_initialize_workspace_capabilities() {
	response := Response{
		id:     0
		result: Capabilities{
			capabilities: Capability{
				execute_command_provider: ExecuteCommandOptions{
					commands: ['vls.runFile', 'vls.runTests']
				}
				workspace:                WorkspaceCapability{
					file_operations:   WorkspaceFileOperations{
						will_create: FileOperationRegistrationOptions{
							filters: [
								FileOperationFilter{
									pattern: FileOperationPattern{
										glob: '**/*.v'
									}
								},
							]
						}
						will_rename: FileOperationRegistrationOptions{
							filters: [
								FileOperationFilter{
									pattern: FileOperationPattern{
										glob: '**/*.v'
									}
								},
							]
						}
						will_delete: FileOperationRegistrationOptions{
							filters: [
								FileOperationFilter{
									pattern: FileOperationPattern{
										glob: '**/*.v'
									}
								},
							]
						}
					}
					workspace_folders: WorkspaceFoldersServerCapability{
						supported:            true
						change_notifications: true
					}
				}
			}
		}
	}

	encoded := json.encode(response)
	assert encoded.contains('"executeCommandProvider":{"commands":["vls.runFile","vls.runTests"]}')
	assert encoded.contains('"workspaceFolders":{"supported":true,"changeNotifications":true}')
	assert encoded.contains('"fileOperations":{"willCreate"')
	assert encoded.contains('"glob":"**/*.v"')
	assert !encoded.contains('"positionEncoding"')
}

fn test_integration_document_lifecycle() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create a valid V file
	test_file := os.join_path(project_dir, 'main.v')
	content := "module main\n\nfn main() {\n\tprintln('hello')\n}\n"
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)

	// 1. Open document
	open_request := Request{
		id:      1
		method:  'textDocument/didOpen'
		jsonrpc: '2.0'
		params:  json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
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
		params:  json.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: new_content
			}]
		})
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
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)

	// Open
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})
	assert app.open_files.len == 1

	// Open another file
	test_file2 := os.join_path(project_dir, 'test2.v')
	integration_test_must_write_file(test_file2, 'module main')
	uri2 := path_to_uri(test_file2)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri2
			}
		})
	})
	assert app.open_files.len == 2
}

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

	integration_test_must_write_file(main_file, main_content)
	integration_test_must_write_file(utils_file, utils_content)

	main_uri := path_to_uri(main_file)
	utils_uri := path_to_uri(utils_file)

	// Open both files
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
		})
	})
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: utils_uri
			}
		})
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

	integration_test_must_write_file(main_file, main_content)
	integration_test_must_write_file(helper_file, helper_content)

	main_uri := path_to_uri(main_file)
	helper_uri := path_to_uri(helper_file)

	// Open both files
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
		})
	})
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: helper_uri
			}
		})
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
	integration_test_must_mkdir_all(src_dir)
	integration_test_must_mkdir_all(lib_dir)

	main_file := os.join_path(src_dir, 'main.v')
	lib_file := os.join_path(lib_dir, 'utils.v')

	integration_test_must_write_file(main_file, 'module src\n\nfn main() {}')
	integration_test_must_write_file(lib_file, 'module lib\n\nfn util() {}')

	main_uri := path_to_uri(main_file)
	lib_uri := path_to_uri(lib_file)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
		})
	})
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: lib_uri
			}
		})
	})

	assert app.open_files.len == 2
}

fn test_integration_diagnostics_syntax_error() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Create a file with a syntax error
	test_file := os.join_path(project_dir, 'error.v')
	// Missing closing brace - syntax error
	error_content := "module main\n\nfn main() {\n\tprintln('hello')\n"
	integration_test_must_write_file(test_file, error_content)

	uri := path_to_uri(test_file)

	// Open the file
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})

	// Trigger change to get diagnostics
	change_request := Request{
		params: json.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: error_content
			}]
		})
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
	integration_test_must_write_file(test_file, valid_content)

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})

	change_request := Request{
		params: json.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: valid_content
			}]
		})
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
	integration_test_must_write_file(test_file, '')

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})

	// Empty content should be processed and return diagnostics for the empty file
	result := app.on_did_change(Request{
		params: json.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: ''
			}]
		})
	})

	if notif := result {
		assert notif.method == 'textDocument/publishDiagnostics'
		assert notif.params.uri == uri
	} else {
		assert false, 'expected a notification for empty file'
	}
}

fn test_integration_completion_request() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'completion.v')
	content := 'module main\n\nfn main() {\n\tos.\n}\n'
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})
	app.text = content
	app.open_files[uri] = content

	// Request completion at the position after "os."
	request := Request{
		id:      1
		method:  'textDocument/completion'
		jsonrpc: '2.0'
		params:  json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 4
			} // After "os."
		})
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
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	// Test with various IDs
	for id in [1, 42, 100, 999] {
		request := Request{
			id:     id
			params: json.encode(Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position:      Position{
					line: 2
					char: 0
				}
			})
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
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	request := Request{
		id:     1
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 9
			}
		})
	}

	response := app.operation_at_pos(.completion, request)
	assert response.id == 1
}

fn test_integration_definition_request() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'definition.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})
	app.text = content
	app.open_files[uri] = content

	// Request definition at the call site of helper()
	request := Request{
		id:      2
		method:  'textDocument/definition'
		jsonrpc: '2.0'
		params:  json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			} // At "helper()"
		})
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

	integration_test_must_write_file(main_file, main_content)
	integration_test_must_write_file(utils_file, utils_content)

	main_uri := path_to_uri(main_file)
	utils_uri := path_to_uri(utils_file)

	// Open both files
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
		})
	})
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: utils_uri
			}
		})
	})
	app.text = main_content
	app.open_files[main_uri] = main_content
	app.open_files[utils_uri] = utils_content

	// Request definition from main file
	request := Request{
		id:     3
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
			position:      Position{
				line: 3
				char: 2
			}
		})
	}

	response := app.operation_at_pos(.definition, request)
	assert response.id == 3
}

fn test_integration_signature_help_request() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'signature.v')
	content := 'module main\n\nfn greet(name string, age int) {}\n\nfn main() {\n\tgreet(\n}\n'
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})
	app.text = content
	app.open_files[uri] = content

	// Request signature help after opening paren
	request := Request{
		id:      3
		method:  'textDocument/signatureHelp'
		jsonrpc: '2.0'
		params:  json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 7
			} // After "greet("
		})
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
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	// At second parameter position
	request := Request{
		id:     4
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 7
			}
		})
	}

	response := app.operation_at_pos(.signature_help, request)
	assert response.id == 4
}

fn test_integration_temp_file_single() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'single.v')
	content := 'module main\n\nfn main() {}\n'
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)

	// Only one file open - should use single file mode
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
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

	integration_test_must_write_file(file1, 'module main\n\nfn a() {}\n')
	integration_test_must_write_file(file2, 'module main\n\nfn b() {}\n')

	uri1 := path_to_uri(file1)
	uri2 := path_to_uri(file2)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri1
			}
		})
	})
	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri2
			}
		})
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
	integration_test_must_write_file(file1, 'module main\n\nfn main() {}\n')

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

fn test_integration_response_encoding() {
	response := Response{
		id:     42
		result: 'null'
	}

	encoded := encode_response_payload(response)

	// Should be valid JSON with required fields
	assert encoded.contains('"id":42')
	assert encoded.contains('"jsonrpc":"2.0"')
	assert encoded.contains('"result":null')
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

fn test_integration_begin_progress_without_client_support_emits_nothing() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	app.capture_output = true
	token := app.begin_progress('Searching workspace symbols…')

	assert token == ''
	assert app.captured_output.len == 0
}

fn test_integration_begin_progress_with_client_support_emits_create_and_begin() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	app.capture_output = true
	app.supports_work_done_progress = true
	token := app.begin_progress('Searching workspace symbols…')

	assert token != ''
	assert app.captured_output.len == 2
	assert app.captured_output[0].contains('"method":"window/workDoneProgress/create"')
	assert app.captured_output[0].contains('"token":"${token}"')
	assert app.captured_output[1].contains('"method":"$/progress"')
	assert app.captured_output[1].contains('"kind":"begin"')
	assert app.captured_output[1].contains('"title":"Searching workspace symbols')
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

fn test_integration_request_id_preserved() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'test.v')
	content := 'module main\n\nfn main() {}\n'
	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	// Test with different request IDs
	for id in [1, 42, 999, 0] {
		request := Request{
			id:     id
			method: 'textDocument/completion'
			params: json.encode(Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position:      Position{
					line: 2
					char: 0
				}
			})
		}

		response := app.operation_at_pos(.completion, request)
		assert response.id == id
	}
}

fn test_integration_method_unknown_handling() {
	// Verify unknown methods are handled gracefully — only empty string is truly unknown now.
	assert Method.from_string('') == .unknown
	// workspace/executeCommand is now supported.
	assert Method.from_string('workspace/executeCommand') == .execute_command
}

fn test_integration_method_all_supported() {
	// Verify all supported methods are recognized
	supported := {
		'initialize':                          Method.initialize
		'initialized':                         Method.initialized
		'textDocument/didOpen':                Method.did_open
		'textDocument/didChange':              Method.did_change
		'textDocument/didClose':               Method.did_close
		'textDocument/didSave':                Method.did_save
		'textDocument/completion':             Method.completion
		'textDocument/definition':             Method.definition
		'textDocument/declaration':            Method.declaration
		'textDocument/typeDefinition':         Method.type_definition
		'textDocument/implementation':         Method.implementation
		'textDocument/signatureHelp':          Method.signature_help
		'textDocument/prepareRename':          Method.prepare_rename
		'workspace/symbol':                    Method.workspace_symbol
		'textDocument/rangeFormatting':        Method.range_formatting
		'textDocument/documentHighlight':      Method.document_highlight
		'textDocument/selectionRange':         Method.selection_range
		'textDocument/semanticTokens/range':   Method.semantic_tokens_range
		'workspace/didChangeWatchedFiles':     Method.did_change_watched_files
		'textDocument/codeLens':               Method.code_lens
		'codeLens/resolve':                    Method.code_lens_resolve
		'workspace/executeCommand':            Method.execute_command
		'textDocument/inlineValue':            Method.inline_value
		'textDocument/linkedEditingRange':     Method.linked_editing_range
		'workspace/willCreateFiles':           Method.will_create_files
		'workspace/willRenameFiles':           Method.will_rename_files
		'workspace/willDeleteFiles':           Method.will_delete_files
		'textDocument/onTypeFormatting':       Method.on_type_formatting
		'workspace/didChangeWorkspaceFolders': Method.workspace_did_change_workspace_folders
		'shutdown':                            Method.shutdown
		'exit':                                Method.exit
		r'$/setTrace':                         Method.set_trace
		r'$/cancelRequest':                    Method.cancel_request
	}

	for method_str, expected in supported {
		actual := Method.from_string(method_str)
		assert actual == expected, 'Method ${method_str} should be ${expected}, got ${actual}'
	}
}

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

fn test_integration_full_lifecycle() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// 1. Create test file
	test_file := os.join_path(project_dir, 'lifecycle.v')
	initial_content := 'module main\n\nfn main() {\n\t// initial\n}\n'
	integration_test_must_write_file(test_file, initial_content)
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
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})
	assert uri in app.open_files

	// 4. Make changes
	modified_content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	app.on_did_change(Request{
		params: json.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: modified_content
			}]
		})
	})
	assert app.text == modified_content

	// 5. Request completion
	comp_response := app.operation_at_pos(.completion, Request{
		id:     1
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			}
		})
	})
	assert comp_response.id == 1

	// 6. Request definition
	def_response := app.operation_at_pos(.definition, Request{
		id:     2
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			}
		})
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
	transport_encoded := encode_response_payload(shutdown_resp)
	assert transport_encoded.contains('"result":null')
}

fn test_integration_malformed_json_request_writes_parse_error_response() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	payload := '{"jsonrpc":"2.0","method":"initialize","params":'
	framed := integration_test_frame_message(payload)
	input_path := os.join_path(project_dir, 'malformed_lsp_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open malformed request input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.captured_output.len >= 1
	outbound := app.captured_output[0]
	assert outbound.contains('Content-Length: ')
	assert outbound.contains('"code":-32700')
	assert outbound.contains('"id":null')
}

fn test_integration_non_default_charset_content_type_header_is_accepted() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	payload := '{"jsonrpc":"2.0","id":99,"method":"initialize","params":{}}'
	frame := 'Content-Length: ${payload.len}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-16\r\n\r\n${payload}'
	input_path := os.join_path(project_dir, 'non_default_charset_header_input.txt')
	integration_test_must_write_file(input_path, frame)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open non-default-charset header input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.captured_output.len >= 1
	outbound := app.captured_output[0]
	assert outbound.contains('"id":99')
	assert outbound.contains('"result"')
}

fn test_integration_pre_initialize_request_rejected_with_server_not_initialized() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	payload := '{"jsonrpc":"2.0","id":1,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tmp/a.v"},"position":{"line":0,"character":0}}}'
	framed := integration_test_frame_message(payload)
	input_path := os.join_path(project_dir, 'pre_init_request_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open pre-initialize request input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.captured_output.len >= 1
	outbound := app.captured_output[0]
	assert outbound.contains('"id":1')
	assert outbound.contains('"code":-32002')
	assert outbound.contains('"message":"Server not yet initialized"')
}

fn test_integration_pre_initialize_notification_is_ignored() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	did_open_before_init := '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/preinit.v","text":"module main"}}}'
	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	framed := integration_test_frame_message(did_open_before_init) +
		integration_test_frame_message(initialize)
	input_path := os.join_path(project_dir, 'pre_init_notification_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open pre-initialize notification input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.open_files.len == 0
	assert app.received_initialize
	assert app.captured_output.len == 1
	assert app.captured_output[0].contains('"id":1')
	assert app.captured_output[0].contains('"result"')
}

fn test_integration_initialized_notification_after_initialize_registers_watcher() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}}}}'
	initialized := '{"jsonrpc":"2.0","method":"initialized","params":{}}'
	framed := integration_test_frame_message(initialize) +
		integration_test_frame_message(initialized)
	input_path := os.join_path(project_dir, 'initialized_notification_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open initialized notification input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	// initialize response + client/registerCapability server-initiated request
	assert app.captured_output.len == 2
	assert app.captured_output[0].contains('"id":1')
	assert app.captured_output[0].contains('"result"')
	assert app.captured_output[1].contains('"method":"client/registerCapability"')
	assert app.captured_output[1].contains('"workspace/didChangeWatchedFiles"')
	assert app.captured_output[1].contains('"**/*.v"')
}

fn test_integration_initialized_notification_without_dynamic_support_skips_registration() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	initialized := '{"jsonrpc":"2.0","method":"initialized","params":{}}'
	framed := integration_test_frame_message(initialize) +
		integration_test_frame_message(initialized)
	input_path := os.join_path(project_dir, 'initialized_no_dynamic_support_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open initialized-without-dynamic-support input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.received_initialize
	assert !app.supports_dynamic_watched_files_registration
	assert app.captured_output.len == 1
	assert app.captured_output[0].contains('"id":1')
	assert app.captured_output[0].contains('"result"')
	assert !app.captured_output[0].contains('client/registerCapability')
}

fn test_integration_duplicate_initialized_sends_single_registration() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}}}}'
	initialized_1 := '{"jsonrpc":"2.0","method":"initialized","params":{}}'
	initialized_2 := '{"jsonrpc":"2.0","method":"initialized","params":{}}'
	framed := integration_test_frame_message(initialize) +
		integration_test_frame_message(initialized_1) +
		integration_test_frame_message(initialized_2)
	input_path := os.join_path(project_dir, 'duplicate_initialized_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open duplicate-initialized input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	// initialize response + exactly one client/registerCapability request
	assert app.captured_output.len == 2
	assert app.captured_output[0].contains('"id":1')
	assert app.captured_output[0].contains('"result"')
	assert app.captured_output[1].contains('"method":"client/registerCapability"')
	assert app.sent_watched_files_registration
}

fn test_integration_post_initialize_notification_updates_state() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	uri := 'file:///tmp/postinit.v'
	content := 'module main\n\nfn main() {}\n'
	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	did_open_after_init := '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"${uri}","text":"${content}"}}}'
	framed := integration_test_frame_message(initialize) +
		integration_test_frame_message(did_open_after_init)
	input_path := os.join_path(project_dir, 'post_init_notification_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open post-initialize notification input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.received_initialize
	assert uri in app.open_files
	assert app.open_files[uri] == content
	assert app.text == content
	assert app.captured_output.len == 1
	assert app.captured_output[0].contains('"id":1')
	assert app.captured_output[0].contains('"result"')
}

fn test_integration_pre_initialize_cancel_request_is_ignored() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	cancel_before_init := '{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":99}}'
	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	framed := integration_test_frame_message(cancel_before_init) +
		integration_test_frame_message(initialize)
	input_path := os.join_path(project_dir, 'pre_init_cancel_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open pre-initialize cancel input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	// $/cancelRequest has no id so no error response should be emitted.
	// The server still processes initialize and emits a single response.
	assert app.captured_output.len == 1
	assert app.captured_output[0].contains('"id":1')
	assert app.captured_output[0].contains('"result"')
	assert app.received_initialize
}

fn test_integration_second_initialize_rejected_with_invalid_request() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	initialize_1 := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	initialize_2 := '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}'
	framed := integration_test_frame_message(initialize_1) +
		integration_test_frame_message(initialize_2)
	input_path := os.join_path(project_dir, 'double_initialize_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open double-initialize request input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.captured_output.len >= 2
	first := app.captured_output[0]
	second := app.captured_output[1]
	assert first.contains('"id":1')
	assert first.contains('"result"')
	assert second.contains('"id":2')
	assert second.contains('"code":-32600')
	assert second.contains('"message":"Server already initialized"')
}

fn test_integration_post_shutdown_request_rejected_with_invalid_request() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	shutdown := '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}'
	completion_after_shutdown := '{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tmp/a.v"},"position":{"line":0,"character":0}}}'
	framed := integration_test_frame_message(initialize) +
		integration_test_frame_message(shutdown) +
		integration_test_frame_message(completion_after_shutdown)
	input_path := os.join_path(project_dir, 'post_shutdown_request_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open post-shutdown request input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.captured_output.len >= 3
	third := app.captured_output[2]
	assert third.contains('"id":3')
	assert third.contains('"code":-32600')
	assert third.contains('"message":"Server has been shut down"')
}

fn test_integration_exit_after_shutdown_emits_no_exit_response() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	shutdown := '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}'
	exit_notification := '{"jsonrpc":"2.0","method":"exit","params":{}}'
	framed := integration_test_frame_message(initialize) +
		integration_test_frame_message(shutdown) + integration_test_frame_message(exit_notification)
	input_path := os.join_path(project_dir, 'shutdown_exit_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open shutdown+exit input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	// initialize and shutdown produce responses; exit is a notification and must not.
	assert app.captured_output.len == 2
	assert app.captured_output[0].contains('"id":1')
	assert app.captured_output[1].contains('"id":2')
	assert app.is_shutdown
	assert app.exit_was_requested
}

fn test_integration_exit_without_shutdown_emits_no_response_and_sets_flag() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	exit_notification := '{"jsonrpc":"2.0","method":"exit","params":{}}'
	framed := integration_test_frame_message(exit_notification)
	input_path := os.join_path(project_dir, 'exit_without_shutdown_input.txt')
	integration_test_must_write_file(input_path, framed)

	mut input := os.open(input_path) or {
		assert false, 'Failed to open exit-without-shutdown input: ${err}'
		return
	}
	defer {
		input.close()
	}

	app.capture_output = true
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.handle_requests(mut reader)

	assert app.captured_output.len == 0
	assert !app.is_shutdown
	assert app.exit_was_requested
}

fn test_integration_completion_includes_sibling_pub_fn() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	// Two files in the same module: main.v triggers completion, utils.v has a pub fn
	main_file := os.join_path(project_dir, 'main.v')
	utils_file := os.join_path(project_dir, 'utils.v')

	main_content := 'module main\n\nfn main() {\n\thelper\n}\n'
	utils_content := 'module main\n\npub fn helper_from_sibling(x int) string {\n\treturn x.str()\n}\n'

	integration_test_must_write_file(main_file, main_content)
	integration_test_must_write_file(utils_file, utils_content)

	main_uri := path_to_uri(main_file)
	utils_uri := path_to_uri(utils_file)

	// Simulate both files being open in the editor
	app.open_files[main_uri] = main_content
	app.open_files[utils_uri] = utils_content
	app.text = main_content

	// Request completion at `helper` on line 3, col 1 (not after '.')
	response := app.operation_at_pos(.completion, Request{
		id:     1
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
			position:      Position{
				line: 3
				char: 1
			}
		})
	})

	assert response.id == 1
	result := response.result
	assert result is CompletionList, 'Expected CompletionList, got ${typeof(result).name}'
	details := (result as CompletionList).items
	labels := details.map(it.label)
	assert 'helper_from_sibling' in labels, 'Expected helper_from_sibling in completion labels'
}

fn test_integration_completion_includes_private_sibling_fn() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	main_file := os.join_path(project_dir, 'main.v')
	utils_file := os.join_path(project_dir, 'utils.v')

	main_content := 'module main\n\nfn main() {\n\tpr\n}\n'
	// Plain fn (no pub) — should appear because it belongs to the same module
	utils_content := 'module main\n\nfn private_sibling() {}\n'

	integration_test_must_write_file(main_file, main_content)
	integration_test_must_write_file(utils_file, utils_content)

	main_uri := path_to_uri(main_file)
	utils_uri := path_to_uri(utils_file)

	app.open_files[main_uri] = main_content
	app.open_files[utils_uri] = utils_content
	app.text = main_content

	response := app.operation_at_pos(.completion, Request{
		id:     1
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
			position:      Position{
				line: 3
				char: 2
			}
		})
	})

	assert response.id == 1
	result := response.result
	assert result is CompletionList, 'Expected CompletionList, got ${typeof(result).name}'
	details := (result as CompletionList).items
	labels := details.map(it.label)
	assert 'private_sibling' in labels, 'Expected private_sibling in completion labels'
}

fn test_integration_completion_includes_current_file_fns() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'main.v')
	// File defines helper_local before main — trigger completion inside main
	content := 'module main\n\nfn helper_local() {}\n\nfn main() {\n\the\n}\n'

	integration_test_must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	app.text = content

	response := app.operation_at_pos(.completion, Request{
		id:     1
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5 // inside fn main, after `he`
				char: 2
			}
		})
	})

	assert response.id == 1
	result := response.result
	assert result is CompletionList, 'Expected CompletionList, got ${typeof(result).name}'
	details := (result as CompletionList).items
	labels := details.map(it.label)
	// helper_local is defined in the same file and must appear
	assert 'helper_local' in labels, 'Expected helper_local in completion labels'
}

fn test_integration_did_close_removes_tracked_file() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'close_test.v')
	content := 'module main\n\nfn main() {}\n'
	integration_test_must_write_file(test_file, content)
	uri := path_to_uri(test_file)

	app.on_did_open(Request{
		params: json.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})
	assert uri in app.open_files

	app.on_did_close(Request{
		params: json.encode(DidCloseTextDocumentParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	})

	assert uri !in app.open_files
}

fn test_integration_did_save_returns_diagnostics_notification() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'save_test.v')
	content := 'module main\n\nfn main() {}\n'
	integration_test_must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	notification := app.on_did_save(Request{
		params: json.encode(DidSaveTextDocumentParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		})
	}) or {
		assert false, 'Expected didSave to produce diagnostics notification'
		return
	}

	assert notification.method == 'textDocument/publishDiagnostics'
	assert notification.params.uri == uri
}

fn test_integration_prepare_rename_returns_symbol_range() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'prepare_rename.v')
	content := 'module main\n\nfn main() {\n\tvalue := 1\n\tprintln(value)\n}\n'
	integration_test_must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	response := app.handle_prepare_rename(Request{
		id:     301
		method: 'textDocument/prepareRename'
		params: json.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 4
				char: 12
			}
		})
	})

	assert response.id == 301
	assert response.result is PrepareRenameResult
	result := response.result as PrepareRenameResult
	assert result.placeholder == 'value'
	assert result.range.start.line == 4
}

fn test_integration_workspace_symbol_query_matches() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'workspace_symbols.v')
	content := 'module main\n\nstruct Person {\n\tname string\n}\n\nfn helper_name() {}\n'
	integration_test_must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	response := app.handle_workspace_symbol(Request{
		id:     302
		method: 'workspace/symbol'
		params: json.encode(WorkspaceSymbolParams{
			query: 'name'
		})
	})

	assert response.id == 302
	assert response.result is []WorkspaceSymbol
	syms := response.result as []WorkspaceSymbol
	labels := syms.map(it.name)
	assert 'Person.name' in labels
	assert 'helper_name' in labels
}

fn test_integration_alias_navigation_methods_preserve_id() {
	mut app, project_dir := create_integration_test_env()
	defer {
		cleanup_integration_test_env(app, project_dir)
	}

	test_file := os.join_path(project_dir, 'alias_nav.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	integration_test_must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	app.text = content

	methods := [Method.declaration, Method.type_definition, Method.implementation]
	mut request_id := 410
	for m in methods {
		resp := app.operation_at_pos(m, Request{
			id:     request_id
			method: m.str()
			params: json.encode(TextDocumentPositionParams{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position:      Position{
					line: 5
					char: 2
				}
			})
		})
		assert resp.id == request_id
		request_id++
	}
}

fn test_integration_capability_flags_for_new_features() {
	caps := Capability{
		text_document_sync:        TextDocumentSyncOptions{
			open_close: true
			change:     2
			save:       SaveOptions{
				include_text: true
			}
		}
		declaration_provider:      true
		type_definition_provider:  true
		implementation_provider:   true
		rename_provider:           RenameOptions{
			prepare_provider: true
		}
		workspace_symbol_provider: true
	}

	encoded := json.encode(Capabilities{
		capabilities: caps
	})

	assert encoded.contains('"save":{"includeText":true}')
	assert encoded.contains('"declarationProvider":true')
	assert encoded.contains('"typeDefinitionProvider":true')
	assert encoded.contains('"implementationProvider":true')
	assert encoded.contains('"renameProvider":{"prepareProvider":true}')
	assert encoded.contains('"workspaceSymbolProvider":true')
}
