// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import io
import os

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
	// These methods are now supported by VLS.
	assert Method.from_string('textDocument/codeLens') == .code_lens
	assert Method.from_string('workspace/executeCommand') == .execute_command
	assert Method.from_string('workspace/symbol') == .workspace_symbol
	assert Method.from_string('textDocument/prepareRename') == .prepare_rename
	assert Method.from_string('textDocument/declaration') == .declaration
	assert Method.from_string('textDocument/typeDefinition') == .type_definition
	assert Method.from_string('textDocument/implementation') == .implementation
	assert Method.from_string('textDocument/didClose') == .did_close
	assert Method.from_string('textDocument/didSave') == .did_save
	assert Method.from_string('textDocument/codeAction') == .code_action
	assert Method.from_string('textDocument/rangeFormatting') == .range_formatting
	assert Method.from_string('textDocument/documentHighlight') == .document_highlight
	assert Method.from_string('textDocument/selectionRange') == .selection_range
	assert Method.from_string('textDocument/semanticTokens/range') == .semantic_tokens_range
	assert Method.from_string('workspace/didChangeWatchedFiles') == .did_change_watched_files
}

fn test_method_from_string_case_sensitive() {
	// Method strings are case-sensitive
	assert Method.from_string('Initialize') == .unknown
	assert Method.from_string('INITIALIZE') == .unknown
	assert Method.from_string('textDocument/DidOpen') == .unknown
	assert Method.from_string('textdocument/didopen') == .unknown
}

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
	encoded := json2.encode(pos, escape_unicode: true)
	assert encoded.contains('"line":10')
	assert encoded.contains('"character":5')
}

fn test_position_json_decoding() {
	json_str := '{"line":20,"character":8}'
	pos := json2.decode[Position](json_str) or {
		assert false, 'Failed to decode Position: ${err}'
		return
	}
	assert pos.line == 20
	assert pos.char == 8
}

fn test_make_cancelled_error_response_fields() {
	err := make_cancelled_error_response(42)
	assert err.id == 42
	assert err.error.code == jsonrpc_err_request_cancelled
	assert err.error.message == 'Request cancelled'
}

fn test_error_response_json_encoding() {
	err := make_cancelled_error_response(7)
	encoded := json2.encode(err, escape_unicode: true)
	assert encoded.contains('"id":7')
	assert encoded.contains('"code":-32800')
	assert encoded.contains('"message":"Request cancelled"')
}

fn test_make_parse_error_response_fields() {
	err := make_parse_error_response('bad json')
	assert err.id == 0
	assert err.error.code == jsonrpc_err_parse_error
	assert err.error.message == 'bad json'
}

fn test_make_server_not_initialized_error_response_fields() {
	err := make_server_not_initialized_error_response(7)
	assert err.id == 7
	assert err.error.code == jsonrpc_err_server_not_initialized
	assert err.error.message == 'Server not yet initialized'
}

fn test_make_server_already_initialized_error_response_fields() {
	err := make_server_already_initialized_error_response(8)
	assert err.id == 8
	assert err.error.code == jsonrpc_err_invalid_request
	assert err.error.message == 'Server already initialized'
}

fn test_make_server_shutdown_error_response_fields() {
	err := make_server_shutdown_error_response(10)
	assert err.id == 10
	assert err.error.code == jsonrpc_err_invalid_request
	assert err.error.message == 'Server has been shut down'
}

fn test_make_method_not_found_error_response_fields() {
	err := make_method_not_found_error_response(9, 'workspace/unknown')
	assert err.id == 9
	assert err.error.code == jsonrpc_err_method_not_found
	assert err.error.message.contains('Method not found')
}

fn test_make_internal_error_response_fields() {
	err := make_internal_error_response(13, 'boom')
	assert err.id == 13
	assert err.error.code == jsonrpc_err_internal_error
	assert err.error.message == 'boom'
}

fn test_request_content_has_id_detects_presence() {
	assert request_content_has_id('{"id":1,"method":"initialize"}')
	assert !request_content_has_id('{"method":"initialized"}')
}

fn test_request_content_has_id_ignores_nested_id_in_params() {
	assert !request_content_has_id('{"method":"$/cancelRequest","params":{"id":77}}')
}

fn test_request_content_has_id_fallback_for_malformed_payload() {
	assert request_content_has_id('{"id":1,"method":"initialize"')
}

fn test_make_invalid_params_error_response_fields() {
	err := make_invalid_params_error_response(11, 'bad params')
	assert err.id == 11
	assert err.error.code == jsonrpc_err_invalid_params
	assert err.error.message == 'bad params'
}

fn test_validate_request_params_reports_missing_uri() {
	err := validate_request_params(.completion, '{"position":{"line":0,"character":0}}')
	assert err != none
}

fn test_validate_request_params_accepts_valid_completion_params() {
	err := validate_request_params(.completion,
		'{"textDocument":{"uri":"file:///tmp/a.v"},"position":{"line":0,"character":0}}')
	assert err == none
}

fn test_validate_request_params_initialize_accepts_position_encodings_list() {
	err := validate_request_params(.initialize,
		'{"capabilities":{"general":{"positionEncodings":["utf-16"]}}}')
	assert err == none
}

fn test_validate_request_params_initialize_accepts_multiple_position_encodings() {
	err := validate_request_params(.initialize,
		'{"capabilities":{"general":{"positionEncodings":["utf-16","utf-32"]}}}')
	assert err == none
}

fn test_validate_request_params_initialize_accepts_workspace_folders_with_uri() {
	err := validate_request_params(.initialize,
		'{"workspaceFolders":[{"uri":"file:///tmp/project","name":"project"}]}')
	assert err == none
}

fn test_validate_request_params_initialize_rejects_workspace_folders_without_uri() {
	err := validate_request_params(.initialize, '{"workspaceFolders":[{"name":"project"}]}')
	assert err != none
	err_msg := err or { '' }
	assert err_msg.contains('workspaceFolders')
}

fn test_validate_request_params_reports_missing_call_hierarchy_item_uri() {
	err_in := validate_request_params(.callhierarchy_incoming, '{"item":{"name":"foo","kind":12}}')
	assert err_in != none
	err_out := validate_request_params(.callhierarchy_outgoing, '{"item":{"name":"foo","kind":12}}')
	assert err_out != none
}

fn test_validate_request_params_accepts_valid_call_hierarchy_item_uri() {
	err := validate_request_params(.callhierarchy_incoming,
		'{"item":{"name":"foo","kind":12,"uri":"file:///tmp/a.v","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"detail":""}}')
	assert err == none
}

fn test_validate_request_params_reports_invalid_rename_new_name() {
	err_empty := validate_request_params(.rename,
		'{"textDocument":{"uri":"file:///tmp/a.v"},"position":{"line":0,"character":0},"newName":""}')
	assert err_empty != none
	err_bad := validate_request_params(.rename,
		'{"textDocument":{"uri":"file:///tmp/a.v"},"position":{"line":0,"character":0},"newName":"1 bad"}')
	assert err_bad != none
}

fn test_validate_request_params_accepts_valid_rename_new_name() {
	err := validate_request_params(.rename,
		'{"textDocument":{"uri":"file:///tmp/a.v"},"position":{"line":0,"character":0},"newName":"new_name1"}')
	assert err == none
}

fn test_validate_notification_params_reports_missing_uri_for_did_open() {
	err := validate_notification_params(.did_open, '{"textDocument":{}}')
	assert err != none
}

fn test_validate_notification_params_accepts_valid_did_open() {
	err := validate_notification_params(.did_open,
		'{"textDocument":{"uri":"file:///tmp/a.v","text":"module main"}}')
	assert err == none
}

fn test_validate_notification_params_accepts_workspace_configuration() {
	err := validate_notification_params(.workspace_did_change_configuration,
		'{"settings":{"vls":{"inlayHints":true}}}')
	assert err == none
}

fn test_validate_notification_params_reports_missing_watched_file_uri() {
	err := validate_notification_params(.did_change_watched_files, '{"changes":[{"type":1}]}')
	assert err != none
}

fn test_validate_notification_params_accepts_valid_watched_file_uri() {
	err := validate_notification_params(.did_change_watched_files,
		'{"changes":[{"uri":"file:///tmp/a.v","type":2}]}')
	assert err == none
}

fn test_encode_error_response_payload_parse_error_uses_null_id() {
	err := make_parse_error_response('bad json')
	encoded := encode_error_response_payload(err)
	assert encoded.contains('"code":-32700')
	assert encoded.contains('"id":null')
	assert !encoded.contains('"id":0')
}

fn test_encode_error_response_payload_non_parse_keeps_id() {
	err := make_invalid_params_error_response(12, 'bad params')
	encoded := encode_error_response_payload(err)
	assert encoded.contains('"id":12')
	assert encoded.contains('"code":-32602')
}

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
	encoded := json2.encode(r, escape_unicode: true)
	assert encoded.contains('"start"')
	assert encoded.contains('"end"')
}

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
	encoded := json2.encode(doc, escape_unicode: true)
	assert encoded.contains('"uri":"file:///path/to/file.v"')
}

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
	params := json2.decode[Params](json_str) or {
		assert false, 'Failed to decode Params: ${err}'
		return
	}
	assert params.text_document.uri == 'file:///test.v'
	assert params.position.line == 5
	assert params.position.char == 10
}

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
	req := json2.decode[Request](json_str) or {
		assert false, 'Failed to decode Request: \\${err}'
		return
	}
	assert req.id == 1
	assert req.method == 'textDocument/completion'
	params := json2.decode[Params](req.params.str()) or {
		assert false, 'Failed to decode Params: \\${err}'
		return
	}
	assert params.position.line == 5
}

fn test_request_json_decoding_did_change() {
	json_str := '{"id":2,"method":"textDocument/didChange","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"contentChanges":[{"text":"fn main() {}"}]}}'
	req := json2.decode[Request](json_str) or {
		assert false, 'Failed to decode Request: \\${err}'
		return
	}
	assert req.method == 'textDocument/didChange'
	params := json2.decode[Params](req.params.str()) or {
		assert false, 'Failed to decode Params: \\${err}'
		return
	}
	assert params.content_changes.len == 1
	assert params.content_changes[0].text == 'fn main() {}'
}

fn test_request_json_decoding_initialize() {
	json_str := '{"id":0,"method":"initialize","jsonrpc":"2.0","params":{}}'
	req := json2.decode[Request](json_str) or {
		assert false, 'Failed to decode Request: ${err}'
		return
	}
	assert req.id == 0
	assert req.method == 'initialize'
}

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
	encoded := json2.encode(resp, escape_unicode: true)
	assert encoded.contains('"id":42')
	assert encoded.contains('"jsonrpc":"2.0"')
}

fn test_encode_response_payload_uses_json_null_for_null_result() {
	resp := Response{
		id:     2
		result: 'null'
	}
	encoded := encode_response_payload(resp)
	assert encoded.contains('"result":null')
	assert !encoded.contains('"result":"null"')
}

fn test_encode_response_payload_preserves_non_null_results() {
	resp := Response{
		id:     3
		result: []TextEdit{}
	}
	encoded := encode_response_payload(resp)
	assert encoded.contains('"result":[]')
}

fn test_encode_response_payload_strips_sum_type_tag_from_capabilities() {
	resp := Response{
		id:     4
		result: Capabilities{
			capabilities: Capability{
				definition_provider: true
			}
		}
	}
	encoded := encode_response_payload(resp)
	assert encoded.contains('"definitionProvider":true')
	assert !encoded.contains('"_type"')
}

fn test_encode_response_payload_strips_sum_type_tag_from_prepare_rename() {
	resp := Response{
		id:     5
		result: PrepareRenameResult{
			range:       LSPRange{
				start: Position{
					line: 1
					char: 2
				}
				end:   Position{
					line: 1
					char: 7
				}
			}
			placeholder: 'value'
		}
	}
	encoded := encode_response_payload(resp)
	assert encoded.contains('"placeholder":"value"')
	assert !encoded.contains('"_type"')
}

fn test_read_request_accepts_lowercase_content_length_header() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	framed := 'content-length: ${payload.len}\r\n\r\n${payload}'
	tmp := os.join_path(os.temp_dir(), 'vls_read_request_header_case_${os.getpid()}.txt')
	os.write_file(tmp, framed) or {
		assert false, 'Failed to write temp request file: ${err}'
		return
	}
	defer {
		os.rm(tmp) or {}
	}
	mut f := os.open(tmp) or {
		assert false, 'Failed to open temp request file: ${err}'
		return
	}
	defer {
		f.close()
	}
	mut reader := io.new_buffered_reader(reader: f, cap: 1)
	decoded := read_request(mut reader) or {
		assert false, 'read_request failed: ${err}'
		return
	}
	assert decoded == payload
}

fn test_parse_content_length_header_rejects_non_numeric() {
	parse_content_length_header('12x') or {
		assert err.msg().contains('non-numeric')
		return
	}
	assert false, 'expected parse_content_length_header to fail for non-numeric input'
}

fn test_read_request_rejects_non_utf8_charset_header() {
	// LSP content is always UTF-8; a declared utf-16 charset must be rejected
	// rather than silently misdecoded (P0-11).
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	framed := 'Content-Length: ${payload.len}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-16\r\n\r\n${payload}'
	tmp := os.join_path(os.temp_dir(), 'vls_read_request_non_utf8_charset_${os.getpid()}.txt')
	os.write_file(tmp, framed) or {
		assert false, 'Failed to write temp request file: ${err}'
		return
	}
	defer {
		os.rm(tmp) or {}
	}
	mut f := os.open(tmp) or {
		assert false, 'Failed to open temp request file: ${err}'
		return
	}
	defer {
		f.close()
	}
	mut reader := io.new_buffered_reader(reader: f, cap: 1)
	if _ := read_request(mut reader) {
		assert false, 'expected read_request to reject non-UTF-8 charset'
	} else {
		assert err.msg().starts_with('invalid header:')
		assert err.msg().contains('charset')
	}
}

fn test_read_request_accepts_utf8_charset_header() {
	// An explicit UTF-8 charset is fine and must not be rejected.
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	framed := 'Content-Length: ${payload.len}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n${payload}'
	tmp := os.join_path(os.temp_dir(), 'vls_read_request_utf8_charset_${os.getpid()}.txt')
	os.write_file(tmp, framed) or {
		assert false, 'Failed to write temp request file: ${err}'
		return
	}
	defer {
		os.rm(tmp) or {}
	}
	mut f := os.open(tmp) or {
		assert false, 'Failed to open temp request file: ${err}'
		return
	}
	defer {
		f.close()
	}
	mut reader := io.new_buffered_reader(reader: f, cap: 1)
	decoded := read_request(mut reader) or {
		assert false, 'read_request failed: ${err}'
		return
	}
	assert decoded == payload
}

fn test_read_request_rejects_oversized_content_length() {
	// A huge Content-Length must be refused before allocating (P0-11).
	framed := 'Content-Length: 999999999999\r\n\r\n'
	tmp := os.join_path(os.temp_dir(), 'vls_read_request_oversized_${os.getpid()}.txt')
	os.write_file(tmp, framed) or {
		assert false, 'Failed to write temp request file: ${err}'
		return
	}
	defer {
		os.rm(tmp) or {}
	}
	mut f := os.open(tmp) or {
		assert false, 'Failed to open temp request file: ${err}'
		return
	}
	defer {
		f.close()
	}
	mut reader := io.new_buffered_reader(reader: f, cap: 1)
	if _ := read_request(mut reader) {
		assert false, 'expected read_request to reject oversized Content-Length'
	} else {
		assert err.msg().starts_with('invalid header:')
	}
}

fn test_read_request_rejects_conflicting_content_length_headers() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	framed := 'Content-Length: ${payload.len}\r\nContent-Length: ${payload.len + 1}\r\n\r\n${payload}'
	tmp := os.join_path(os.temp_dir(), 'vls_read_request_conflict_len_${os.getpid()}.txt')
	os.write_file(tmp, framed) or {
		assert false, 'Failed to write temp request file: ${err}'
		return
	}
	defer {
		os.rm(tmp) or {}
	}
	mut f := os.open(tmp) or {
		assert false, 'Failed to open temp request file: ${err}'
		return
	}
	defer {
		f.close()
	}
	mut reader := io.new_buffered_reader(reader: f, cap: 1)
	read_request(mut reader) or {
		assert err.msg().contains('conflicting Content-Length')
		return
	}
	assert false, 'Expected read_request to reject conflicting Content-Length headers'
}

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
	encoded := json2.encode(notif, escape_unicode: true)
	assert encoded.contains('"method":"textDocument/publishDiagnostics"')
	assert encoded.contains('"jsonrpc":"2.0"')
}

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
	encoded := json2.encode(diag, escape_unicode: true)
	assert encoded.contains('"message":"undefined identifier"')
	assert encoded.contains('"severity":1')
}

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
	encoded := json2.encode(detail, escape_unicode: true)
	assert encoded.contains('"kind":6')
	assert encoded.contains('"label":"test_fn"')
}

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
	encoded := json2.encode(loc, escape_unicode: true)
	assert encoded.contains('"uri":"file:///path/to/file.v"')
	assert encoded.contains('"range"')
}

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
	encoded := json2.encode(sig, escape_unicode: true)
	assert encoded.contains('"activeSignature":0')
	assert encoded.contains('"activeParameter":0')
}

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
	encoded := json2.encode(caps, escape_unicode: true)
	assert encoded.contains('"definitionProvider":true')
}

fn test_completion_provider_trigger_characters() {
	provider := CompletionProvider{
		trigger_characters: ['.', ':', '@']
	}
	assert provider.trigger_characters.len == 3
	assert '.' in provider.trigger_characters
}

fn test_completion_item_capability_snippet_support() {
	cap := CompletionItemCapability{
		snippet_support: true
	}
	assert cap.snippet_support == true
}

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

fn test_signature_help_options() {
	opts := SignatureHelpOptions{
		trigger_characters: ['(', ',', '<']
	}
	assert opts.trigger_characters.len == 3
	assert '(' in opts.trigger_characters
}

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
	err := json2.decode[JsonError](json_str) or {
		assert false, 'Failed to decode JsonError: ${err}'
		return
	}
	assert err.path == '/test/file.v'
	assert err.line_nr == 5
}

fn test_json_error_array_decoding() {
	json_str := '[{"path":"/a.v","message":"err1","line_nr":1,"col":1,"len":1},{"path":"/b.v","message":"err2","line_nr":2,"col":2,"len":2}]'
	errors := json2.decode[[]JsonError](json_str) or {
		assert false, 'Failed to decode JsonError array: ${err}'
		return
	}
	assert errors.len == 2
	assert errors[0].path == '/a.v'
	assert errors[1].path == '/b.v'
}

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
	ac := json2.decode[JsonVarAC](json_str) or {
		assert false, 'Failed to decode JsonVarAC: ${err}'
		return
	}
	assert ac.details.len == 1
	assert ac.details[0].label == 'test'
}

// ============================================================================
// Tests for DocumentSymbol and sym_kind_* constants
// ============================================================================

fn test_document_symbol_default_values() {
	sym := DocumentSymbol{}
	assert sym.name == ''
	assert sym.kind == 0
	assert sym.children.len == 0
}

fn test_document_symbol_with_values() {
	sym := DocumentSymbol{
		name:            'greet'
		kind:            sym_kind_function
		range:           LSPRange{
			start: Position{
				line: 2
				char: 0
			}
			end:   Position{
				line: 2
				char: 20
			}
		}
		selection_range: LSPRange{
			start: Position{
				line: 2
				char: 3
			}
			end:   Position{
				line: 2
				char: 8
			}
		}
		children:        []DocumentSymbol{}
	}
	assert sym.name == 'greet'
	assert sym.kind == sym_kind_function
	assert sym.range.start.line == 2
	assert sym.selection_range.start.char == 3
}

fn test_document_symbol_json_encoding() {
	sym := DocumentSymbol{
		name:            'Person'
		kind:            sym_kind_struct
		range:           LSPRange{
			start: Position{
				line: 5
				char: 0
			}
			end:   Position{
				line: 5
				char: 14
			}
		}
		selection_range: LSPRange{
			start: Position{
				line: 5
				char: 7
			}
			end:   Position{
				line: 5
				char: 13
			}
		}
		children:        []DocumentSymbol{}
	}
	encoded := json2.encode(sym, escape_unicode: true)
	assert encoded.contains('"name":"Person"')
	assert encoded.contains('"kind":${sym_kind_struct}')
	assert encoded.contains('"selectionRange"')
	assert encoded.contains('"children"')
}

fn test_document_symbol_json_decoding() {
	json_str := '{"name":"Color","kind":10,"range":{"start":{"line":8,"character":0},"end":{"line":8,"character":11}},"selectionRange":{"start":{"line":8,"character":5},"end":{"line":8,"character":10}},"children":[]}'
	sym := json2.decode[DocumentSymbol](json_str) or {
		assert false, 'Failed to decode DocumentSymbol: ${err}'
		return
	}
	assert sym.name == 'Color'
	assert sym.kind == sym_kind_enum
	assert sym.range.start.line == 8
	assert sym.selection_range.start.char == 5
}

fn test_document_symbol_with_children() {
	sym := DocumentSymbol{
		name:            'App'
		kind:            sym_kind_struct
		range:           LSPRange{}
		selection_range: LSPRange{}
		children:        [
			DocumentSymbol{
				name:            'run'
				kind:            sym_kind_method
				range:           LSPRange{}
				selection_range: LSPRange{}
				children:        []DocumentSymbol{}
			},
		]
	}
	assert sym.children.len == 1
	assert sym.children[0].name == 'run'
	assert sym.children[0].kind == sym_kind_method
}

fn test_sym_kind_constants_values() {
	// Symbol kinds currently used by vls
	assert sym_kind_class == 5
	assert sym_kind_method == 6
	assert sym_kind_field == 8
	assert sym_kind_enum == 10
	assert sym_kind_interface == 11
	assert sym_kind_function == 12
	assert sym_kind_constant == 14
	assert sym_kind_enum_member == 22
	assert sym_kind_struct == 23
}

fn test_sym_kind_constants_are_distinct() {
	kinds := [
		sym_kind_class,
		sym_kind_method,
		sym_kind_field,
		sym_kind_enum,
		sym_kind_interface,
		sym_kind_function,
		sym_kind_constant,
		sym_kind_enum_member,
		sym_kind_struct,
	]
	// Check no two constants are the same value
	mut seen := map[int]bool{}
	for k in kinds {
		assert k !in seen, 'sym_kind constant ${k} is duplicated'
		seen[k] = true
	}
}

fn test_method_from_string_document_symbols() {
	assert Method.from_string('textDocument/documentSymbol') == .document_symbols
}

fn test_method_str_document_symbols() {
	assert Method.document_symbols.str() == 'textDocument/documentSymbol'
}

fn test_method_roundtrip_document_symbols() {
	m := Method.document_symbols
	assert Method.from_string(m.str()) == m
}

fn test_method_from_string_unsupported_methods_updated() {
	// textDocument/documentSymbol is now supported – it must NOT be unknown
	assert Method.from_string('textDocument/documentSymbol') != .unknown
	assert Method.from_string('workspace/symbol') == .workspace_symbol
	// 'textDocument/codeAction' is now supported
	assert Method.from_string('textDocument/codeAction') == .code_action
}

fn test_method_roundtrip_new_methods() {
	methods := [
		Method.workspace_symbol,
		Method.prepare_rename,
		Method.declaration,
		Method.type_definition,
		Method.implementation,
		Method.did_close,
		Method.did_save,
	]
	for m in methods {
		assert Method.from_string(m.str()) == m
	}
}

fn test_response_result_workspace_symbols() {
	result := ResponseResult([
		WorkspaceSymbol{
			name:     'main'
			kind:     sym_kind_function
			location: Location{
				uri:   'file:///tmp/main.v'
				range: LSPRange{}
			}
		},
	])
	if result is []WorkspaceSymbol {
		assert result.len == 1
		assert result[0].name == 'main'
	} else {
		assert false, 'Expected []WorkspaceSymbol result'
	}
}

fn test_response_result_prepare_rename_result() {
	result := ResponseResult(PrepareRenameResult{
		range:       LSPRange{
			start: Position{
				line: 1
				char: 2
			}
			end:   Position{
				line: 1
				char: 5
			}
		}
		placeholder: 'foo'
	})
	if result is PrepareRenameResult {
		assert result.placeholder == 'foo'
		assert result.range.start.line == 1
		assert result.range.end.char == 5
	} else {
		assert false, 'Expected PrepareRenameResult result'
	}
}

fn test_response_result_document_symbols_empty() {
	result := ResponseResult([]DocumentSymbol{})
	if result is []DocumentSymbol {
		assert result.len == 0
	} else {
		assert false, 'Expected []DocumentSymbol result'
	}
}

fn test_response_result_document_symbols_with_data() {
	syms := [
		DocumentSymbol{
			name:            'main'
			kind:            sym_kind_function
			range:           LSPRange{}
			selection_range: LSPRange{}
			children:        []DocumentSymbol{}
		},
		DocumentSymbol{
			name:            'App'
			kind:            sym_kind_struct
			range:           LSPRange{}
			selection_range: LSPRange{}
			children:        []DocumentSymbol{}
		},
	]
	result := ResponseResult(syms)
	if result is []DocumentSymbol {
		assert result.len == 2
		assert result[0].name == 'main'
		assert result[0].kind == sym_kind_function
		assert result[1].name == 'App'
		assert result[1].kind == sym_kind_struct
	} else {
		assert false, 'Expected []DocumentSymbol result'
	}
}

fn test_response_with_document_symbols_json_encoding() {
	syms := [
		DocumentSymbol{
			name:            'greet'
			kind:            sym_kind_function
			range:           LSPRange{
				start: Position{
					line: 2
					char: 0
				}
				end:   Position{
					line: 2
					char: 25
				}
			}
			selection_range: LSPRange{
				start: Position{
					line: 2
					char: 3
				}
				end:   Position{
					line: 2
					char: 8
				}
			}
			children:        []DocumentSymbol{}
		},
	]
	resp := Response{
		id:     7
		result: syms
	}
	encoded := json2.encode(resp, escape_unicode: true)
	assert encoded.contains('"id":7')
	assert encoded.contains('"name":"greet"')
	assert encoded.contains('"kind":${sym_kind_function}')
	assert encoded.contains('"selectionRange"')
}

fn test_capability_document_symbol_provider_true() {
	cap := Capability{
		document_symbol_provider: true
	}
	assert cap.document_symbol_provider == true
}

fn test_capability_document_symbol_provider_false_by_default() {
	cap := Capability{}
	assert cap.document_symbol_provider == false
}

fn test_capability_document_symbol_provider_json_encoding() {
	caps := Capabilities{
		capabilities: Capability{
			document_symbol_provider: true
			definition_provider:      true
		}
	}
	encoded := json2.encode(caps, escape_unicode: true)
	assert encoded.contains('"documentSymbolProvider":true')
	assert encoded.contains('"definitionProvider":true')
}

fn test_capability_code_lens_provider_json_encoding_object_shape() {
	caps := Capabilities{
		capabilities: Capability{
			code_lens_provider: CodeLensOptions{}
		}
	}
	encoded := json2.encode(caps, escape_unicode: true)
	assert encoded.contains('"codeLensProvider":{}')
	assert !encoded.contains('"codeLensProvider":true')
}

// --- P0-02 / P0-03: JSON-RPC envelope, string ids, direction ---

fn test_extract_raw_id_numeric() {
	id := extract_raw_id('{"id":5,"method":"x"}') or {
		assert false, 'expected id'
		return
	}
	assert id == '5'
}

fn test_extract_raw_id_string_preserves_quotes() {
	id := extract_raw_id('{"jsonrpc":"2.0","id":"abc-1","method":"x"}') or {
		assert false, 'expected id'
		return
	}
	assert id == '"abc-1"'
}

fn test_extract_raw_id_present_null_is_literal() {
	// A present null id is a request with a null id (JSON-RPC permits it), not a
	// notification: it must be distinguished from an absent id.
	id := extract_raw_id('{"id":null,"method":"x"}') or {
		assert false, 'present null id must not be none'
		return
	}
	assert id == 'null'
	assert raw_id_is_valid(id)
	assert request_content_has_id('{"id":null,"method":"x"}')
}

fn test_extract_raw_id_ignores_nested_id() {
	// An "id" inside params must not be mistaken for the top-level id.
	id := extract_raw_id('{"method":"x","params":{"id":99},"id":7}') or {
		assert false, 'expected id'
		return
	}
	assert id == '7'
}

fn test_extract_raw_id_absent_is_none() {
	assert extract_raw_id('{"method":"x","params":{}}') == none
}

fn test_raw_id_is_valid_accepts_strings_and_numbers() {
	assert raw_id_is_valid('') // absent/null id
	assert raw_id_is_valid('5')
	assert raw_id_is_valid('-3')
	assert raw_id_is_valid('"abc-1"')
}

fn test_raw_id_is_valid_rejects_other_types() {
	// Booleans, objects, and arrays are not legal JSON-RPC ids.
	assert !raw_id_is_valid('true')
	assert !raw_id_is_valid('false')
	assert !raw_id_is_valid('{}')
	assert !raw_id_is_valid('{"a":1}')
	assert !raw_id_is_valid('[]')
	assert !raw_id_is_valid('[1,2]')
	// extract_raw_id returns these exact tokens, so the pair rejects the request.
	bad := extract_raw_id('{"id":true,"method":"x"}') or {
		assert false, 'expected raw id token'
		return
	}
	assert bad == 'true'
	assert !raw_id_is_valid(bad)
}

fn test_is_client_response_message_detection() {
	assert is_client_response_message('{"jsonrpc":"2.0","id":2,"result":null}')
	assert is_client_response_message('{"jsonrpc":"2.0","id":2,"error":{"code":-1,"message":"x"}}')
	assert !is_client_response_message('{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}')
	assert !is_client_response_message('{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{}}')
}

fn test_inject_raw_id_restores_string_id() {
	assert inject_raw_id('{"id":0,"result":null,"jsonrpc":"2.0"}', '"abc"') == '{"id":"abc","result":null,"jsonrpc":"2.0"}'
}

fn test_inject_raw_id_numeric_is_noop() {
	assert inject_raw_id('{"id":5,"result":null}', '5') == '{"id":5,"result":null}'
}

fn test_method_is_notification_only_contract() {
	assert method_is_notification_only(.did_open)
	assert method_is_notification_only(.did_change)
	assert method_is_notification_only(.cancel_request)
	assert !method_is_notification_only(.completion)
	assert !method_is_notification_only(.shutdown)
	// exit is excluded so the shutdown/exit lifecycle stays robust.
	assert !method_is_notification_only(.exit)
}

fn test_encode_response_payload_strips_type_from_array_variant() {
	// Array-of-struct result variants (e.g. []WorkspaceSymbol) must also have
	// their per-element `_type` discriminators stripped (P1-10).
	resp := Response{
		id:     9
		result: [
			WorkspaceSymbol{
				name:     'helper_fn'
				kind:     sym_kind_function
				location: Location{
					uri:   'file:///tmp/lib.v'
					range: LSPRange{}
				}
			},
		]
	}
	encoded := encode_response_payload(resp)
	assert encoded.contains('"name":"helper_fn"')
	assert !encoded.contains('"_type"')
}

fn test_strip_sum_type_tags_handles_multiple_and_positions() {
	// Tag as last member, first member, and only member.
	assert strip_response_sum_type_tags('{"a":1,"_type":"X"}') == '{"a":1}'
	assert strip_response_sum_type_tags('{"_type":"X","a":1}') == '{"a":1}'
	assert strip_response_sum_type_tags('{"_type":"X"}') == '{}'
	assert strip_response_sum_type_tags('[{"a":1,"_type":"X"},{"b":2,"_type":"Y"}]') == '[{"a":1},{"b":2}]'
	// No tag: unchanged.
	assert strip_response_sum_type_tags('{"a":1}') == '{"a":1}'
}

fn test_validate_rename_rejects_keyword_new_name() {
	// Renaming to a V keyword must be rejected (uncompilable result).
	params := '{"textDocument":{"uri":"file:///a.v"},"position":{"line":0,"character":0},"newName":"fn"}'
	if err := validate_request_params(.rename, params) {
		assert err.contains('reserved')
	} else {
		assert false, 'expected keyword newName to be rejected'
	}
}

fn test_validate_rename_accepts_normal_new_name() {
	params := '{"textDocument":{"uri":"file:///a.v"},"position":{"line":0,"character":0},"newName":"my_fn"}'
	assert validate_request_params(.rename, params) == none
}
