module vls

import v.table
import v.doc
import v.token
import v.ast
import json
import jsonrpc
import strings

interface ReceiveSender {
	send(data string)
	receive() ?string
}

struct Vls {
mut:
	table            &table.Table = table.new_table()
	status           ServerStatus = .off
	// imports
	import_graph     map[string][]string
	mod_import_paths map[string]string
	mod_docs         map[string]doc.Doc
	// directory -> file name
	// projects         map[string]Project
	docs             map[string]doc.Doc
	tokens           map[string]map[string][]token.Token
	asts             map[string]map[string]ast.File
	current_file     string
	root_path        string
pub mut:
	// TODO: replace with io.ReadWriter
	io               ReceiveSender
}

pub fn new(io ReceiveSender) Vls {
	return Vls{
		io: io
	}
}

pub fn (mut ls Vls) execute(payload string) {
	request := json.decode(jsonrpc.Request, payload) or {
		ls.send(new_error(jsonrpc.parse_error))
		return
	}
	match ls.status{
		.initialized {
			match request.method { // not only requests but also notifications
				'initialized' {} // does nothing currently
				'shutdown' {
					ls.shutdown(request.id, request.params)
				}
				'exit' {
					ls.exit(request.params)
				}
				'textDocument/didOpen' {
					ls.did_open(request.id, request.params)
				}
				'textDocument/didChange' {
					ls.did_change(request.id, request.params)
				}
				else {}
			}
		} else {
			match request.method {
				'exit' {
					ls.exit(request.params)
				}
				'initialize' {
					ls.initialize(request.id, request.params)
				}
				else {
					if ls.status == .shutdown {
						ls.send(new_error(jsonrpc.invalid_request))
					}
					else {
						ls.send(new_error(jsonrpc.server_not_initialized))
					}
				}
			}
		}

	}
}

// status returns the current server status
pub fn (ls Vls) status() ServerStatus {
	return ls.status
}

// TODO: fn (ls Vls) send<T>(data T) {
fn (ls Vls) send(data string) {
	ls.io.send(data)
}

fn C.fgetc(stream byteptr) int

// start_loop starts an endless loop which waits for stdin and prints responses to the stdout
pub fn (mut ls Vls) start_loop() {
	for {
		payload := ls.io.receive() or { continue }
		ls.execute(payload)
	}
}

fn get_raw_input() string {
	eof := C.EOF
	mut buf := strings.new_builder(200)
	for {
		c := C.fgetc(C.stdin)
		chr := byte(c)
		if buf.len > 2 && (c == eof || chr in [`\r`, `\n`]) {
			break
		}
		buf.write_b(chr)
	}
	return buf.str()
}

pub enum ServerStatus {
	off
	initialized
	shutdown
}

// with error
struct JrpcResponse2<T> {
	jsonrpc string = jsonrpc.version
	id int
	error jsonrpc.ResponseError
	result T
}

[inline]
fn new_error(code int) string {
	err := JrpcResponse2<string>{
		error: jsonrpc.new_response_error(code)
	}
	return json.encode(err)
}
