// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
import json
import os
import v.pref
import io

// App represents the context of the server during its lifetime.
pub struct App {
	cur_mod string = 'main'
	exit    bool   = os.args.contains('exit')
mut:
	text string
}

const v_prefs = pref.Preferences{
	is_vls: true
}

fn log(s string) {
	eprintln(s)
	temp_dir := os.temp_dir()
	mut output := os.open_append(os.join_path(temp_dir, 'vls_out.txt') or { panic(err) }
	output.writeln(s) or { panic(err) }
	output.close()
}

fn main() {
	log('VLS (stdio mode) started. Reading from stdin...')
	mut app := &App{
		text: ''
	}
	mut reader := io.new_buffered_reader(reader: os.stdin(), cap: 1)
	app.handle_stdio_requests(mut reader)
	log('VLS exiting.')
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
		log('1method="${method}" request.method="${request.method}" kek${method == .completion}')
		match method {
			.completion {
				log('RUNNING COMPLETION')
				resp := app.completion(request)
				write_response(resp)
			}
			.signature_help {
				log('SIG HELP')
				resp := app.signature_help(request)
				write_response(resp)
			}
			.definition {
				log('GO TO DEFINITION')
				resp := app.go_to_definition(request)
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
							text_document_sync:      TextDocumentSyncOptions{
								open_close: true
								change:     1 // 1 = Full sync
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
				write_response(response)
			}
			.initialized, .did_open, .set_trace, .cancel_request {
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
	mut content := json.encode(response)
	// These replaces are needed because V's json encoder adds a `_type` field for union variants.
	// TODO make it cleaner
	content = content.replace(',"_type":"Detail"', '')
	content = content.replace('"_type":"Detail",', '')
	content = content.replace(',"_type":"LSPDiagnostic"', '')
	content = content.replace('"_type":"LSPDiagnostic",', '')
	content = content.replace(',"_type":"SignatureInformation"', '')
	content = content.replace('"_type":"SignatureInformation",', '')
	content = content.replace(',"_type":"ParameterInformation"', '')
	content = content.replace('"_type":"ParameterInformation",', '')
	content = content.replace(',"_type":"Location"', '')
	content = content.replace('"_type":"Location",', '')
	headers := 'Content-Length: ${content.len}\r\n\r\n'
	full_message := '${headers}${content}'
	log('SEND: ${full_message}')
	print(full_message)
	flush_stdout()
}

fn write_notification(notification Notification) {
	mut content := json.encode(notification)
	content = content.replace(',"_type":"LSPDiagnostic"', '')
	content = content.replace('"_type":"LSPDiagnostic",', '')
	headers := 'Content-Length: ${content.len}\r\n\r\n'
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
	name    string
	type    string
	fields  []string // "name:type" strings
	methods []string // "name:type" strings
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
