module vls

import v.table
import v.doc
import v.token
import v.ast
import json
import jsonrpc
import eventbus

pub struct Vls {
mut:
	table            &table.Table = table.new_table()
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
	status           ServerStatus = .off
	eb							 &eventbus.EventBus = eventbus.new()
	// for additional contexts such as tcp context and etc.
	ctx							 voidptr
pub mut:
	// TODO: replace with io.Writer
	// send             fn (string) = fn (res string) {}
	response         string
	test_mode        bool
}

pub fn (mut ls Vls) execute(payload string) {
	request := json.decode(jsonrpc.Request, payload) or {
		ls.send_error(jsonrpc.parse_error)
		return
	}
	if request.method != 'exit' && ls.status == .shutdown {
		ls.send_error(jsonrpc.invalid_request)
		return
	}
	if request.method != 'initialize' && ls.status != .initialized {
		ls.send_error(jsonrpc.server_not_initialized)
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
		else {
			if ls.status != .initialized {
				ls.send_error(jsonrpc.server_not_initialized)
			}
		}
	}
}

// send dispatches the response data to the subscribed events
fn (mut ls Vls) send(data string) {
	if data.len == 0 {
		if ls.test_mode {
			ls.response = ''
		}

		return
	}

	if ls.test_mode {
		ls.response = data
	} else {
		response := 'Content-Length: ${data.len}\r\n\r\n$data'
		ls.eb.publish('response', ls, response.str)
	}
}

pub fn (ls Vls) subscriber() eventbus.Subscriber {
	return *ls.eb.subscriber
}

pub enum ServerStatus {
	off
	initialized
	shutdown
}

// status returns the current status of the server
fn (ls Vls) status() ServerStatus {
	return ls.status
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

// send_error
pub fn (mut ls Vls) send_error(code int) {
	err := new_error(code)
	ls.send(err)
}
