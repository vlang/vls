// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json
import net
import os
import time
import v.pref
import io

// App represents the context of the server during its lifetime.
pub struct App {
	cur_mod string = 'main'
	exit    bool   = os.args.contains('exit')
mut:
	text                                        string            // Current file content
	open_files                                  map[string]string // Map of file URI to file content
	open_files_versions                         map[string]int    // Per-URI document version from the client
	temp_dir                                    string            // Temporary directory for multi-file compilation
	workspace_roots                             []string          // Workspace root directories from initialize
	capture_output                              bool              // Test hook: capture outbound transport messages instead of writing
	captured_output                             []string          // Test hook buffer for outbound transport messages
	supports_dynamic_watched_files_registration bool              // Client supports dynamic workspace watcher registration
	supports_work_done_progress                 bool              // Client supports window/workDoneProgress + $/progress
	sent_watched_files_registration             bool              // client/registerCapability watcher registration was sent
	inlay_hints_enabled                         bool = true // toggled via workspace/didChangeConfiguration
	diagnostics_enabled                         bool = true // toggled via workspace/didChangeConfiguration
	diag_cache                                  map[string]DiagCacheEntry // Per-URI cached diagnostics
	open_files_generation                       int                       // Incremented on every workspace file mutation
	cancelled_requests                          map[int]bool              // Request ids cancelled via $/cancelRequest
	tcp_conn                                    ?&net.TcpConn             // Non-nil when serving a TCP client
	is_shutdown                                 bool                      // True after shutdown request was acknowledged
	exit_was_requested                          bool                      // True when the exit notification was received
	received_initialize                         bool                      // True after initialize request was processed
	next_request_id                             int = 1 // Counter for server-initiated request ids
}

struct JsonError {
	path    string
	message string
	line_nr int
	col     int
	len     int
	level   string // 'error', 'warning', 'notice', or '' — populated by the V compiler
}

struct JsonVarAC {
	details []Detail
}

struct RequestIdEnvelope {
	id ?int
}

// DiagCacheEntry stores a cached diagnostic result for one file.
struct DiagCacheEntry {
	content_hash int
	generation   int
	errors       []JsonError
}

const v_prefs = pref.Preferences{
	is_vls: true
}

// v_dir is the path to the V home directory, derived from the V compiler executable.
// It is resolved once at process start and never changes.
const v_dir = find_v_dir()

// find_v_dir resolves the V home directory by finding the V executable and
// returning its parent directory.
fn find_v_dir() string {
	v_exe := os.find_abs_path_of_executable('v') or { return '' }
	return os.dir(os.real_path(v_exe))
}

fn log(s string) {
	eprintln(s)
	temp_dir := os.temp_dir()
	mut output := os.open_append(os.join_path(temp_dir, 'vls_out.txt')) or { return }
	output.writeln(s) or {
		output.close()
		return
	}
	output.close()
}

fn main() {
	log('VLS started. Reading from stdin...')
	log('VLS preferences: is_vls=${v_prefs.is_vls}')

	// Check for --port PORT argument to start as a TCP multi-client server.
	args := os.args
	mut port := ''
	for i, arg in args {
		if arg == '--port' && i + 1 < args.len {
			port = args[i + 1]
			break
		}
	}
	if port != '' {
		run_tcp_server(port)
		return
	}

	// Stdio mode (default).
	temp_dir := os.join_path(os.temp_dir(), 'vls_${os.getpid()}')
	os.mkdir_all(temp_dir) or {
		eprintln('Failed to create temp directory: ${err}')
		return
	}
	mut app := &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
	mut reader := io.new_buffered_reader(reader: os.stdin(), cap: 1)
	app.handle_requests(mut reader)
	log('VLS exiting.')
	os.rmdir_all(temp_dir) or {
		$if debug { log('Failed to clean up temp directory: ${err}') }
	}
	// LSP spec §3.5: exit after proper shutdown → 0; exit without shutdown → 1.
	if app.exit_was_requested && !app.is_shutdown {
		exit(1)
	}
}

// run_tcp_server listens on the given TCP port and spawns a goroutine for each
// incoming client connection.  Each client gets its own App instance so all
// state is fully isolated.
fn run_tcp_server(port string) {
	log('VLS TCP server starting on :${port}...')
	mut listener := net.listen_tcp(.ip, ':${port}') or {
		log('Failed to start TCP listener on port ${port}: ${err}')
		return
	}
	log('VLS TCP server listening on :${port}')
	for {
		mut conn := listener.accept() or {
			log('TCP accept error: ${err}')
			continue
		}
		spawn handle_tcp_client(mut conn)
	}
}

// handle_tcp_client creates a fresh App instance for the newly accepted TCP
// connection and drives the LSP request loop until the client disconnects.
fn handle_tcp_client(mut conn net.TcpConn) {
	log('New TCP client connected')
	temp_dir := os.join_path(os.temp_dir(), 'vls_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or {
		log('Failed to create temp directory for TCP client: ${err}')
		conn.close() or {}
		return
	}
	mut app := &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
		tcp_conn:   &conn
	}
	mut reader := io.new_buffered_reader(reader: conn, cap: 1)
	app.handle_requests(mut reader)
	log('TCP client disconnected')
	os.rmdir_all(temp_dir) or {
		$if debug { log('Failed to clean up TCP client temp directory: ${err}') }
	}
	conn.close() or {}
}

// write_data sends raw data to the client — either via the TCP connection when
// in multi-client mode, or to stdout in stdio mode.
fn (mut app App) write_data(data string) {
	if app.capture_output {
		app.captured_output << data
		return
	}
	if mut conn := app.tcp_conn {
		conn.write_string(data) or { log('TCP write error: ${err}') }
	} else {
		print(data)
		flush_stdout()
	}
}

fn read_request(mut reader io.BufferedReader) !string {
	mut len := -1
	mut header_error := ''
	for {
		line := reader.read_line() or {
			if err is io.Eof {
				return err
			}
			$if debug { log('read_request: error reading header line: ${err}') }
			return err
		}
		trimmed_line := line.trim_space()
		if trimmed_line == '' {
			break
		}
		log('line=${line}')
		lower := trimmed_line.to_lower()
		if lower.starts_with('content-length:') {
			len_str := trimmed_line.all_after(':').trim_space()
			parsed_len := parse_content_length_header(len_str) or {
				header_error = 'invalid header: invalid Content-Length'
				continue
			}
			if len != -1 && len != parsed_len {
				header_error = 'invalid header: conflicting Content-Length headers'
				continue
			}
			len = parsed_len
			continue
		}
	}
	if len < 0 {
		return ''
	}
	mut buf := []u8{len: len}
	mut total_bytes_read := 0
	for total_bytes_read < len {
		bytes_read_now := reader.read(mut buf[total_bytes_read..]) or {
			log('read_request: error reading content body: ${err}')
			return err
		}
		if bytes_read_now == 0 && total_bytes_read < len {
			log('read_request: got EOF before reading full content body.')
			return io.Eof{}
		}
		total_bytes_read += bytes_read_now
	}
	if header_error != '' {
		return error(header_error)
	}
	return buf.bytestr()
}

fn parse_content_length_header(s string) !int {
	t := s.trim_space()
	if t == '' {
		return error('empty Content-Length')
	}
	for ch in t {
		if ch < `0` || ch > `9` {
			return error('non-numeric Content-Length')
		}
	}
	n := t.int()
	if n < 0 {
		return error('negative Content-Length')
	}
	return n
}

// handle_requests is the main request handler loop for both stdio and TCP modes.
fn (mut app App) handle_requests(mut reader io.BufferedReader) {
	for {
		content := read_request(mut reader) or {
			if err is io.Eof {
				log('Client closed connection. Exiting.')
				break
			}
			if err.msg().starts_with('invalid header:') {
				app.write_error_response(make_parse_error_response(err.msg()))
				continue
			}
			$if debug { log('Error reading request: ${err.msg()}') }
			break
		}
		if content.len == 0 {
			continue
		}
		log('\n\nRECV: ${content}')
		has_id := request_content_has_id(content)
		request := json.decode(Request, content) or {
			log('Failed to decode JSON request: ${err.msg()}. Content: "${content}"')
			app.write_error_response(make_parse_error_response(err.msg()))
			continue
		}
		pretty := json.encode_pretty(request)
		log('\n\nRECV (pretty): ${pretty}')
		method := Method.from_string(request.method)
		log('method="${method}" request.method="${request.method}" ${method == .completion}')
		if method_requires_response(method) && request.id in app.cancelled_requests {
			app.write_error_response(make_cancelled_error_response(request.id))
			app.consume_cancelled_request(request.id)
			continue
		}
		// After shutdown, reject all requests except exit.
		if app.is_shutdown && method != .exit {
			if has_id {
				app.write_error_response(make_server_shutdown_error_response(request.id))
			}
			continue
		}
		// Before initialize, reject all requests (except initialize and exit).
		// Per LSP §3.5, the server MUST respond with ServerNotInitialized (-32002)
		// to any request received before the initialize handshake completes.
		if !app.received_initialize && method != .initialize && method != .exit {
			if has_id {
				app.write_error_response(make_server_not_initialized_error_response(request.id))
			}
			continue
		}
		if has_id {
			if err_msg := validate_request_params(method, request.params) {
				app.write_error_response(make_invalid_params_error_response(request.id, err_msg))
				continue
			}
		} else {
			if err_msg := validate_notification_params(method, request.params) {
				log('Invalid notification params for ${request.method}: ${err_msg}')
				continue
			}
		}
		match method {
			.completion, .signature_help, .definition, .hover, .declaration, .type_definition,
			.implementation {
				resp := app.operation_at_pos(method, request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.references {
				resp := app.find_references(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.rename {
				resp := app.handle_rename(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.prepare_rename {
				resp := app.handle_prepare_rename(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.workspace_symbol {
				resp := app.handle_workspace_symbol(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.formatting {
				resp := app.handle_formatting(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.document_symbols {
				resp := app.handle_document_symbols(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.inlay_hint {
				resp := app.handle_inlay_hints(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.did_change {
				notification := app.on_did_change(request) or { continue }
				app.write_notification(notification)
			}
			.initialize {
				// Reject double-initialize per LSP spec.
				if app.received_initialize {
					app.write_error_response(make_server_already_initialized_error_response(request.id))
					continue
				}
				if err_msg := app.on_initialize(request) {
					app.write_error_response(make_invalid_params_error_response(request.id, err_msg))
					continue
				}
				// Return all supported capabilities, matching the LSP spec and what is implemented.
				response := Response{
					id:     request.id
					result: Capabilities{
						capabilities: Capability{
							text_document_sync:                 TextDocumentSyncOptions{
								open_close:           true
								change:               2 // Incremental
								save:                 SaveOptions{
									include_text: true
								}
								will_save:            true
								will_save_wait_until: true
							}
							completion_provider:                CompletionProvider{
								trigger_characters: ['.', ' ']
							}
							signature_help_provider:            SignatureHelpOptions{
								trigger_characters: ['(', ',']
							}
							definition_provider:                true
							declaration_provider:               true
							type_definition_provider:           true
							implementation_provider:            true
							hover_provider:                     true
							references_provider:                true
							rename_provider:                    RenameOptions{
								prepare_provider: true
							}
							execute_command_provider:           ExecuteCommandOptions{
								commands: ['vls.runFile', 'vls.runTests']
							}
							document_formatting_provider:       true
							document_symbol_provider:           true
							workspace_symbol_provider:          true
							inlay_hint_provider:                true
							code_action_provider:               true
							code_lens_provider:                 CodeLensOptions{}
							inline_value_provider:              true
							linked_editing_range_provider:      true
							on_type_formatting_provider:        OnTypeFormattingOptions{
								first_trigger_character: '}'
								more_trigger_characters: ['\n']
							}
							semantic_tokens_provider:           SemanticTokensOptions{
								legend: SemanticTokensLegend{
									token_types:     semantic_token_types()
									token_modifiers: semantic_token_modifiers()
								}
								full:   true
								range:  true
							}
							folding_range_provider:             true
							call_hierarchy_provider:            true
							document_highlight_provider:        true
							selection_range_provider:           true
							document_range_formatting_provider: true
							workspace:                          WorkspaceCapability{
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
						server_info:  ServerInfo{
							name:    'vls'
							version: '0.0.2'
						}
					}
				}
				app.write_response(response)
				app.received_initialize = true
			}
			.did_open {
				app.on_did_open(request)
			}
			.did_close {
				app.on_did_close(request)
			}
			.did_save {
				notification := app.on_did_save(request) or { continue }
				app.write_notification(notification)
			}
			.will_save_wait_until {
				resp := app.on_will_save_wait_until(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.initialized {
				log('Received initialized notification.')
				app.on_initialized(request)
			}
			.set_trace {
				log('Received and ignored method: ${request.method}')
			}
			.cancel_request {
				app.on_cancel_request(request)
			}
			.shutdown {
				log('Received shutdown request.')
				app.is_shutdown = true
				shutdown_resp := Response{
					id:     request.id
					result: 'null'
				}
				app.write_response(shutdown_resp)
			}
			.exit {
				log('Received exit notification. Terminating.')
				app.exit_was_requested = true
				break
			}
			.code_action {
				resp := app.handle_code_action(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.semantic_tokens {
				resp := app.handle_semantic_tokens(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.folding_range {
				resp := app.handle_folding_range(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.callhierarchy_prepare {
				resp := app.handle_prepare_call_hierarchy(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.callhierarchy_incoming {
				resp := app.handle_call_hierarchy_incoming(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.callhierarchy_outgoing {
				resp := app.handle_call_hierarchy_outgoing(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.workspace_did_change_configuration {
				app.on_did_change_configuration(request)
			}
			.workspace_did_change_workspace_folders {
				app.on_did_change_workspace_folders(request)
			}
			.document_highlight {
				resp := app.handle_document_highlight(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.selection_range {
				resp := app.handle_selection_range(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.semantic_tokens_range {
				resp := app.handle_semantic_tokens_range(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.range_formatting {
				resp := app.handle_range_formatting(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.did_change_watched_files {
				app.on_did_change_watched_files(request)
			}
			.code_lens {
				resp := app.handle_code_lens(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.code_lens_resolve {
				resp := app.handle_code_lens_resolve(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.execute_command {
				resp := app.handle_execute_command(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.inline_value {
				resp := app.handle_inline_value(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.linked_editing_range {
				resp := app.handle_linked_editing_range(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			.will_create_files, .will_rename_files, .will_delete_files {
				// Return null — vls has no pre-operation file mutations to apply.
				app.write_response(Response{
					id:     request.id
					result: 'null'
				})
			}
			.on_type_formatting {
				resp := app.handle_on_type_formatting(request)
				app.write_response_or_cancelled(request.id, resp)
			}
			else {
				log('UNKNOWN method ${request.method}')
				if has_id {
					if method == .unknown {
						app.write_error_response(make_method_not_found_error_response(request.id,
							request.method))
					} else {
						app.write_error_response(make_internal_error_response(request.id,
							'Unhandled request dispatch for known method: ${request.method}'))
					}
				}
			}
		}
	}
}

fn request_content_has_id(content string) bool {
	envelope := json.decode(RequestIdEnvelope, content) or {
		// Fallback for malformed payloads where full decode is impossible.
		return content.contains('"id":')
	}
	return envelope.id != none
}

fn (mut app App) write_response(response Response) {
	content := encode_response_payload(response)
	headers := $if windows {
		// windows text stdio will output `\r\n` for every `\n`
		'Content-Length: ${content.len}\n\n'
	} $else {
		'Content-Length: ${content.len}\r\n\r\n'
	}
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	app.write_data(full_message)
}

fn encode_response_payload(response Response) string {
	mut content := json.encode(response)
	content = strip_response_sum_type_tags(content)
	if response.result is string {
		if (response.result as string) == 'null' {
			return content.replace('"result":"null"', '"result":null')
		}
	}
	return content
}

fn strip_response_sum_type_tags(content string) string {
	mut cleaned := content
	// V sum-type JSON encoding injects a non-standard `_type` discriminator for
	// struct variants. LSP/JSON-RPC result payloads must not expose those tags.
	for type_name in ['CompletionList', 'Capabilities', 'SignatureHelp', 'Location', 'Hover',
		'WorkspaceEdit', 'PrepareRenameResult', 'SemanticTokens', 'CodeLens', 'LinkedEditingRanges'] {
		cleaned = cleaned.replace(',"_type":"${type_name}"', '')
		cleaned = cleaned.replace('"_type":"${type_name}",', '')
	}
	return cleaned
}

fn (mut app App) write_notification(notification Notification) {
	content := json.encode(notification)
	headers := $if windows {
		// windows text stdio will output `\r\n` for every `\n`
		'Content-Length: ${content.len}\n\n'
	} $else {
		'Content-Length: ${content.len}\r\n\r\n'
	}
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	app.write_data(full_message)
}

fn (mut app App) write_error_response(response ErrorResponse) {
	content := encode_error_response_payload(response)
	headers := $if windows {
		// windows text stdio will output `\r\n` for every `\n`
		'Content-Length: ${content.len}\n\n'
	} $else {
		'Content-Length: ${content.len}\r\n\r\n'
	}
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	app.write_data(full_message)
}

fn encode_error_response_payload(response ErrorResponse) string {
	content := json.encode(response)
	if response.error.code == jsonrpc_err_parse_error {
		return content.replace('"id":0', '"id":null')
	}
	return content
}

fn v_error_to_lsp_diagnostic(e JsonError) LSPDiagnostic {
	start_line := e.line_nr - 1 // LSP is 0-indexed, V parser is 1-indexed
	start_char := e.col - 1 // LSP is 0-indexed, V parser is 1-indexed
	end_char := start_char + e.len
	severity := match e.level {
		'warning' { 2 }
		'notice' { 3 }
		'hint' { 4 }
		else { 1 } // default to Error
	}

	code, tags := derive_diagnostic_code_and_tags(e.message)
	return LSPDiagnostic{
		message:  e.message
		severity: severity
		source:   'vlang'
		code:     code
		tags:     tags
		range:    LSPRange{
			start: Position{
				line: start_line
				char: start_char
			}
			end:   Position{
				line: start_line
				char: end_char
			}
		}
	}
}

// derive_diagnostic_code_and_tags maps a V compiler error message to an optional
// LSP diagnostic code string and an optional list of DiagnosticTag values.
fn derive_diagnostic_code_and_tags(message string) (?string, ?[]int) {
	msg := message.to_lower()
	if msg.contains('unused variable') || msg.contains('declared and not used') {
		return 'unused_variable', [1] // tag 1 = unnecessary
	}
	if msg.contains('unused import') {
		return 'unused_import', [1]
	}
	if msg.contains('deprecated') {
		return 'deprecated', [2] // tag 2 = deprecated
	}
	if msg.contains('undefined') {
		return 'undefined', none
	}
	if msg.contains('type mismatch') || msg.contains('cannot convert') {
		return 'type_mismatch', none
	}
	if msg.contains('unknown module') {
		return 'unknown_module', none
	}
	return none, none
}

fn method_requires_response(method Method) bool {
	return match method {
		.initialize, .completion, .signature_help, .definition, .hover, .declaration,
		.type_definition, .implementation, .references, .rename, .prepare_rename,
		.workspace_symbol, .formatting, .document_symbols, .inlay_hint, .shutdown, .code_action,
		.semantic_tokens, .folding_range, .callhierarchy_prepare, .callhierarchy_incoming,
		.callhierarchy_outgoing, .document_highlight, .selection_range, .semantic_tokens_range,
		.range_formatting, .code_lens, .code_lens_resolve, .execute_command, .inline_value,
		.linked_editing_range, .will_create_files, .will_rename_files, .will_delete_files,
		.on_type_formatting {
			true
		}
		else {
			false
		}
	}
}

fn make_server_not_initialized_error_response(id int) ErrorResponse {
	return ErrorResponse{
		id:    id
		error: ResponseError{
			code:    jsonrpc_err_server_not_initialized
			message: 'Server not yet initialized'
		}
	}
}

fn make_server_already_initialized_error_response(id int) ErrorResponse {
	return ErrorResponse{
		id:    id
		error: ResponseError{
			code:    jsonrpc_err_invalid_request
			message: 'Server already initialized'
		}
	}
}

fn make_server_shutdown_error_response(id int) ErrorResponse {
	return ErrorResponse{
		id:    id
		error: ResponseError{
			code:    jsonrpc_err_invalid_request
			message: 'Server has been shut down'
		}
	}
}

fn make_cancelled_error_response(id int) ErrorResponse {
	return ErrorResponse{
		id:    id
		error: ResponseError{
			code:    jsonrpc_err_request_cancelled
			message: 'Request cancelled'
		}
	}
}

fn make_parse_error_response(message string) ErrorResponse {
	msg := if message != '' { message } else { 'Invalid JSON' }
	return ErrorResponse{
		id:    0
		error: ResponseError{
			code:    jsonrpc_err_parse_error
			message: msg
		}
	}
}

fn make_method_not_found_error_response(id int, method string) ErrorResponse {
	return ErrorResponse{
		id:    id
		error: ResponseError{
			code:    jsonrpc_err_method_not_found
			message: 'Method not found: ${method}'
		}
	}
}

fn make_invalid_params_error_response(id int, message string) ErrorResponse {
	msg := if message != '' { message } else { 'Invalid params' }
	return ErrorResponse{
		id:    id
		error: ResponseError{
			code:    jsonrpc_err_invalid_params
			message: msg
		}
	}
}

fn make_internal_error_response(id int, message string) ErrorResponse {
	msg := if message != '' { message } else { 'Internal error' }
	return ErrorResponse{
		id:    id
		error: ResponseError{
			code:    jsonrpc_err_internal_error
			message: msg
		}
	}
}

fn validate_request_params(method Method, params_json string) ?string {
	return match method {
		.initialize {
			params := json.decode(InitializeParams, params_json) or {
				return 'Invalid initialize params: ${err.msg()}'
			}
			if folders := params.workspace_folders {
				for folder in folders {
					if folder.uri.trim_space() == '' {
						return 'Invalid initialize params: workspaceFolders[i].uri is required'
					}
				}
			}
			none
		}
		.completion, .signature_help, .definition, .hover, .declaration, .type_definition,
		.implementation, .prepare_rename, .document_highlight {
			params := json.decode(TextDocumentPositionParams, params_json) or {
				return 'Invalid textDocument/position params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.references {
			params := json.decode(ReferenceParams, params_json) or {
				return 'Invalid references params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.rename {
			params := json.decode(RenameParams, params_json) or {
				return 'Invalid rename params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			if !is_valid_v_identifier_name(params.new_name) {
				return 'Invalid newName'
			}
			none
		}
		.workspace_symbol {
			json.decode(WorkspaceSymbolParams, params_json) or {
				return 'Invalid workspace/symbol params: ${err.msg()}'
			}
			none
		}
		.formatting {
			params := json.decode(DocumentFormattingParams, params_json) or {
				return 'Invalid formatting params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.document_symbols {
			params := json.decode(DocumentSymbolParams, params_json) or {
				return 'Invalid documentSymbol params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.inlay_hint {
			params := json.decode(InlayHintParams, params_json) or {
				return 'Invalid inlayHint params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.code_action {
			params := json.decode(CodeActionParams, params_json) or {
				return 'Invalid codeAction params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.semantic_tokens {
			params := json.decode(SemanticTokensParams, params_json) or {
				return 'Invalid semanticTokens/full params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.folding_range {
			params := json.decode(FoldingRangeParams, params_json) or {
				return 'Invalid foldingRange params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.callhierarchy_prepare {
			params := json.decode(PrepareCallHierarchyParams, params_json) or {
				return 'Invalid prepareCallHierarchy params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.callhierarchy_incoming {
			params := json.decode(CallHierarchyIncomingCallsParams, params_json) or {
				return 'Invalid incomingCalls params: ${err.msg()}'
			}
			if params.item.uri == '' {
				return 'Missing item.uri'
			}
			none
		}
		.callhierarchy_outgoing {
			params := json.decode(CallHierarchyOutgoingCallsParams, params_json) or {
				return 'Invalid outgoingCalls params: ${err.msg()}'
			}
			if params.item.uri == '' {
				return 'Missing item.uri'
			}
			none
		}
		.selection_range {
			params := json.decode(SelectionRangeParams, params_json) or {
				return 'Invalid selectionRange params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.semantic_tokens_range {
			params := json.decode(SemanticTokensRangeParams, params_json) or {
				return 'Invalid semanticTokens/range params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.range_formatting {
			params := json.decode(DocumentRangeFormattingParams, params_json) or {
				return 'Invalid rangeFormatting params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.linked_editing_range {
			params := json.decode(TextDocumentPositionParams, params_json) or {
				return 'Invalid linkedEditingRange params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.inline_value {
			params := json.decode(InlineValueParams, params_json) or {
				return 'Invalid inlineValue params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.code_lens {
			params := json.decode(CodeLensParams, params_json) or {
				return 'Invalid codeLens params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.code_lens_resolve {
			json.decode(CodeLens, params_json) or {
				return 'Invalid codeLens/resolve params: ${err.msg()}'
			}
			none
		}
		.execute_command {
			json.decode(ExecuteCommandParams, params_json) or {
				return 'Invalid executeCommand params: ${err.msg()}'
			}
			none
		}
		.on_type_formatting {
			params := json.decode(OnTypeFormattingParams, params_json) or {
				return 'Invalid onTypeFormatting params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		else {
			none
		}
	}
}

fn validate_notification_params(method Method, params_json string) ?string {
	return match method {
		.did_open {
			params := json.decode(DidOpenTextDocumentParams, params_json) or {
				return 'Invalid didOpen params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.did_change {
			params := json.decode(DidChangeTextDocumentParams, params_json) or {
				return 'Invalid didChange params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.did_close {
			params := json.decode(DidCloseTextDocumentParams, params_json) or {
				return 'Invalid didClose params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.did_save {
			params := json.decode(DidSaveTextDocumentParams, params_json) or {
				return 'Invalid didSave params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.did_change_watched_files {
			params := json.decode(DidChangeWatchedFilesParams, params_json) or {
				return 'Invalid didChangeWatchedFiles params: ${err.msg()}'
			}
			for change in params.changes {
				if change.uri == '' {
					return 'Missing changes[i].uri'
				}
			}
			none
		}
		.workspace_did_change_configuration {
			// This notification intentionally supports multiple client shapes.
			none
		}
		.workspace_did_change_workspace_folders {
			// params are decoded in the handler; no pre-validation needed here.
			none
		}
		.initialized, .set_trace, .cancel_request, .exit {
			none
		}
		else {
			none
		}
	}
}

fn is_valid_v_identifier_name(name string) bool {
	t := name.trim_space()
	if t == '' {
		return false
	}
	first := t[0]
	if !((first >= `a` && first <= `z`) || (first >= `A` && first <= `Z`) || first == `_`) {
		return false
	}
	for ch in t {
		if !((ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
			|| (ch >= `0` && ch <= `9`) || ch == `_`) {
			return false
		}
	}
	return true
}

// write_raw_notification sends an arbitrary JSON-RPC notification to the client.
// params_json must already be a valid JSON value (object or array).
fn (mut app App) write_raw_notification(method string, params_json string) {
	content := '{"jsonrpc":"2.0","method":"${method}","params":${params_json}}'
	headers := $if windows {
		'Content-Length: ${content.len}\n\n'
	} $else {
		'Content-Length: ${content.len}\r\n\r\n'
	}
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	app.write_data(full_message)
}

// write_raw_request sends an arbitrary JSON-RPC request from the server to the client.
fn (mut app App) write_raw_request(id int, method string, params_json string) {
	content := '{"jsonrpc":"2.0","id":${id},"method":"${method}","params":${params_json}}'
	headers := $if windows {
		'Content-Length: ${content.len}\n\n'
	} $else {
		'Content-Length: ${content.len}\r\n\r\n'
	}
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	app.write_data(full_message)
}

// send_show_message pushes a window/showMessage notification to the client.
// level: 1=Error, 2=Warning, 3=Info, 4=Log.
fn (mut app App) send_show_message(msg string, level int) {
	params := ShowMessageParams{
		type_:   level
		message: msg
	}
	app.write_raw_notification('window/showMessage', json.encode(params))
}

// send_log_message pushes a window/logMessage notification to the client.
// level: 1=Error, 2=Warning, 3=Info, 4=Log.
fn (mut app App) send_log_message(msg string, level int) {
	params := LogMessageParams{
		type_:   level
		message: msg
	}
	app.write_raw_notification('window/logMessage', json.encode(params))
}

// begin_progress sends window/workDoneProgress/create to the client and then
// emits a $/progress begin notification.  Returns the token string so the
// caller can later call report_progress / end_progress with the same token.
fn (mut app App) begin_progress(title string) string {
	if !app.supports_work_done_progress {
		return ''
	}
	token := 'vls-${app.next_request_id}'
	app.next_request_id++
	// Ask the client to create the progress UI.
	create_params := ProgressCreateParams{
		token: token
	}
	app.write_raw_request(app.next_request_id, 'window/workDoneProgress/create',
		json.encode(create_params))
	app.next_request_id++
	// Send the begin payload.
	begin := WorkDoneProgressBegin{
		title: title
	}
	progress_json := '{"token":"${token}","value":${json.encode(begin)}}'
	app.write_raw_notification('$/progress', progress_json)
	return token
}

// report_progress sends a $/progress report notification for an active token.
fn (mut app App) report_progress(token string, message string, percentage int) {
	if token == '' || !app.supports_work_done_progress {
		return
	}
	report := WorkDoneProgressReport{
		message:    message
		percentage: percentage
	}
	progress_json := '{"token":"${token}","value":${json.encode(report)}}'
	app.write_raw_notification('$/progress', progress_json)
}

// end_progress sends a $/progress end notification to finish a progress sequence.
fn (mut app App) end_progress(token string, message string) {
	if token == '' || !app.supports_work_done_progress {
		return
	}
	end := WorkDoneProgressEnd{
		message: message
	}
	progress_json := '{"token":"${token}","value":${json.encode(end)}}'
	app.write_raw_notification('$/progress', progress_json)
}

// on_initialized handles the initialized notification by registering dynamic
// file-watcher capabilities with the client.
fn (mut app App) on_initialized(_ Request) {
	if !app.supports_dynamic_watched_files_registration {
		log('VLS: client does not support dynamic watched-files registration; skipping watcher registration')
		return
	}
	if app.sent_watched_files_registration {
		log('VLS: dynamic watched-files registration already sent; skipping duplicate')
		return
	}
	reg := RegisterCapabilityRequest{
		id:     app.next_request_id
		params: WatcherRegistrationParams{
			registrations: [
				WatcherRegistration{
					id:               'vls-file-watcher'
					method:           'workspace/didChangeWatchedFiles'
					register_options: WatcherRegisterOptions{
						watchers: [
							FileSystemWatcher{
								glob_pattern: '**/*.v'
							},
						]
					}
				},
			]
		}
	}
	app.next_request_id++
	content := json.encode(reg)
	headers := $if windows {
		'Content-Length: ${content.len}\n\n'
	} $else {
		'Content-Length: ${content.len}\r\n\r\n'
	}
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	app.write_data(full_message)
	app.sent_watched_files_registration = true
}

// write_response_or_cancelled sends a cancelled error if the request was
// cancelled while being processed; otherwise it sends the normal response.
fn (mut app App) write_response_or_cancelled(id int, response Response) {
	if app.consume_cancelled_request(id) {
		app.write_error_response(make_cancelled_error_response(id))
		return
	}
	// Defensive: catch response/request id mismatches caused by programming errors.
	if response.id != id {
		app.write_error_response(make_internal_error_response(id,
			'Response id mismatch: expected ${id}, got ${response.id}'))
		return
	}
	app.write_response(response)
}

fn (mut app App) consume_cancelled_request(id int) bool {
	if id in app.cancelled_requests {
		app.cancelled_requests.delete(id)
		return true
	}
	return false
}
