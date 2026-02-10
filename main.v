// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json
import os
import v.pref
import io

// App represents the context of the server during its lifetime.
pub struct App {
	cur_mod string = 'main'
	exit    bool   = os.args.contains('exit')
mut:
	text       string            // Current file content
	open_files map[string]string // Map of file URI to file content
	temp_dir   string            // Temporary directory for multi-file compilation
}

const v_prefs = pref.Preferences{
	is_vls: true
}

fn log(s string) {
	eprintln(s)
	temp_dir := os.temp_dir()
	mut output := os.open_append(os.join_path(temp_dir, 'vls_out.txt')) or { panic(err) }
	output.writeln(s) or { panic(err) }
	output.close()
}

fn main() {
	log('VLS (stdio mode) started. Reading from stdin...')
	temp_dir := os.join_path(os.temp_dir(), 'vls_${os.getpid()}')
	os.mkdir_all(temp_dir) or { panic('Failed to create temp directory: ${err}') }
	mut app := &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
	mut reader := io.new_buffered_reader(reader: os.stdin(), cap: 1)
	app.handle_stdio_requests(mut reader)
	log('VLS exiting.')
	os.rmdir_all(temp_dir) or { log('Failed to clean up temp directory: ${err}') }
}

fn read_request(mut reader io.BufferedReader) !string {
	mut len := 0
	for {
		line := reader.read_line() or {
			if err is io.Eof {
				return err
			}
			log('read_request: error reading header line: ${err}')
			return err
		}
		trimmed_line := line.trim_space()
		if trimmed_line == '' {
			break
		}
		log('line=${line}')
		if trimmed_line.starts_with('Content-Length: ') {
			len_str := trimmed_line.after(':').trim_space()
			len = len_str.int()
		}
	}
	if len == 0 {
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

// Main request handler loop
fn (mut app App) handle_stdio_requests(mut reader io.BufferedReader) {
	for {
		content := read_request(mut reader) or {
			if err is io.Eof {
				log('Client closed stdin. Exiting.')
			}
			log('Error reading request: ${err.msg()}')
			break
		}
		if content.len == 0 {
			continue
		}
		log('\n\nRECV: ${content}')
		request := json.decode(Request, content) or {
			log('Failed to decode JSON request: ${err.msg()}. Content: "${content}"')
			continue
		}
		pretty := json.encode_pretty(request)
		log('\n\nRECV (pretty): ${pretty}')
		method := Method.from_string(request.method)
		log('method="${method}" request.method="${request.method}" ${method == .completion}')
		match method {
			.completion, .signature_help, .definition, .hover {
				resp := app.operation_at_pos(method, request)
				write_response(resp)
			}
			.references {
				resp := app.find_references(request)
				write_response(resp)
			}
			.rename {
				resp := app.handle_rename(request)
				write_response(resp)
			}
			.formatting {
				resp := app.handle_formatting(request)
				write_response(resp)
			}
			.did_change {
				log('DID_CHANGE')
				notification := app.on_did_change(request) or { continue }
				write_notification(notification)
			}
			.initialize {
				response := Response{
					id:     request.id
					result: Capabilities{
						capabilities: Capability{
							text_document_sync:           TextDocumentSyncOptions{
								open_close: true
								change:     1 // 1 = Full sync
							}
							completion_provider:          CompletionProvider{
								trigger_characters: ['.']
								completion_item:    CompletionItemCapability{
									snippet_support: true
								}
							}
							signature_help_provider:      SignatureHelpOptions{
								trigger_characters: ['(', ',']
							}
							definition_provider:          true
							hover_provider:               true
							references_provider:          true
							rename_provider:              true
							document_formatting_provider: true
						}
					}
				}
				write_response(response)
			}
			.did_open {
				log('DID_OPEN')
				app.on_did_open(request)
			}
			.initialized, .set_trace, .cancel_request {
				log('Received and ignored method: ${request.method}')
			}
			.shutdown {
				log('Received shutdown request.')
				shutdown_resp := Response{
					id:     request.id
					result: 'null'
				}
				write_response(shutdown_resp)
			}
			.exit {
				log('Received exit notification. Terminating.')
				break
			}
			else {
				log('UNKNOWN method ${request.method}')
			}
		}
	}
}

fn write_response(response Response) {
	content := json.encode(response)
	headers := $if windows {
		// windows text stdio will output `\r\n` for every `\n`
		'Content-Length: ${content.len}\n\n'
	} $else {
		'Content-Length: ${content.len}\r\n\r\n'
	}
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	print(full_message)
	flush_stdout()
}

fn write_notification(notification Notification) {
	content := json.encode(notification)
	headers := $if windows {
		// windows text stdio will output `\r\n` for every `\n`
		'Content-Length: ${content.len}\n\n'
	} $else {
		'Content-Length: ${content.len}\r\n\r\n'
	}
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	print(full_message)
	flush_stdout()
}

struct JsonError {
	path    string
	message string
	line_nr int
	col     int
	len     int
}

struct JsonVarAC {
	details []Detail
}

fn v_error_to_lsp_diagnostic(e JsonError) LSPDiagnostic {
	start_line := e.line_nr - 1 // LSP is 0-indexed, V parser is 1-indexed
	start_char := e.col - 1 // LSP is 0-indexed, V parser is 1-indexed
	end_char := start_char + e.len
	return LSPDiagnostic{
		message:  e.message
		severity: 1 // 1 = Error
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
