// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json

// ============================================================================
// Unit tests for LSP structures and Method enum
// ============================================================================

// --- Method.from_string() tests ---

fn test_method_from_string_initialize() {
	assert Method.from_string('initialize') == .initialize
}

fn test_method_from_string_initialized() {
	assert Method.from_string('initialized') == .initialized
}

fn test_method_from_string_did_open() {
	assert Method.from_string('textDocument/didOpen') == .did_open
}

fn test_method_from_string_did_change() {
	assert Method.from_string('textDocument/didChange') == .did_change
}

fn test_method_from_string_definition() {
	assert Method.from_string('textDocument/definition') == .definition
}

fn test_method_from_string_completion() {
	assert Method.from_string('textDocument/completion') == .completion
}

fn test_method_from_string_signature_help() {
	assert Method.from_string('textDocument/signatureHelp') == .signature_help
}

fn test_method_from_string_set_trace() {
	assert Method.from_string('$/setTrace') == .set_trace
}

fn test_method_from_string_cancel_request() {
	assert Method.from_string('$/cancelRequest') == .cancel_request
}

fn test_method_from_string_shutdown() {
	assert Method.from_string('shutdown') == .shutdown
}

fn test_method_from_string_exit() {
	assert Method.from_string('exit') == .exit
}

fn test_method_from_string_unknown() {
	assert Method.from_string('unknown_method') == .unknown
	assert Method.from_string('') == .unknown
}

fn test_method_from_string_hover() {
	assert Method.from_string('textDocument/hover') == .hover
}

fn test_method_from_string_references() {
	assert Method.from_string('textDocument/references') == .references
}

fn test_method_from_string_rename() {
	assert Method.from_string('textDocument/rename') == .rename
}

fn test_method_from_string_unsupported_methods() {
	// These are valid LSP methods but not supported by VLS
	unsupported := [
		'textDocument/formatting',
		'textDocument/rangeFormatting',
		'textDocument/codeAction',
		'textDocument/codeLens',
		'textDocument/documentSymbol',
		'workspace/symbol',
		'workspace/executeCommand',
	]
	for method_str in unsupported {
		assert Method.from_string(method_str) == .unknown
	}
}

fn test_method_from_string_case_sensitive() {
	// Method strings are case-sensitive
	assert Method.from_string('Initialize') == .unknown
	assert Method.from_string('INITIALIZE') == .unknown
	assert Method.from_string('textDocument/DidOpen') == .unknown
	assert Method.from_string('textdocument/didopen') == .unknown
}

// --- Method.str() tests ---

fn test_method_str_initialize() {
	assert Method.initialize.str() == 'initialize'
}

fn test_method_str_initialized() {
	assert Method.initialized.str() == 'initialized'
}

fn test_method_str_did_open() {
	assert Method.did_open.str() == 'textDocument/didOpen'
}

fn test_method_str_did_change() {
	assert Method.did_change.str() == 'textDocument/didChange'
}

fn test_method_str_definition() {
	assert Method.definition.str() == 'textDocument/definition'
}

fn test_method_str_completion() {
	assert Method.completion.str() == 'textDocument/completion'
}

fn test_method_str_signature_help() {
	assert Method.signature_help.str() == 'textDocument/signatureHelp'
}

fn test_method_str_hover() {
	assert Method.hover.str() == 'textDocument/hover'
}

fn test_method_str_references() {
	assert Method.references.str() == 'textDocument/references'
}

fn test_method_str_rename() {
	assert Method.rename.str() == 'textDocument/rename'
}

fn test_method_str_set_trace() {
	assert Method.set_trace.str() == '$/setTrace'
}

fn test_method_str_cancel_request() {
	assert Method.cancel_request.str() == '$/cancelRequest'
}

fn test_method_str_shutdown() {
	assert Method.shutdown.str() == 'shutdown'
}

fn test_method_str_exit() {
	assert Method.exit.str() == 'exit'
}

fn test_method_str_unknown() {
	assert Method.unknown.str() == 'unknown'
}

// --- Round-trip conversion tests ---

fn test_method_roundtrip() {
	methods := [Method.initialize, Method.initialized, Method.did_open, Method.did_change,
		Method.definition, Method.completion, Method.signature_help, Method.hover, Method.references,
		Method.rename, Method.set_trace, Method.cancel_request, Method.shutdown, Method.exit]
	for m in methods {
		assert Method.from_string(m.str()) == m
	}
}

fn test_method_roundtrip_all_values() {
	// Ensure all Method enum values round-trip correctly
	$for m in Method.values {
		if m.value != Method.unknown {
			assert Method.from_string(m.value.str()) == m.value
		}
	}
}

// --- Position struct tests ---

fn test_position_default_values() {
	pos := Position{}
	assert pos.line == 0
	assert pos.char == 0
}

fn test_position_with_values() {
	pos := Position{
		line: 42
		char: 15
	}
	assert pos.line == 42
	assert pos.char == 15
}

fn test_position_json_encoding() {
	pos := Position{
		line: 10
		char: 5
	}
	encoded := json.encode(pos)
	assert encoded.contains('"line":10')
	assert encoded.contains('"character":5')
}

fn test_position_json_decoding() {
	json_str := '{"line":20,"character":8}'
	pos := json.decode(Position, json_str) or {
		assert false, 'Failed to decode Position: ${err}'
		return
	}
	assert pos.line == 20
	assert pos.char == 8
}

// --- LSPRange struct tests ---

fn test_lsp_range_default_values() {
	r := LSPRange{}
	assert r.start.line == 0
	assert r.start.char == 0
	assert r.end.line == 0
	assert r.end.char == 0
}

fn test_lsp_range_same_line() {
	r := LSPRange{
		start: Position{
			line: 5
			char: 10
		}
		end:   Position{
			line: 5
			char: 20
		}
	}
	assert r.start.line == r.end.line
	assert r.end.char > r.start.char
}

fn test_lsp_range_multi_line() {
	r := LSPRange{
		start: Position{
			line: 5
			char: 0
		}
		end:   Position{
			line: 10
			char: 15
		}
	}
	assert r.end.line > r.start.line
}

fn test_lsp_range_json_encoding() {
	r := LSPRange{
		start: Position{
			line: 1
			char: 2
		}
		end:   Position{
			line: 3
			char: 4
		}
	}
	encoded := json.encode(r)
	assert encoded.contains('"start"')
	assert encoded.contains('"end"')
}

// --- TextDocumentIdentifier tests ---

fn test_text_document_identifier() {
	doc := TextDocumentIdentifier{
		uri: 'file:///test/file.v'
	}
	assert doc.uri == 'file:///test/file.v'
}

fn test_text_document_identifier_json_encoding() {
	doc := TextDocumentIdentifier{
		uri: 'file:///path/to/file.v'
	}
	encoded := json.encode(doc)
	assert encoded.contains('"uri":"file:///path/to/file.v"')
}

// --- ContentChange tests ---

fn test_content_change_empty() {
	change := ContentChange{}
	assert change.text == ''
}

fn test_content_change_with_text() {
	change := ContentChange{
		text: 'fn main() {}'
	}
	assert change.text == 'fn main() {}'
}

fn test_content_change_multiline() {
	change := ContentChange{
		text: 'fn main() {\n\tprintln("hello")\n}'
	}
	assert change.text.contains('\n')
}

// --- Params struct tests ---

fn test_params_empty() {
	params := Params{}
	assert params.content_changes.len == 0
	assert params.position.line == 0
	assert params.text_document.uri == ''
}

fn test_params_with_position() {
	params := Params{
		position: Position{
			line: 10
			char: 5
		}
	}
	assert params.position.line == 10
	assert params.position.char == 5
}

fn test_params_with_content_changes() {
	params := Params{
		content_changes: [ContentChange{
			text: 'test'
		}]
	}
	assert params.content_changes.len == 1
	assert params.content_changes[0].text == 'test'
}

fn test_params_json_decoding() {
	json_str := '{"textDocument":{"uri":"file:///test.v"},"position":{"line":5,"character":10}}'
	params := json.decode(Params, json_str) or {
		assert false, 'Failed to decode Params: ${err}'
		return
	}
	assert params.text_document.uri == 'file:///test.v'
	assert params.position.line == 5
	assert params.position.char == 10
}

// --- Request struct tests ---

fn test_request_default_values() {
	req := Request{}
	assert req.id == 0
	assert req.method == ''
	assert req.jsonrpc == ''
}

fn test_request_with_values() {
	req := Request{
		id:      1
		method:  'textDocument/completion'
		jsonrpc: '2.0'
	}
	assert req.id == 1
	assert req.method == 'textDocument/completion'
	assert req.jsonrpc == '2.0'
}

fn test_request_json_decoding_completion() {
	json_str := '{"id":1,"method":"textDocument/completion","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"position":{"line":5,"character":10}}}'
	req := json.decode(Request, json_str) or {
		assert false, 'Failed to decode Request: ${err}'
		return
	}
	assert req.id == 1
	assert req.method == 'textDocument/completion'
	assert req.params.position.line == 5
}

fn test_request_json_decoding_did_change() {
	json_str := '{"id":2,"method":"textDocument/didChange","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"contentChanges":[{"text":"fn main() {}"}]}}'
	req := json.decode(Request, json_str) or {
		assert false, 'Failed to decode Request: ${err}'
		return
	}
	assert req.method == 'textDocument/didChange'
	assert req.params.content_changes.len == 1
	assert req.params.content_changes[0].text == 'fn main() {}'
}

fn test_request_json_decoding_initialize() {
	json_str := '{"id":0,"method":"initialize","jsonrpc":"2.0","params":{}}'
	req := json.decode(Request, json_str) or {
		assert false, 'Failed to decode Request: ${err}'
		return
	}
	assert req.id == 0
	assert req.method == 'initialize'
}

// --- Response struct tests ---

fn test_response_default_jsonrpc() {
	resp := Response{
		id:     1
		result: 'null'
	}
	assert resp.jsonrpc == '2.0'
}

fn test_response_json_encoding() {
	resp := Response{
		id:     42
		result: 'null'
	}
	encoded := json.encode(resp)
	assert encoded.contains('"id":42')
	assert encoded.contains('"jsonrpc":"2.0"')
}

// --- Notification struct tests ---

fn test_notification_default_jsonrpc() {
	notif := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{}
	}
	assert notif.jsonrpc == '2.0'
}

fn test_notification_json_encoding() {
	notif := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri:         'file:///test.v'
			diagnostics: []
		}
	}
	encoded := json.encode(notif)
	assert encoded.contains('"method":"textDocument/publishDiagnostics"')
	assert encoded.contains('"jsonrpc":"2.0"')
}

// --- LSPDiagnostic struct tests ---

fn test_lsp_diagnostic_error_severity() {
	diag := LSPDiagnostic{
		range:    LSPRange{}
		message:  'error message'
		severity: 1
	}
	assert diag.severity == 1 // Error
	assert diag.message == 'error message'
}

fn test_lsp_diagnostic_warning_severity() {
	diag := LSPDiagnostic{
		range:    LSPRange{}
		message:  'warning message'
		severity: 2
	}
	assert diag.severity == 2 // Warning
}

fn test_lsp_diagnostic_json_encoding() {
	diag := LSPDiagnostic{
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
	}
	encoded := json.encode(diag)
	assert encoded.contains('"message":"undefined identifier"')
	assert encoded.contains('"severity":1')
}

// --- Detail struct tests ---

fn test_detail_function_kind() {
	detail := Detail{
		kind:          6 // Function
		label:         'my_function'
		detail:        'fn my_function() string'
		documentation: 'A helper function'
	}
	assert detail.kind == 6
	assert detail.label == 'my_function'
}

fn test_detail_variable_kind() {
	detail := Detail{
		kind:          6
		label:         'my_var'
		detail:        'int'
		documentation: 'A variable'
	}
	assert detail.label == 'my_var'
}

fn test_detail_with_snippet() {
	detail := Detail{
		kind:               6
		label:              'println'
		detail:             'fn println(s string)'
		insert_text:        'println(\${1:s})'
		insert_text_format: 2 // Snippet
	}
	assert detail.insert_text? == 'println(\${1:s})'
	assert detail.insert_text_format? == 2
}

fn test_detail_json_encoding() {
	detail := Detail{
		kind:  6
		label: 'test_fn'
	}
	encoded := json.encode(detail)
	assert encoded.contains('"kind":6')
	assert encoded.contains('"label":"test_fn"')
}

// --- Location struct tests ---

fn test_location_basic() {
	loc := Location{
		uri:   'file:///test/file.v'
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
	assert loc.uri == 'file:///test/file.v'
	assert loc.range.start.line == 10
}

fn test_location_json_encoding() {
	loc := Location{
		uri:   'file:///path/to/file.v'
		range: LSPRange{
			start: Position{
				line: 0
				char: 0
			}
			end:   Position{
				line: 0
				char: 5
			}
		}
	}
	encoded := json.encode(loc)
	assert encoded.contains('"uri":"file:///path/to/file.v"')
	assert encoded.contains('"range"')
}

// --- SignatureHelp struct tests ---

fn test_signature_help_empty() {
	sig := SignatureHelp{}
	assert sig.signatures.len == 0
	assert sig.active_signature == 0
	assert sig.active_parameter == 0
}

fn test_signature_help_with_signature() {
	sig := SignatureHelp{
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
	assert sig.signatures.len == 1
	assert sig.active_parameter == 1
	assert sig.signatures[0].parameters.len == 2
}

fn test_signature_help_json_encoding() {
	sig := SignatureHelp{
		signatures:       [
			SignatureInformation{
				label: 'fn example()'
			},
		]
		active_signature: 0
		active_parameter: 0
	}
	encoded := json.encode(sig)
	assert encoded.contains('"activeSignature":0')
	assert encoded.contains('"activeParameter":0')
}

// --- Capabilities struct tests ---

fn test_capabilities_full() {
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
	assert caps.capabilities.completion_provider.trigger_characters == ['.']
	assert caps.capabilities.signature_help_provider.trigger_characters == ['(', ',']
	assert caps.capabilities.text_document_sync.change == 1
}

fn test_capabilities_json_encoding() {
	caps := Capabilities{
		capabilities: Capability{
			definition_provider: true
		}
	}
	encoded := json.encode(caps)
	assert encoded.contains('"definitionProvider":true')
}

// --- CompletionProvider tests ---

fn test_completion_provider_trigger_characters() {
	provider := CompletionProvider{
		trigger_characters: ['.', ':', '@']
	}
	assert provider.trigger_characters.len == 3
	assert '.' in provider.trigger_characters
}

fn test_completion_provider_with_snippet_support() {
	provider := CompletionProvider{
		trigger_characters: ['.']
		completion_item:    CompletionItemCapability{
			snippet_support: true
		}
	}
	assert provider.completion_item?.snippet_support == true
}

// --- TextDocumentSyncOptions tests ---

fn test_text_document_sync_full() {
	sync := TextDocumentSyncOptions{
		open_close: true
		change:     1 // Full
	}
	assert sync.open_close == true
	assert sync.change == 1
}

fn test_text_document_sync_incremental() {
	sync := TextDocumentSyncOptions{
		open_close: true
		change:     2 // Incremental
	}
	assert sync.change == 2
}

// --- SignatureHelpOptions tests ---

fn test_signature_help_options() {
	opts := SignatureHelpOptions{
		trigger_characters: ['(', ',', '<']
	}
	assert opts.trigger_characters.len == 3
	assert '(' in opts.trigger_characters
}

// --- ResponseResult union type tests ---

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

// --- PublishDiagnosticsParams tests ---

fn test_publish_diagnostics_params_empty() {
	params := PublishDiagnosticsParams{
		uri:         'file:///test.v'
		diagnostics: []
	}
	assert params.uri == 'file:///test.v'
	assert params.diagnostics.len == 0
}

fn test_publish_diagnostics_params_with_diagnostics() {
	params := PublishDiagnosticsParams{
		uri:         'file:///test.v'
		diagnostics: [
			LSPDiagnostic{
				range:    LSPRange{}
				message:  'error 1'
				severity: 1
			},
			LSPDiagnostic{
				range:    LSPRange{}
				message:  'error 2'
				severity: 1
			},
		]
	}
	assert params.diagnostics.len == 2
}

// --- JsonError struct tests ---

fn test_json_error_struct() {
	err := JsonError{
		path:    '/test/file.v'
		message: 'undefined identifier'
		line_nr: 10
		col:     5
		len:     3
	}
	assert err.path == '/test/file.v'
	assert err.message == 'undefined identifier'
	assert err.line_nr == 10
	assert err.col == 5
	assert err.len == 3
}

fn test_json_error_json_decoding() {
	json_str := '{"path":"/test/file.v","message":"error","line_nr":5,"col":10,"len":2}'
	err := json.decode(JsonError, json_str) or {
		assert false, 'Failed to decode JsonError: ${err}'
		return
	}
	assert err.path == '/test/file.v'
	assert err.line_nr == 5
}

fn test_json_error_array_decoding() {
	json_str := '[{"path":"/a.v","message":"err1","line_nr":1,"col":1,"len":1},{"path":"/b.v","message":"err2","line_nr":2,"col":2,"len":2}]'
	errors := json.decode([]JsonError, json_str) or {
		assert false, 'Failed to decode JsonError array: ${err}'
		return
	}
	assert errors.len == 2
	assert errors[0].path == '/a.v'
	assert errors[1].path == '/b.v'
}

// --- JsonVarAC struct tests ---

fn test_json_var_ac_empty() {
	ac := JsonVarAC{}
	assert ac.details.len == 0
}

fn test_json_var_ac_with_details() {
	ac := JsonVarAC{
		details: [
			Detail{
				kind:  6
				label: 'fn1'
			},
			Detail{
				kind:  6
				label: 'fn2'
			},
		]
	}
	assert ac.details.len == 2
}

fn test_json_var_ac_json_decoding() {
	json_str := '{"details":[{"kind":6,"label":"test","detail":"","documentation":""}]}'
	ac := json.decode(JsonVarAC, json_str) or {
		assert false, 'Failed to decode JsonVarAC: ${err}'
		return
	}
	assert ac.details.len == 1
	assert ac.details[0].label == 'test'
}
