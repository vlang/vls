module jsonrpc

import json
import strings

pub const (
	// see http://xmlrpc-epi.sourceforge.net/specs/rfc.fault_codes.php
	version                = '2.0'
	parse_error            = -32700
	//
	invalid_request        = -32600
	method_not_found       = -32601
	invalid_params         = -32602
	//
	internal_error         = -32693
	//
	server_error_start     = -32099
	server_not_initialized = -32002
	unknown_error          = -32001
	server_error_end       = -32000
)

pub struct Request {
pub mut:
	jsonrpc string = jsonrpc.version
	id      string [raw]
	method  string
	params  string [raw]
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
	resp_wr.write_string('{"jsonrpc":"$jsonrpc.version","id":$resp.id')
	if resp.id.len == 0 {
		resp_wr.write_string('null')
	}
	if resp.error.code != 0 {
		err := json.encode(resp.error)
		resp_wr.write_string(',"error":$err')
	} else {
		res := json.encode(resp.result)
		resp_wr.write_string(',"result":$res')
	}
	resp_wr.write_byte(`}`)
	return resp_wr.str()
}

pub struct NotificationMessage<T> {
	jsonrpc string = jsonrpc.version
	method  string
	params  T
}

pub fn (notif NotificationMessage<T>) json() string {
	return json.encode(notif)
}

pub struct ResponseError {
pub mut:
	code    int
	message string
	data    string
}

[inline]
pub fn new_response_error(err_code int) ResponseError {
	return ResponseError{
		code: err_code
		message: err_message(err_code)
	}
}

pub fn err_message(err_code int) string {
	// can't use error consts in match
	if err_code == jsonrpc.parse_error {
		return 'Invalid JSON.'
	} else if err_code == jsonrpc.invalid_params {
		return 'Invalid params.'
	} else if err_code == jsonrpc.invalid_request {
		return 'Invalid request.'
	} else if err_code == jsonrpc.method_not_found {
		return 'Method not found.'
	} else if err_code == jsonrpc.server_error_start {
		return 'An error occurred while starting the server.'
	} else if err_code == jsonrpc.server_error_end {
		return 'An error occurred while stopping the server.'
	} else if err_code == jsonrpc.server_not_initialized {
		return 'Server not yet initialized.'
	}
	return 'Unknown error.'
}
