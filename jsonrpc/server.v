module jsonrpc

import json
import strings
import io

[heap]
pub struct Server {
mut:
	// internal fields
	req_buf strings.Builder = strings.new_builder(200)
	conlen_buf strings.Builder = strings.new_builder(200)
	res_buf strings.Builder = strings.new_builder(200)
pub mut:
	stream  io.ReaderWriter
	interceptors []Interceptor
	handler Handler
}

pub fn (mut s Server) intercept_raw_request(req []u8) ? {
	for mut interceptor in s.interceptors {
		interceptor.on_raw_request(req) ?
	}
}

pub fn (mut s Server) intercept_request(req &Request) ? {
	for mut interceptor in s.interceptors {
		interceptor.on_request(req) ?
	}
}

pub fn (mut s Server) intercept_encoded_response(resp []u8) {
	for mut interceptor in s.interceptors {
		interceptor.on_encoded_response(resp)
	}
}

pub interface InterceptorData {}

pub fn (mut s Server) dispatch_event(event_name string, data InterceptorData) ? {
	for mut i in s.interceptors {
		i.on_event(event_name, data) ?
	}
}

fn (s Server) process_raw_request(raw_request string) ?Request {
	json_payload := raw_request.all_after('\r\n\r\n')
	return json.decode(Request, json_payload)
}

// for testing purposes only
pub fn (mut s Server) respond() ? {
	mut base_rw := s.writer()
	return s.internal_respond(mut base_rw)
}

fn (mut s Server) internal_respond(mut base_rw ResponseWriter) ? {
	s.stream.read(mut s.req_buf) or {
		unsafe { s.req_buf.free() }
		return err
	}

	req := s.process_raw_request(s.req_buf.str()) or {
		base_rw.write_error(response_error(parse_error))
		return err
	}

	s.intercept_request(&req) or {
		base_rw.write_error(response_error(err))
		return err
	}

	mut rw := ResponseWriter{
		server: s
		writer: base_rw.writer
		sb: base_rw.sb
		clen_sb: base_rw.clen_sb
		req_id: req.id
	}

	s.handler.handle_jsonrpc(&req, mut rw) or {
		if err is ResponseError {
			rw.write_error(err)
		} else {
			rw.write_error(response_error(unknown_error))
		}
		return err
	}
}

pub fn (s &Server) writer() ResponseWriter {
	// NOTE: writing content lengths should be an interceptor
	// since there are some situations that a payload is only
	// passthrough between processes and does not need a
	// "repackaging" of the outgoing data
	return ResponseWriter{
		server: s
		writer: io.MultiWriter{
			writers: [
				InterceptorWriter{
					interceptors: s.interceptors
				},
				Writer{
					read_writer: s.stream
				}
			]
		}
		sb: s.res_buf
		clen_sb: s.conlen_buf
	}
}

pub fn (mut s Server) start() {
	mut rw := s.writer()
	for {
		s.internal_respond(mut rw) or {
			continue
		}
	}
}

pub interface Interceptor {
mut:
	on_event(name string, data InterceptorData) ?
	on_raw_request(req []u8) ?
	on_request(req &Request) ?
	on_encoded_response(resp []u8) // we cant use generic methods without marking the interface as generic
}

pub interface Handler {
mut:
	handle_jsonrpc(req &Request, mut wr ResponseWriter) ?
}

pub struct ResponseWriter {
	req_id string = 'null' // raw JSON
mut:
	clen_sb strings.Builder
	sb     strings.Builder
pub mut:
	server  &Server
	writer io.Writer
}

fn (mut rw ResponseWriter) close() {
	rw.clen_sb.write_string('Content-Length: $rw.sb.len\r\n\r\n')
	rw.clen_sb.write(rw.sb) or {}
	rw.writer.write(rw.clen_sb) or {}
	rw.sb.go_back_to(0)
	rw.clen_sb.go_back_to(0)
}

pub fn (mut rw ResponseWriter) write<T>(payload T) {
	final_resp := jsonrpc.Response<T>{
		id: rw.req_id
		result: payload
	}
	encode_response<T>(final_resp, mut rw.sb)
	rw.close()
}

pub fn (mut rw ResponseWriter) write_notify<T>(method string, params T) {
	notif := jsonrpc.NotificationMessage<T>{
		method: method
		params: params
	}
	encode_notification<T>(notif, mut rw.sb)
	rw.close()
}

pub fn (mut rw ResponseWriter) write_error(err &ResponseError) {
	final_resp := jsonrpc.Response<string>{
		id: rw.req_id
		error: err
	}
	encode_response<string>(final_resp, mut rw.sb)
	rw.close()
}

struct Writer {
mut:
	read_writer io.ReaderWriter
}

fn (mut w Writer) write(byt []u8) ?int {
	return w.read_writer.write(byt)
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

pub struct PassiveHandler {}

fn (mut h PassiveHandler) handle_jsonrpc(req &Request, mut rw ResponseWriter) ? {}

pub fn is_interceptor_enabled<T>(server &Server) bool {
	for inter in server.interceptors {
		if inter is T {
			return true
		}
	}
	return false
}
