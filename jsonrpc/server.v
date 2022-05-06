module jsonrpc

import json
import strings
import io

pub struct Server {
mut:
	stream  io.ReaderWriter
	interceptors []Interceptor
	handler Handler

	// internal fields
	req_buf strings.Builder = strings.new_builder(200)
	res_buf strings.Builder = strings.new_builder(200)
}

fn (s Server) process_raw_request(raw_request string) ?Request {
	json_payload := raw_request.all_after('\r\n\r\n')
	return json.decode(Request, json_payload)
}

// for testing purposes only
pub fn (mut s Server) respond() ? {
	mut base_rw := ResponseWriter{
		writer: s.writers()
		sb: s.res_buf
	}

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

	for mut interceptor in s.interceptors {
		interceptor.on_request(&req) or {
			return err
		}
	}

	mut rw := ResponseWriter{
		writer: base_rw.writer
		sb: base_rw.sb
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

fn (s &Server) writers() io.Writer {
	return io.MultiWriter {
		writers: [
			InterceptorWriter{
				interceptors: s.interceptors
			},
			Writer{
				read_writer: s.stream
			}
		]
	}
}

pub fn (mut s Server) start() {
	mut base_rw := ResponseWriter{
		writer: s.writers()
		sb: s.res_buf
	}

	for {
		s.internal_respond(mut base_rw) or {
			continue
		}
	}
}

pub interface Interceptor {
mut:
	on_request(req &Request) ?
	on_encoded_response(resp []u8) // we cant use generic methods without marking the interface as generic
}

pub interface Handler {
mut:
	handle_jsonrpc(req &Request, mut wr ResponseWriter) ?
}

pub struct ResponseWriter {
	req_id string = 'null' // raw JSON
	writer io.Writer
	sb     strings.Builder
}

pub fn (rw ResponseWriter) write<T>(payload T) {
	final_resp := jsonrpc.Response<T>{
		id: rw.req_id
		result: payload
	}

	mut wr := rw.writer
	mut builder := rw.sb
	defer { unsafe { builder.free() } }

	encode_response<T>(final_resp, mut builder)
	write_response(builder.clone(), mut wr)
}

pub fn write_response(buf []u8, mut wr io.Writer) {
	wr.write('Content-Length: $buf.len\r\n\r\n'.bytes()) or {}
	wr.write(buf) or {}
}

pub fn (rw ResponseWriter) write_error(err &ResponseError) {
	final_resp := jsonrpc.Response<string>{
		id: rw.req_id
		error: err
	}

	mut wr := rw.writer
	mut builder := rw.sb
	defer { unsafe { builder.free() } }

	encode_response<string>(final_resp, mut builder)
	write_response(builder, mut wr)
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
	is_conlen bool = true
	interceptors []Interceptor
}

fn (mut wr InterceptorWriter) write(buf []u8) ?int {
	if wr.is_conlen {
		wr.is_conlen = false
		return 0
	}

	for mut interceptor in wr.interceptors {
		interceptor.on_encoded_response(buf)
	}
	return buf.len
}
