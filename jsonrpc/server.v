// Copyright (c) 2022 Ned Palacios. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module jsonrpc

import json
import strings
import io

// Server represents a JSONRPC server that sends/receives data
// from a stream (an io.ReaderWriter, inspects data with interceptors
// and hands over the decoded request to a Handler.
[heap]
pub struct Server {
mut:
	// internal fields
	req_buf strings.Builder = strings.new_builder(4096)
	conlen_buf strings.Builder = strings.new_builder(4096)
	res_buf strings.Builder = strings.new_builder(4096)
pub mut:
	stream  io.ReaderWriter
	interceptors []Interceptor
	handler Handler
}

// intercept_raw_request intercepts the incoming raw request buffer
// to the interceptors.
pub fn (mut s Server) intercept_raw_request(req []u8) ? {
	for mut interceptor in s.interceptors {
		interceptor.on_raw_request(req) ?
	}
}

// intercept_raw_request intercepts the incoming decoded JSONRPC Request
// to the interceptors.
pub fn (mut s Server) intercept_request(req &Request) ? {
	for mut interceptor in s.interceptors {
		interceptor.on_request(req) ?
	}
}

// intercept_raw_request intercepts the outgoing raw response buffer
// to the interceptors.
pub fn (mut s Server) intercept_encoded_response(resp []u8) {
	for mut interceptor in s.interceptors {
		interceptor.on_encoded_response(resp)
	}
}

pub interface InterceptorData {}

// dispatch_event sends a custom event to the interceptors.
pub fn (mut s Server) dispatch_event(event_name string, data InterceptorData) ? {
	for mut i in s.interceptors {
		i.on_event(event_name, data) ?
	}
}

// process_raw_request decodes the raw request string into JSONRPC request.
fn (s Server) process_raw_request(raw_request string) ?Request {
	json_payload := raw_request.all_after('\r\n\r\n')
	return json.decode(Request, json_payload)
}

// respond executes the incoming request into a response.
// for testing purposes only.
pub fn (mut s Server) respond() ? {
	mut base_rw := s.writer()
	return s.internal_respond(mut base_rw)
}

fn (mut s Server) internal_respond(mut base_rw ResponseWriter) ? {
	defer { s.req_buf.go_back_to(0) }
	s.stream.read(mut s.req_buf) ?

	req := s.process_raw_request(s.req_buf.after(0)) or {
		base_rw.write_error(response_error(error: parse_error))
		return err
	}

	s.intercept_request(&req) or {
		base_rw.write_error(response_error(error: err))
		return err
	}

	mut rw := ResponseWriter{
		server: s
		writer: base_rw.writer
		sb: base_rw.sb
		req_id: req.id
	}

	s.handler.handle_jsonrpc(&req, mut rw) or {
		// do not send response error if request is a notification
		if req.id.len != 0 {
			if err is none {
				rw.write(null)
			} else if err is ResponseError {
				rw.write_error(err)
			} else if err.code() !in jsonrpc.error_codes {
				rw.write_error(response_error(error: unknown_error))
			} else {
				rw.write_error(response_error(error: err))
			}
		}
		return err
	}
}

[params]
pub struct NewWriterConfig {
	own_buffer bool
}

// writer returns the Server's current ResponseWriter
pub fn (s &Server) writer(cfg NewWriterConfig) &ResponseWriter {
	return &ResponseWriter{
		server: s
		writer: io.MultiWriter{
			writers: [
				InterceptorWriter{
					interceptors: s.interceptors
				},
				// NOTE: writing content lengths should be an interceptor
				// since there are some situations that a payload is only
				// passthrough between processes and does not need a
				// "repackaging" of the outgoing data
				Writer{
					clen_sb: if cfg.own_buffer { s.conlen_buf.clone() } else { s.conlen_buf }
					read_writer: s.stream
				}
			]
		}
		sb: if cfg.own_buffer { s.res_buf.clone() } else { s.res_buf }
	}
}

// start executes a loop and observes the incoming request from the stream.
pub fn (mut s Server) start() {
	mut rw := s.writer()
	for {
		s.internal_respond(mut rw) or {
			continue
		}
	}
}

// Interceptor is an interface that observes and inspects the data
// before handing over to the Handler.
pub interface Interceptor {
mut:
	on_event(name string, data InterceptorData) ?
	on_raw_request(req []u8) ?
	on_request(req &Request) ?
	on_encoded_response(resp []u8) // we cant use generic methods without marking the interface as generic
}

// Handler is an interface that handles the JSONRPC request and
// returns a response data via a ResponseWriter.
pub interface Handler {
mut:
	handle_jsonrpc(req &Request, mut wr ResponseWriter) ?
}

// ResponseWriter constructs and sends a JSONRPC response to the stream.
pub struct ResponseWriter {
mut:
	sb     strings.Builder
pub mut:
	req_id string = 'null' // raw JSON
	server  &Server
	writer io.Writer
}

fn (mut rw ResponseWriter) close() {
	rw.writer.write(rw.sb) or {}
	rw.sb.go_back_to(0)
}

// write sends the given payload to the stream.
pub fn (mut rw ResponseWriter) write<T>(payload T) {
	final_resp := jsonrpc.Response<T>{
		id: rw.req_id
		result: payload
	}
	encode_response<T>(final_resp, mut rw.sb)
	rw.close()
}

// write_notify sends the given method and params as
// a server notification to the stream.
pub fn (mut rw ResponseWriter) write_notify<T>(method string, params T) {
	notif := jsonrpc.NotificationMessage<T>{
		method: method
		params: params
	}
	encode_notification<T>(notif, mut rw.sb)
	rw.close()
}

// write_error sends a ResponseError to the stream.
pub fn (mut rw ResponseWriter) write_error(err &ResponseError) {
	final_resp := jsonrpc.Response<string>{
		id: rw.req_id
		error: err
	}
	encode_response<string>(final_resp, mut rw.sb)
	rw.close()
}

// Writer is an internal representation of a raw response writer.
// It adds a Content-Length header to the response before handing
// over to the io.ReaderWriter.
struct Writer {
mut:
	clen_sb     strings.Builder
	read_writer io.ReaderWriter
}

fn (mut w Writer) write(byt []u8) ?int {
	defer { w.clen_sb.go_back_to(0) }
	w.clen_sb.write_string('Content-Length: $byt.len\r\n\r\n')
	w.clen_sb.write(byt) or {}
	return w.read_writer.write(w.clen_sb)
}

struct InterceptorWriter {
mut:
	interceptors []Interceptor
}

fn (mut wr InterceptorWriter) write(buf []u8) ?int {
	for mut interceptor in wr.interceptors {
		interceptor.on_encoded_response(buf)
	}
	return buf.len
}

// PassiveHandler is an implementation of a Handler
// used as a default value for Server.handler 
pub struct PassiveHandler {}

fn (mut h PassiveHandler) handle_jsonrpc(req &Request, mut rw ResponseWriter) ? {}

// is_intercepter_enabled checks if the given T is enabled in a Server.
pub fn is_interceptor_enabled<T>(server &Server) bool {
	for inter in server.interceptors {
		if inter is T {
			return true
		}
	}
	return false
}
