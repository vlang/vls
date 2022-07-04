module log

import os
import time
import io
import jsonrpc
import strings

pub struct LogRecorder {
mut:
	file           os.File
	buffer         strings.Builder
	file_opened    bool
	enabled        bool
pub mut:
	file_path    string
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
	recv_request
	send_response
}

pub fn (lk LogKind) str() string {
	return match lk {
		.send_notification { 'send-notification' }
		.recv_notification { 'recv-notification' }
		.recv_request { 'recv-request' }
		.send_response { 'send-response' }
	}
}

pub struct LogItem {
	kind      LogKind
	timestamp time.Time = time.now()
	payload   []u8 // raw JSON
}

// json is a JSON string representation of the log item.
pub fn (li LogItem) encode_json(mut wr io.Writer) ? {
	wr.write('{"kind":"$li.kind","timestamp":$li.timestamp.unix,"payload":'.bytes()) ?
	wr.write(li.payload) ?
	wr.write('}\n'.bytes()) ?
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

	l.file = os.open_append(os.real_path(path)) ?
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

// write writes the log item into the log file or in the
// buffer if the file is not opened yet.
[manualfree]
fn (mut l LogRecorder) log(item LogItem) {
	if !l.enabled {
		return
	} else if l.file_opened {
		if l.buffer.len != 0 {
			unsafe {
				l.file.write_ptr(l.buffer.data, l.buffer.len)
				l.buffer.go_back_to(0)
			}
		}
		item.encode_json(mut l.file) or { eprintln(err) }
		l.flush()
	} else {
		item.encode_json(mut l.buffer) or { eprintln(err) }
	}
}

// as a JSON-RPC interceptor
const event_prefix = '$/lspLogger'

pub const set_logpath_event = '$event_prefix/setPath'
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
	log_kind := if req.id.len == 0 {
		LogKind.recv_notification
	} else {
		LogKind.recv_request
	}
	l.log(kind: log_kind, payload: req.json().bytes())
}

pub fn (mut l LogRecorder) on_encoded_response(resp []u8) {
	if 15 < resp.len && 23 < resp.len && resp[15..23].bytestr() == ',"method"' {
		l.log(kind: .send_response, payload: resp)
	} else {
		l.log(kind: .send_notification, payload: resp)
	}
}
