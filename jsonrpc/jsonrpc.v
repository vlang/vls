module jsonrpc

import json
import jsonrpc
import strings
import io

pub const (
	// see https://www.jsonrpc.org/specification#error_object
	version                = '2.0'
	parse_error            = error_with_code('Invalid JSON.', -32700)
	//
	invalid_request        = error_with_code('Invalid request.', -32600)
	method_not_found       = error_with_code('Method not found.', -32601)
	invalid_params         = error_with_code('Invalid params', -32602)
	//
	internal_error         = error_with_code('Internal error.', -32693)
	//
	server_error_start     = error_with_code('Error occurred when starting server.', -32099)
	server_not_initialized = error_with_code('Server not initialized.', -32002)
	unknown_error          = error_with_code('Unknown error.', -32001)
	server_error_end       = error_with_code('Error occurred when stopping the server.', -32000)
)

struct Null {}

pub const null = Null{}

pub struct Request {
pub mut:
	jsonrpc string = jsonrpc.version
	id      string [raw]
	method  string
	params  string [raw]
}

pub fn (req Request) json() string {
	return '{"jsonrpc":"$jsonrpc.version","id":$req.id,"method":"$req.method","params":$req.params}'
}

pub fn (req Request) decode_params<T>() ?T {
	return json.decode(T, req.params)
}

pub struct Response<T> {
pub:
	jsonrpc string = jsonrpc.version
	id      string
	//	error   ResponseError
	result T
	error  ResponseError
}

pub fn (resp Response<T>) json() string {
	mut resp_wr := strings.new_builder(100)
	defer {
		unsafe { resp_wr.free() }
	}
	encode_response<T>(resp, mut resp_wr)
	return resp_wr.str()
}

const null_in_u8 = 'null'.bytes()
const error_field_in_u8 = ',"error":'.bytes()
const result_field_in_u8 = ',"result":'.bytes()

fn encode_response<T>(resp Response<T>, mut writer io.Writer) {
	writer.write('{"jsonrpc":"$jsonrpc.version","id":'.bytes()) or {}
	if resp.id.len == 0 {
		writer.write(null_in_u8) or {}
	} else {
		writer.write(resp.id.bytes()) or {}
	}
	if resp.error.code != 0 {
		err := json.encode(resp.error)
		writer.write(error_field_in_u8) or {}
		writer.write(err.bytes()) or {}
	} else {
		writer.write(result_field_in_u8) or {}
		if typeof(resp.result).name == 'jsonrpc.Null' {
			writer.write(null_in_u8) or {}
		} else {
			res := json.encode(resp.result)
			writer.write(res.bytes()) or {}
		}
	}
	writer.write([u8(`}`)]) or {}
}

pub struct NotificationMessage<T> {
	jsonrpc string = jsonrpc.version
	method  string
	params  T
}

pub fn (notif NotificationMessage<T>) json() string {
	mut notif_wr := strings.new_builder(100)
	defer {
		unsafe { notif_wr.free() }
	}
	encode_notification<T>(notif, mut notif_wr)
	return notif_wr.str()
}

fn encode_notification<T>(notif jsonrpc.NotificationMessage<T>, mut writer io.Writer) {
	writer.write('{"jsonrpc":"$jsonrpc.version","method":"$notif.method","params":'.bytes()) or {}
	$if notif.params is Null {
		writer.write(null_in_u8) or {}
	} $else {
		res := json.encode(notif.params)
		writer.write(res.bytes()) or {}
	}
	writer.write([u8(`}`)]) or {}
}

pub struct ResponseError {
pub mut:
	code    int
	message string
	data    string
}

pub fn (err ResponseError) code() int {
	return err.code
}

pub fn (err ResponseError) msg() string {
	return err.message
}

pub fn (e ResponseError) err() IError {
	return IError(e)
}

[inline]
pub fn response_error(err IError) ResponseError {
	return ResponseError{
		code: err.code()
		message: err.msg()
	}
}
