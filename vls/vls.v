module vls

import v.table
import lsp
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
	base_table				&table.Table
	status            ServerStatus = .off
	symbols						map[string]&ast.Stmt
	files							map[string]ast.File
	sources						map[string]string
	tables						map[string]&table.Table
	root_path         string
	cached_completion []lsp.CompletionItem
pub mut:
	// TODO: replace with io.ReadWriter
	io               ReceiveSender
}

pub fn new(io ReceiveSender) Vls {
	mut tbl := table.new_table()
	tbl.is_fmt = false
	return Vls{
		io: io
		base_table: tbl
	}
}

pub fn (mut ls Vls) execute(payload string) {
	request := json.decode(jsonrpc.Request, payload) or {
		ls.send(new_error(jsonrpc.parse_error))
		return
	}
	if request.method != 'exit' && ls.status == .shutdown {
		ls.send(new_error(jsonrpc.invalid_request))
		return
	}
	if request.method != 'initialize' && ls.status != .initialized {
		ls.send(new_error(jsonrpc.server_not_initialized))
		return
	}
	match request.method {
		'initialize' {
			ls.initialize(request.id, request.params)
		}
		'initialized' {} // does nothing currently
		'shutdown' {
			ls.shutdown(request.params)
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
		'textDocument/completion' {
			ls.completion(request.id, request.params)
		}
		else {
			if ls.status != .initialized {
				ls.send(new_error(jsonrpc.server_not_initialized))
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
