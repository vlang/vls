module log

import os
import time
import json
import io
import jsonrpc
import strings

pub interface Logger {
mut:
	close()
	flush()
	enable()
	disable()
	request(msg string, kind TransportKind)
	response(msg string, kind TransportKind)
	notification(msg string, kind TransportKind)
	set_logpath(path string) ?
}

const default_log_kind_filter = [
	LogKind.send_notification,
	.recv_notification,
	.send_request,
	.recv_request,
	.send_response,
	.recv_response
]

pub struct LogRecorder {
	filter_kinds   []LogKind = log.default_log_kind_filter
mut:
	file           os.File
	buffer         strings.Builder
	file_opened    bool
	enabled        bool
	last_timestamp time.Time = time.now()
pub mut:
	file_path    string
	cur_requests map[int]string
}

pub enum TransportKind {
	send
	receive
}

struct Payload {
	id     int
	method string
	result string [raw]
	params string [raw]
}

pub enum LogKind {
	send_notification
	recv_notification
	send_request
	recv_request
	send_response
	recv_response
}

pub fn (lk LogKind) str() string {
	return match lk {
		.send_notification { 'send-notification' }
		.recv_notification { 'recv-notification' }
		.send_request { 'send-request' }
		.recv_request { 'recv-request' }
		.send_response { 'send-response' }
		.recv_response { 'recv-response' }
	}
}

pub struct LogItem {
	kind      LogKind
	message   []u8
	method    string
	timestamp time.Time = time.now()
}

// json is a JSON string representation of the log item.
pub fn (li LogItem) encode_json(mut wr io.Writer) ? {
	wr.write('{"kind":"$li.kind","message":'.bytes()) ?
	wr.write(li.message) ?
	wr.write(',"timestamp":$li.timestamp.unix}'.bytes()) ?
}

pub fn new() &LogRecorder {
	return &LogRecorder{
		file_opened: false
		enabled: true
		buffer: strings.new_builder(4096)
	}
}

// set_logpath sets the filepath of the log file and opens the file.
pub fn (mut l LogRecorder) set_logpath(path string) ? {
	if l.file_opened {
		l.close()
	}

	file := os.open_append(os.real_path(path)) ?
	l.file = file
	l.file_path = path
	l.file_opened = true
	l.enabled = true
}

// flush flushes the contents of the log file into the disk.
pub fn (mut l LogRecorder) flush() {
	l.file.flush()
}

// close closes the log file.
pub fn (mut l LogRecorder) close() {
	if !l.file_opened {
		return
	}

	l.file_opened = false
	l.file.close()
}

// enable enables/starts the logging.
pub fn (mut l LogRecorder) enable() {
	l.enabled = true
}

// disable disables/stops the logging.
pub fn (mut l LogRecorder) disable() {
	l.enabled = false
}

const newline = [u8(`\n`)]

// write writes the log item into the log file or in the
// buffer if the file is not opened yet.
[manualfree]
fn (mut l LogRecorder) write(item LogItem) {
	if !l.enabled || item.kind !in l.filter_kinds {
		return
	}
	if l.file_opened {
		if l.buffer.len != 0 {
			unsafe {
				l.file.write_ptr(l.buffer.data, l.buffer.len)
				l.buffer.go_back_to(0)
			}
		}
		item.encode_json(mut l.file) or { eprintln(err) }
		l.file.write(newline) or {}
	} else {
		item.encode_json(mut l.buffer) or { eprintln(err) }
		l.buffer.write(newline) or {}
	}

	l.last_timestamp = item.timestamp
	// unsafe { content.free() }
}

// request logs a request message.
pub fn (mut l LogRecorder) request(msg string, kind TransportKind) {
	req_kind := match kind {
		.send { LogKind.send_request }
		.receive { LogKind.recv_request }
	}

	mut req_method := ''
	if kind == .receive {
		payload := json.decode(Payload, msg) or { Payload{} }
		l.cur_requests[payload.id] = payload.method
		req_method = payload.method
	}

	l.write(kind: req_kind, message: msg.bytes(), method: req_method)
}

// notification logs a notification message.
pub fn (mut l LogRecorder) notification(msg string, kind TransportKind) {
	notif_kind := match kind {
		.send { LogKind.send_notification }
		.receive { LogKind.recv_notification }
	}

	l.write(kind: notif_kind, message: msg.bytes())
}

// response logs a response message.
pub fn (mut l LogRecorder) response(msg string, kind TransportKind) {
	resp_kind := match kind {
		.send { LogKind.send_response }
		.receive { LogKind.recv_response }
	}

	payload := json.decode(Payload, msg) or { Payload{} }
	mut resp_method := ''
	if payload.id in l.cur_requests {
		resp_method = l.cur_requests[payload.id]
		l.cur_requests.delete(payload.id)
	}

	l.write(kind: resp_kind, message: msg.bytes(), method: resp_method)
}

// as a JSON-RPC interceptor
const event_prefix = 'lspLogger'

pub const set_logpath_event = '$event_prefix/setLogpath'
pub const close_event = '$event_prefix/close'
pub const state_event = '$event_prefix/state'

pub fn (mut l LogRecorder) on_event(name string, data jsonrpc.InterceptorData) ? {
	if name == log.set_logpath_event && data is string {
		l.set_logpath(data) ?
	} else if name == log.close_event {
		l.close()
	} else if name == log.state_event && data is bool {
		if data {
			l.enable()
		} else {
			l.disable()
		}
	}
}

pub fn (l &LogRecorder) on_raw_request(req []u8) ? {}

pub fn (l &LogRecorder) on_raw_response(raw_resp []u8) ? {}

pub fn (mut l LogRecorder) on_request(req &jsonrpc.Request) ? {
	mut log_kind := LogKind.recv_request
	mut req_method := req.method
	if req.id.len == 0 {
		req_method = ''
		log_kind = .recv_notification
	}
	l.write(kind: log_kind, message: req.json().bytes(), method: req_method)
}

pub fn (mut l LogRecorder) on_encoded_response(resp []u8) {
	l.response(resp.bytestr(), .send)
}
