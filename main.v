// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
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
	project_generations                         map[string]int            // Per-project-dir revision, for scoped cache invalidation
	cancelled_requests                          map[int]bool              // Request ids cancelled via $/cancelRequest
	cancelled_raw_ids                           map[string]bool           // String/raw request ids cancelled via $/cancelRequest
	current_request_raw_id                      string                    // Raw JSON id of the request being processed (echoed verbatim)
	position_encoding                           PositionEncoding = .utf16 // Negotiated LSP position encoding (default UTF-16)
	symbol_index                                map[string]IndexEntry // Persistent per-URI symbol index (see index.v)
	indexed_dirs                                map[string]bool       // Project dirs already walked into the index
	indexed_dir_walk_ms                         map[string]i64        // Last walk time per dir, for watcher-less refresh
	ref_occurrences                             map[string]OccEntry   // Per-URI identifier occurrences for references (see index.v)
	vlib_fn_cache                               map[string]map[string]string // Per-vlib-module fn→return-type index (immutable during a session)
	tcp_conn                                    ?&net.TcpConn         // Non-nil when serving a TCP client
	is_shutdown                                 bool                  // True after shutdown request was acknowledged
	exit_was_requested                          bool                  // True when the exit notification was received
	received_initialize                         bool                  // True after initialize request was processed
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

// logging_enabled gates all diagnostic logging. Logging is OFF by default:
// the old behavior wrote every received/sent JSON payload (which can contain
// full source text and secrets) to stderr AND re-opened/appended/closed a
// shared unrotated file on every one of the ~160 call sites (P1-13). Set the
// VLS_LOG environment variable to any non-empty value to enable logging to
// ${TMPDIR}/vls_out.txt for debugging.
const logging_enabled = os.getenv('VLS_LOG') != ''
const log_file_path = os.join_path(os.temp_dir(), 'vls_out.txt')

fn log(s string) {
	if !logging_enabled {
		return
	}
	eprintln(s)
	mut output := os.open_append(log_file_path) or { return }
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
	// TCP binds to loopback (127.0.0.1) by default; binding to any other
	// interface requires the explicit --unsafe-allow-remote opt-in because the
	// transport is unauthenticated (P0-06).
	args := os.args
	mut port := ''
	mut host := '127.0.0.1'
	mut allow_remote := false
	for i, arg in args {
		match arg {
			'--port' {
				if i + 1 < args.len {
					port = args[i + 1]
				}
			}
			'--host' {
				if i + 1 < args.len {
					host = args[i + 1]
				}
			}
			'--unsafe-allow-remote' {
				allow_remote = true
			}
			else {}
		}
	}
	if port != '' {
		run_tcp_server(host, port, allow_remote)
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
	mut reader := io.new_buffered_reader(reader: os.stdin(), cap: transport_buffer_cap)
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

// is_loopback_host reports whether `host` refers to the local machine only.
fn is_loopback_host(host string) bool {
	return host in ['127.0.0.1', '::1', 'localhost', '']
}

// run_tcp_server listens on the given host/port and spawns a goroutine for each
// incoming client connection.  Each client gets its own App instance so all
// state is fully isolated.  Non-loopback binds require an explicit opt-in
// because the transport has no authentication or TLS (P0-06).
fn run_tcp_server(host string, port string, allow_remote bool) {
	if !is_loopback_host(host) && !allow_remote {
		msg :=
			'VLS: refusing to bind TCP to non-loopback host "${host}" without --unsafe-allow-remote. ' +
			'The TCP transport is unauthenticated and unencrypted; exposing it on a network is unsafe.'
		log(msg)
		eprintln(msg)
		return
	}
	bind_host := if host == '' { '127.0.0.1' } else { host }
	addr := '${bind_host}:${port}'
	log('VLS TCP server starting on ${addr}...')
	mut listener := net.listen_tcp(.ip, addr) or {
		log('Failed to start TCP listener on ${addr}: ${err}')
		return
	}
	log('VLS TCP server listening on ${addr}')
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
	mut reader := io.new_buffered_reader(reader: conn, cap: transport_buffer_cap)
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

// send_framed prepends a Content-Length header to `content` and writes the
// message. LSP requires CRLF-delimited headers. A TCP connection is a raw byte
// stream, so it always gets literal `\r\n\r\n`; only Windows *stdio* uses `\n\n`,
// relying on text-mode stdout to translate each `\n` into `\r\n` on the wire
// (P0-11). This prevents Windows TCP from emitting LF-only framing.
fn (mut app App) send_framed(content string) {
	mut is_tcp := false
	if _ := app.tcp_conn {
		is_tcp = true
	}
	header := if is_tcp {
		'Content-Length: ${content.len}\r\n\r\n'
	} else {
		$if windows {
			'Content-Length: ${content.len}\n\n'
		} $else {
			'Content-Length: ${content.len}\r\n\r\n'
		}
	}
	full_message := '${header}${content}'
	log('SEND: ${full_message}')
	app.write_data(full_message)
}

// Transport framing limits (P0-11). These bound how much memory an untrusted
// client (local or over TCP) can force the server to allocate.
const transport_buffer_cap = 64 * 1024 // buffered reader capacity
const max_content_length = 64 * 1024 * 1024 // 64 MiB max JSON-RPC body
const max_header_bytes = 64 * 1024 // total header section size cap
const max_charset = 'utf-8' // LSP content is always UTF-8

fn read_request(mut reader io.BufferedReader) !string {
	mut len := -1
	mut header_error := ''
	mut header_bytes := 0
	for {
		line := reader.read_line() or {
			if err is io.Eof {
				return err
			}
			$if debug { log('read_request: error reading header line: ${err}') }
			return err
		}
		header_bytes += line.len + 2 // account for the stripped CRLF
		if header_bytes > max_header_bytes {
			return error('invalid header: header section exceeds ${max_header_bytes} bytes')
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
			if parsed_len > max_content_length {
				header_error = 'invalid header: Content-Length ${parsed_len} exceeds maximum ${max_content_length}'
				continue
			}
			if len != -1 && len != parsed_len {
				header_error = 'invalid header: conflicting Content-Length headers'
				continue
			}
			len = parsed_len
			continue
		}
		if lower.starts_with('content-type:') {
			// LSP content is always UTF-8. Reject any explicitly declared
			// non-UTF-8 charset instead of silently misdecoding bytes.
			if charset_is_unsupported(trimmed_line.all_after(':')) {
				header_error = 'invalid header: unsupported charset (only ${max_charset} is allowed)'
				continue
			}
			continue
		}
	}
	// Surface a header error before doing anything else, so a malformed
	// Content-Length can never silently desynchronize the stream.
	if header_error != '' {
		return error(header_error)
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
	return buf.bytestr()
}

// charset_is_unsupported reports whether a Content-Type header value declares a
// charset other than UTF-8. LSP §3 mandates UTF-8 for all message content; the
// historical `utf8` spelling is also accepted.
fn charset_is_unsupported(content_type string) bool {
	lower := content_type.to_lower()
	idx := lower.index('charset=') or { return false }
	charset := lower[idx + 'charset='.len..].trim_space().trim_right(';').trim_space()
	return charset != 'utf-8' && charset != 'utf8'
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
	// Guard against overflow of the 32-bit int parse before using the value.
	if t.len > 18 {
		return error('Content-Length too large')
	}
	n := t.i64()
	if n < 0 || n > max_content_length {
		return error('Content-Length out of range')
	}
	return int(n)
}

// handle_requests is the main request handler loop for both stdio and TCP modes.
fn (mut app App) handle_requests(mut reader io.BufferedReader) {
	for {
		// Reset the per-request raw id so a stale id can never leak into an
		// error response emitted before a new message is fully read.
		app.current_request_raw_id = ''
		content := read_request(mut reader) or {
			if err is io.Eof {
				log('Client closed connection. Exiting.')
				break
			}
			if err.msg().starts_with('invalid header:') {
				// The frame body was not consumed, so the stream is now
				// desynchronized: the unread body would be misread as the next
				// header. Report the error, then close the connection rather than
				// attempting to resynchronize (P0-11).
				app.write_error_response(make_parse_error_response(err.msg()))
				break
			}
			$if debug { log('Error reading request: ${err.msg()}') }
			break
		}
		if content.len == 0 {
			continue
		}
		log('\n\nRECV: ${content}')
		// A message with an id + result/error but no method is a response to a
		// server-initiated request (progress create, capability registration).
		// Consume it without dispatching so it never hits the method router or
		// produces a spurious MethodNotFound error (P0-02).
		if is_client_response_message(content) {
			log('Consumed client response to a server-initiated request: ${content}')
			continue
		}
		has_id := request_content_has_id(content)
		// Preserve the exact id (numeric or string) so responses echo it
		// verbatim; string ids would otherwise collapse to 0 (P0-02).
		app.current_request_raw_id = extract_raw_id(content) or { '' }
		// JSON-RPC ids may only be a string, number, or null (an absent raw id).
		// A present id of any other type (object, array, boolean) is an Invalid
		// Request: respond with a null id — the id could not be validly
		// determined — rather than dispatching and echoing a bogus id (P0-02).
		if app.current_request_raw_id != '' && !raw_id_is_valid(app.current_request_raw_id) {
			app.current_request_raw_id = 'null'
			app.write_error_response(make_invalid_request_error_response(0, 'Request id must be a string, number, or null'))
			continue
		}
		// Decode the body WITHOUT the id field: json2 aborts the whole decode on
		// a string value in an int field, which would otherwise make every
		// string-id request undecodable. The numeric id is derived from the raw
		// id (0 for non-numeric ids), while the exact id is echoed via the raw id.
		body := json2.decode[RequestBody](content) or {
			log('Failed to decode JSON request: ${err.msg()}. Content: "${content}"')
			app.write_error_response(make_parse_error_response(err.msg()))
			continue
		}
		request := Request{
			id:      raw_id_to_int(app.current_request_raw_id)
			method:  body.method
			jsonrpc: body.jsonrpc
			params:  body.params
		}
		log('\n\nRECV (pretty): ${content}')
		method := Method.from_string(request.method)
		log('method="${method}" request.method="${request.method}" ${method == .completion}')
		// Enforce request/notification direction (P0-03): a message with an id
		// sent to a notification-only method is an InvalidRequest; a message
		// without an id sent to a request-only method is dropped rather than
		// processed into a response with a bogus id.
		if has_id && method_is_notification_only(method) {
			app.write_error_response(make_invalid_request_error_response(request.id,
				'Method ${request.method} is a notification and cannot be sent as a request'))
			continue
		}
		if !has_id && method_requires_response(method) {
			log('Dropping notification-shaped message for request-only method ${request.method}')
			continue
		}
		if method_requires_response(method) && app.request_is_cancelled(request.id) {
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
							// NOTE: Placeholder/stub capabilities are intentionally NOT
							// advertised (P1-07 / Stage 0): on-type formatting (always
							// empty), inline values (wrong abstraction), linked editing
							// (wrong abstraction), file-operation hooks (no-ops), the
							// run/test executeCommand + codeLens stubs, and willSave
							// (never dispatched). Advertising only working features gives
							// a better editor experience than exposing broken UI.
							text_document_sync:           TextDocumentSyncOptions{
								open_close:           true
								change:               2 // Incremental
								save:                 SaveOptions{
									include_text: true
								}
								will_save:            false
								will_save_wait_until: true
							}
							completion_provider:          CompletionProvider{
								trigger_characters: ['.']
							}
							signature_help_provider:      SignatureHelpOptions{
								trigger_characters: ['(', ',']
							}
							definition_provider:          true
							declaration_provider:         true
							type_definition_provider:     true
							implementation_provider:      true
							hover_provider:               true
							references_provider:          true
							rename_provider:              RenameOptions{
								prepare_provider: true
							}
							document_formatting_provider: true
							document_symbol_provider:     true
							workspace_symbol_provider:    true
							inlay_hint_provider:          true
							code_action_provider:         true
							semantic_tokens_provider:     SemanticTokensOptions{
								legend: SemanticTokensLegend{
									token_types:     semantic_token_types()
									token_modifiers: semantic_token_modifiers()
								}
								full:   true
								range:  true
							}
							folding_range_provider:       true
							call_hierarchy_provider:      true
							document_highlight_provider:  true
							selection_range_provider:     true
							// Range formatting is NOT advertised: v fmt only formats whole
							// files, so a correct range implementation needs a
							// character-accurate, EOL-preserving diff restricted to the
							// requested range, which is not yet implemented (P0-08).
							document_range_formatting_provider: false
							position_encoding:                  position_encoding_string(app.position_encoding)
							workspace:                          WorkspaceCapability{
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
				// Surface a clearly actionable message if the V compiler is not
				// available, instead of silently returning empty diagnostics,
				// completion, and navigation for every request (P1-03).
				if !compiler_is_available() {
					app.send_show_message('vls: the V compiler (`v`) was not found on PATH. Diagnostics, completion, and navigation will not work until `v` is installed and on PATH.',
						1)
				}
			}
			.did_open {
				app.on_did_open(request)
				// Publish diagnostics immediately on open (P0-07 item 10).
				if params := json2.decode[DidOpenTextDocumentParams](request.params) {
					uri := params.text_document.uri
					if doc_content := app.open_files[uri] {
						app.write_notification(app.build_diagnostics_notification(uri, doc_content))
					}
				}
			}
			.did_close {
				app.on_did_close(request)
				// Clear published diagnostics for the closed document (P0-07 item 9).
				if params := json2.decode[DidCloseTextDocumentParams](request.params) {
					app.write_notification(Notification{
						method: 'textDocument/publishDiagnostics'
						params: PublishDiagnosticsParams{
							uri:         params.text_document.uri
							diagnostics: []
						}
					})
				}
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
	return extract_raw_id(content) != none
}

// raw_id_to_int converts a raw JSON id token to an int for internal use. String
// ids (and absent ids) collapse to 0; the exact id is preserved separately via
// the raw id and echoed verbatim in responses.
fn raw_id_to_int(raw string) int {
	if raw == '' || raw.starts_with('"') {
		return 0
	}
	return raw.int()
}

// raw_id_is_valid reports whether a raw JSON id token is a legal JSON-RPC id: a
// string, a number, or null. Objects, arrays, and booleans are rejected. An
// absent id is represented by an empty token and is handled by the caller.
fn raw_id_is_valid(raw string) bool {
	if raw == '' || raw == 'null' || raw[0] == `"` {
		return true
	}
	c := raw[0]
	return c == `-` || (c >= `0` && c <= `9`)
}

// json_is_ws reports whether a byte is JSON insignificant whitespace.
fn json_is_ws(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r`
}

// read_json_string_token reads a JSON string starting at `content[i]` (which
// must be a double quote) and returns the decoded key text plus the index just
// past the closing quote.
fn read_json_string_token(content string, start int) (string, int) {
	mut i := start + 1 // past opening quote
	mut sb := []u8{}
	for i < content.len {
		c := content[i]
		if c == `\\` && i + 1 < content.len {
			nxt := content[i + 1]
			esc := match nxt {
				`n` { u8(`\n`) }
				`t` { u8(`\t`) }
				`r` { u8(`\r`) }
				else { nxt }
			}
			sb << esc
			i += 2
			continue
		}
		if c == `"` {
			return sb.bytestr(), i + 1
		}
		sb << c
		i++
	}
	return sb.bytestr(), i
}

// skip_json_value returns the index just past a complete JSON value beginning at
// `content[i]` (object, array, string, number, or keyword).
fn skip_json_value(content string, start int) int {
	mut i := start
	n := content.len
	if i >= n {
		return i
	}
	c := content[i]
	if c == `"` {
		_, next := read_json_string_token(content, i)
		return next
	}
	if c == `{` || c == `[` {
		mut depth := 0
		for i < n {
			ch := content[i]
			if ch == `"` {
				_, next := read_json_string_token(content, i)
				i = next
				continue
			}
			if ch == `{` || ch == `[` {
				depth++
			} else if ch == `}` || ch == `]` {
				depth--
				if depth == 0 {
					return i + 1
				}
			}
			i++
		}
		return i
	}
	// number / true / false / null
	for i < n && content[i] != `,` && content[i] != `}` && content[i] != `]`
		&& !json_is_ws(content[i]) {
		i++
	}
	return i
}

// extract_raw_id returns the raw JSON representation of the top-level `id`
// member (e.g. `5`, `"abc"`, or `null`), preserving its exact type so it can be
// echoed verbatim in the response. Returns none ONLY when `id` is absent: a
// present JSON null yields the literal token `null` so the message is treated as
// a request (JSON-RPC permits null ids) and answered with `"id":null`, rather
// than being misclassified as a notification. This is how the server supports
// numeric, string, and null request/cancellation IDs (P0-02) even though the
// typed decoder collapses string ids to 0.
fn extract_raw_id(content string) ?string {
	mut i := content.index('{') or { return none }
	i++
	n := content.len
	for i < n {
		for i < n && (json_is_ws(content[i]) || content[i] == `,`) {
			i++
		}
		if i >= n || content[i] == `}` {
			break
		}
		if content[i] != `"` {
			break
		}
		key, after_key := read_json_string_token(content, i)
		i = after_key
		for i < n && json_is_ws(content[i]) {
			i++
		}
		if i >= n || content[i] != `:` {
			break
		}
		i++
		for i < n && json_is_ws(content[i]) {
			i++
		}
		if key == 'id' {
			// A present null id is returned as the literal `null` (not none) so it
			// is distinguished from an absent id and treated as a request.
			end := skip_json_value(content, i)
			return content[i..end].trim_space()
		}
		i = skip_json_value(content, i)
	}
	return none
}

// content_has_member reports whether the top-level JSON object declares `member`.
fn content_has_member(content string, member string) bool {
	mut i := content.index('{') or { return false }
	i++
	n := content.len
	for i < n {
		for i < n && (json_is_ws(content[i]) || content[i] == `,`) {
			i++
		}
		if i >= n || content[i] == `}` {
			break
		}
		if content[i] != `"` {
			break
		}
		key, after_key := read_json_string_token(content, i)
		i = after_key
		for i < n && json_is_ws(content[i]) {
			i++
		}
		if i >= n || content[i] != `:` {
			break
		}
		i++
		for i < n && json_is_ws(content[i]) {
			i++
		}
		if key == member {
			return true
		}
		i = skip_json_value(content, i)
	}
	return false
}

// is_client_response_message reports whether an inbound message is a response to
// a server-initiated request: it carries an `id` and a `result` or `error`
// member but no `method`. Such messages must be consumed, not dispatched as
// method calls (P0-02).
fn is_client_response_message(content string) bool {
	if content_has_member(content, 'method') {
		return false
	}
	has_id := content.contains('"id"')
	return has_id && (content_has_member(content, 'result') || content_has_member(content, 'error'))
}

// inject_raw_id rewrites the first `"id":<value>` in an encoded response so the
// response echoes the request's id with its original type. For numeric ids this
// is a no-op; for string ids it replaces the placeholder `0` written by the
// typed encoder with the quoted string.
fn inject_raw_id(encoded string, raw_id string) string {
	if raw_id == '' {
		return encoded
	}
	key := '"id":'
	idx := encoded.index(key) or { return encoded }
	val_start := idx + key.len
	mut val_end := val_start
	for val_end < encoded.len && encoded[val_end] != `,` && encoded[val_end] != `}` {
		val_end++
	}
	return encoded[..val_start] + raw_id + encoded[val_end..]
}

fn (mut app App) write_response(response Response) {
	content := inject_raw_id(encode_response_payload(response), app.current_request_raw_id)
	app.send_framed(content)
}

fn encode_response_payload(response Response) string {
	mut content := json2.encode(response, escape_unicode: true)
	content = strip_response_sum_type_tags(content)
	if response.result is string {
		if (response.result as string) == 'null' {
			return content.replace('"result":"null"', '"result":null')
		}
	}
	return content
}

// strip_response_sum_type_tags removes V's non-standard `_type` sum-type
// discriminator members from an encoded result payload. LSP/JSON-RPC responses
// must not expose them. This strips the tag for EVERY result variant — including
// array-of-struct variants and any future type — rather than a hardcoded list,
// so a newly added result type can never leak a `_type` field (P1-10). The tag
// value is always a bare V struct name (identifier characters only), so scanning
// to its closing quote is unambiguous.
fn strip_response_sum_type_tags(content string) string {
	needle := '"_type":"'
	if !content.contains(needle) {
		return content
	}
	mut sb := []u8{cap: content.len}
	mut i := 0
	for i < content.len {
		if content[i] == `"` && matches_needle_at(content, i, needle) {
			mut j := i + needle.len
			for j < content.len && content[j] != `"` {
				j++
			}
			member_end := if j < content.len { j + 1 } else { j } // just past closing quote
			if i > 0 && content[i - 1] == `,` {
				// The separating comma was already emitted; drop it.
				sb.delete_last()
				i = member_end
			} else if member_end < content.len && content[member_end] == `,` {
				i = member_end + 1
			} else {
				i = member_end
			}
			continue
		}
		sb << content[i]
		i++
	}
	return sb.bytestr()
}

// matches_needle_at reports whether `needle` occurs in `s` starting at `i`.
fn matches_needle_at(s string, i int, needle string) bool {
	if i + needle.len > s.len {
		return false
	}
	for k in 0 .. needle.len {
		if s[i + k] != needle[k] {
			return false
		}
	}
	return true
}

fn (mut app App) write_notification(notification Notification) {
	app.send_framed(json2.encode(notification, escape_unicode: true))
}

fn (mut app App) write_error_response(response ErrorResponse) {
	// Parse errors have a null id per spec; never echo a (possibly stale) raw id
	// for those. Other errors echo the request's id verbatim.
	mut content := encode_error_response_payload(response)
	if response.error.code != jsonrpc_err_parse_error {
		content = inject_raw_id(content, app.current_request_raw_id)
	}
	app.send_framed(content)
}

fn encode_error_response_payload(response ErrorResponse) string {
	content := json2.encode(response, escape_unicode: true)
	if response.error.code == jsonrpc_err_parse_error {
		return content.replace('"id":0', '"id":null')
	}
	return content
}

fn v_error_to_lsp_diagnostic(e JsonError) LSPDiagnostic {
	// LSP is 0-indexed, the V parser is 1-indexed. LSP positions must be
	// non-negative, so clamp values the compiler may report as 0/negative
	// instead of emitting invalid negative positions (P1-09).
	start_line := if e.line_nr - 1 > 0 { e.line_nr - 1 } else { 0 }
	start_char := if e.col - 1 > 0 { e.col - 1 } else { 0 }
	len := if e.len > 0 { e.len } else { 0 }
	end_char := start_char + len
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

// method_is_notification_only reports whether `method` is a client→server
// notification that must never receive a response (LSP method contract). `exit`
// is deliberately excluded so the shutdown/exit lifecycle stays robust
// regardless of whether a client mistakenly attaches an id.
fn method_is_notification_only(method Method) bool {
	return match method {
		.initialized, .did_open, .did_change, .did_close, .did_save, .did_change_watched_files,
		.workspace_did_change_configuration, .workspace_did_change_workspace_folders, .set_trace,
		.cancel_request, .will_save {
			true
		}
		else {
			false
		}
	}
}

// request_is_cancelled reports whether the request currently being processed was
// cancelled. A string-id request is matched ONLY by its exact raw id, so it can
// never be falsely cancelled by a numeric cancel of id 0 (P0-02).
fn (app &App) request_is_cancelled(id int) bool {
	raw := app.current_request_raw_id
	if raw.starts_with('"') {
		return raw in app.cancelled_raw_ids
	}
	if id in app.cancelled_requests {
		return true
	}
	return raw != '' && raw in app.cancelled_raw_ids
}

fn make_invalid_request_error_response(id int, message string) ErrorResponse {
	msg := if message != '' { message } else { 'Invalid request' }
	return ErrorResponse{
		id:    id
		error: ResponseError{
			code:    jsonrpc_err_invalid_request
			message: msg
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
			params := json2.decode[InitializeParams](params_json) or {
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
			params := json2.decode[TextDocumentPositionParams](params_json) or {
				return 'Invalid textDocument/position params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.references {
			params := json2.decode[ReferenceParams](params_json) or {
				return 'Invalid references params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.rename {
			params := json2.decode[RenameParams](params_json) or {
				return 'Invalid rename params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			if !is_valid_v_identifier_name(params.new_name) {
				return 'Invalid newName'
			}
			// Renaming to a V keyword or builtin would produce uncompilable code.
			if params.new_name in v_keywords || params.new_name in v_builtins {
				return 'newName `${params.new_name}` is a reserved V keyword or builtin'
			}
			none
		}
		.workspace_symbol {
			json2.decode[WorkspaceSymbolParams](params_json) or {
				return 'Invalid workspace/symbol params: ${err.msg()}'
			}
			none
		}
		.formatting {
			params := json2.decode[DocumentFormattingParams](params_json) or {
				return 'Invalid formatting params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.document_symbols {
			params := json2.decode[DocumentSymbolParams](params_json) or {
				return 'Invalid documentSymbol params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.inlay_hint {
			params := json2.decode[InlayHintParams](params_json) or {
				return 'Invalid inlayHint params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.code_action {
			params := json2.decode[CodeActionParams](params_json) or {
				return 'Invalid codeAction params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.semantic_tokens {
			params := json2.decode[SemanticTokensParams](params_json) or {
				return 'Invalid semanticTokens/full params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.folding_range {
			params := json2.decode[FoldingRangeParams](params_json) or {
				return 'Invalid foldingRange params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.callhierarchy_prepare {
			params := json2.decode[PrepareCallHierarchyParams](params_json) or {
				return 'Invalid prepareCallHierarchy params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.callhierarchy_incoming {
			params := json2.decode[CallHierarchyIncomingCallsParams](params_json) or {
				return 'Invalid incomingCalls params: ${err.msg()}'
			}
			if params.item.uri == '' {
				return 'Missing item.uri'
			}
			none
		}
		.callhierarchy_outgoing {
			params := json2.decode[CallHierarchyOutgoingCallsParams](params_json) or {
				return 'Invalid outgoingCalls params: ${err.msg()}'
			}
			if params.item.uri == '' {
				return 'Missing item.uri'
			}
			none
		}
		.selection_range {
			params := json2.decode[SelectionRangeParams](params_json) or {
				return 'Invalid selectionRange params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.semantic_tokens_range {
			params := json2.decode[SemanticTokensRangeParams](params_json) or {
				return 'Invalid semanticTokens/range params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.range_formatting {
			params := json2.decode[DocumentRangeFormattingParams](params_json) or {
				return 'Invalid rangeFormatting params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.linked_editing_range {
			params := json2.decode[TextDocumentPositionParams](params_json) or {
				return 'Invalid linkedEditingRange params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.inline_value {
			params := json2.decode[InlineValueParams](params_json) or {
				return 'Invalid inlineValue params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.code_lens {
			params := json2.decode[CodeLensParams](params_json) or {
				return 'Invalid codeLens params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.code_lens_resolve {
			json2.decode[CodeLens](params_json) or {
				return 'Invalid codeLens/resolve params: ${err.msg()}'
			}
			none
		}
		.execute_command {
			json2.decode[ExecuteCommandParams](params_json) or {
				return 'Invalid executeCommand params: ${err.msg()}'
			}
			none
		}
		.on_type_formatting {
			params := json2.decode[OnTypeFormattingParams](params_json) or {
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
			params := json2.decode[DidOpenTextDocumentParams](params_json) or {
				return 'Invalid didOpen params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.did_change {
			params := json2.decode[DidChangeTextDocumentParams](params_json) or {
				return 'Invalid didChange params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.did_close {
			params := json2.decode[DidCloseTextDocumentParams](params_json) or {
				return 'Invalid didClose params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.did_save {
			params := json2.decode[DidSaveTextDocumentParams](params_json) or {
				return 'Invalid didSave params: ${err.msg()}'
			}
			if params.text_document.uri == '' {
				return 'Missing textDocument.uri'
			}
			none
		}
		.did_change_watched_files {
			params := json2.decode[DidChangeWatchedFilesParams](params_json) or {
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
	app.send_framed('{"jsonrpc":"2.0","method":"${method}","params":${params_json}}')
}

// write_raw_request sends an arbitrary JSON-RPC request from the server to the client.
fn (mut app App) write_raw_request(id int, method string, params_json string) {
	app.send_framed('{"jsonrpc":"2.0","id":${id},"method":"${method}","params":${params_json}}')
}

// send_show_message pushes a window/showMessage notification to the client.
// level: 1=Error, 2=Warning, 3=Info, 4=Log.
fn (mut app App) send_show_message(msg string, level int) {
	params := ShowMessageParams{
		type_:   level
		message: msg
	}
	app.write_raw_notification('window/showMessage', json2.encode(params, escape_unicode: true))
}

// send_log_message pushes a window/logMessage notification to the client.
// level: 1=Error, 2=Warning, 3=Info, 4=Log.
fn (mut app App) send_log_message(msg string, level int) {
	params := LogMessageParams{
		type_:   level
		message: msg
	}
	app.write_raw_notification('window/logMessage', json2.encode(params, escape_unicode: true))
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
	app.write_raw_request(app.next_request_id, 'window/workDoneProgress/create', json2.encode(create_params,
		escape_unicode: true
	))
	app.next_request_id++
	// Send the begin payload.
	begin := WorkDoneProgressBegin{
		title: title
	}
	progress_json := '{"token":"${token}","value":${json2.encode(begin, escape_unicode: true)}}'
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
	progress_json := '{"token":"${token}","value":${json2.encode(report, escape_unicode: true)}}'
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
	progress_json := '{"token":"${token}","value":${json2.encode(end, escape_unicode: true)}}'
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
	app.send_framed(json2.encode(reg, escape_unicode: true))
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
	raw := app.current_request_raw_id
	mut was_cancelled := false
	if raw.starts_with('"') {
		// String-id request: consume only its exact raw id.
		if raw in app.cancelled_raw_ids {
			app.cancelled_raw_ids.delete(raw)
			was_cancelled = true
		}
		return was_cancelled
	}
	if id in app.cancelled_requests {
		app.cancelled_requests.delete(id)
		was_cancelled = true
	}
	if raw != '' && raw in app.cancelled_raw_ids {
		app.cancelled_raw_ids.delete(raw)
		was_cancelled = true
	}
	return was_cancelled
}

// generation_key returns the cache-invalidation scope for `uri`: its enclosing
// `v.mod` project root, or its immediate directory when the file belongs to no
// project. Keying on the project root (not just `os.dir`) means editing one
// module invalidates diagnostics for sibling modules in the same project that
// import it — otherwise an importer keyed on its own directory would reuse
// diagnostics computed against the imported module's old API (P1-06).
fn (app &App) generation_key(uri string) string {
	dir := os.dir(uri_to_path(uri))
	root := find_project_root(dir)
	return if root != '' { root } else { dir }
}

// bump_generation records a mutation to `uri`, advancing both the global counter
// and the per-project revision. Diagnostic caching keys off the per-project
// revision so that editing one file invalidates cached diagnostics for the whole
// owning project (covering cross-module imports), not every open document (P1-06).
fn (mut app App) bump_generation(uri string) {
	app.open_files_generation++
	key := app.generation_key(uri)
	app.project_generations[key] = app.project_generations[key] + 1
}

// project_generation returns the current revision for the project that owns `uri`.
fn (app &App) project_generation(uri string) int {
	return app.project_generations[app.generation_key(uri)]
}
