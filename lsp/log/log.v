module log

import os
import time
import json

pub enum Format {
	json
	text
}

pub struct Log {
mut:
	file os.File
	format Format = .json
pub mut:
	file_path string
	opened bool
	cur_requests map[int]string = map[int]string{}
}

const (
	send_notification = 'send-notification'
	recv_notification = 'recv-notification'
	send_request = 'send-request'
	recv_request = 'recv-request'
	send_response = 'send-response'
	recv_response = 'recv-response'
)

pub enum TransportKind {
	send
	receive
}

struct Payload {
	id int
	method string
	result string [raw]
	params string [raw]
}

pub struct LogItem {
	@type string
	message string
	method string
	timestamp time.Time // unix timestamp
}

pub fn new(path string, format Format) Log {
	file := os.open_append(os.real_path(path)) or {
		panic(err)
	}

	return Log{
		file: file
		file_path: path
		format: format
		opened: true
	}
}

pub fn (mut l Log) flush() {
	l.file.flush()
}

pub fn (mut l Log) close() {
	l.opened = false
	l.file.close()
}

fn (mut l Log) write(item LogItem) {
	if !l.opened {
		return
	}

	match l.format {
		.json {
			l.file.writeln(item.json() + '\r') or { panic(err) }
		}
		.text {
			l.file.writeln(item.text() + '\n\n') or { panic(err) }
		}
	}
}

pub fn (mut l Log) request(msg string, kind TransportKind) {
	kind_str := match kind {
		.send { log.send_request }
		.receive { log.recv_request }
	}

	mut req_method := ''
	payload := json.decode(Payload, msg) or { Payload{} }
	if kind == .receive {
		l.cur_requests[payload.id] = payload.method
	} else {
		req_method = l.cur_requests[payload.id] or { '' }
		l.cur_requests.delete(payload.id.str())
	}

	l.write({@type: kind_str, message: msg, method: req_method, timestamp: time.now()})
}

pub fn (mut l Log) response(msg string, kind TransportKind) {
	kind_str := match kind {
		.send { log.send_response }
		.receive { log.recv_response }
	}

	l.write({@type: kind_str, message: msg, timestamp: time.now()})
}

pub fn (mut l Log) notification(msg string, kind TransportKind) {
	kind_str := match kind {
		.send { log.send_notification }
		.receive { log.recv_notification }
	}

	l.write({@type: kind_str, message: msg, timestamp: time.now()})
}

pub fn (li LogItem) json() string {
	return '{"kind":"${li.@type}","message":${li.message},"timestamp":${li.timestamp.unix}}'
}

pub fn (li LogItem) text() string {
	payload := json.decode(Payload, li.message) or { Payload{} }

	method := if li.method.len != 0 { li.method } else { payload.method }
	message := match li.@type {
		log.send_notification { 'Sending notification \'$method\'.' }
		log.recv_notification { 'Received notification \'$method\'.' }
		log.send_request { 'Sending request \'$method - (${payload.id})\'.' }
		log.recv_request { 'Received request \'$method - (${payload.id})\'.' }
		log.send_response { 'Sending response \'$method - (${payload.id})\'. Process request took 0ms' }
		log.recv_response { 'Received response \'$method - (${payload.id})\' in 0ms.' }
		else { '' }
	}

	params_msg := if li.message == 'null' { 
		'No result returned.' 
	}	else if li.@type == log.send_response || li.@type == log.recv_response { 
		'Result: ${li.message}'
	} else {
		'Params: ${li.message}'
	}
	return '[Trace - ${li.timestamp.hhmmss()}] $message\n$params_msg'
}
