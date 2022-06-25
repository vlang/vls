// Copyright (c) 2022 Ned Palacios. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module jsonrpc

import json
import jsonrpc
import strings
import io

pub const version = '2.0'

// see
// - https://www.jsonrpc.org/specification#error_object
// - http://xmlrpc-epi.sourceforge.net/specs/rfc.fault_codes.php
pub const (
	// Invalid JSON was received by the server.
	// An error occurred on the server while parsing the JSON text.
	parse_error            = error_with_code('Invalid JSON.', -32700)
	// The JSON sent is not a valid Request object.
	invalid_request        = error_with_code('Invalid request.', -32600)
	// The method does not exist / is not available.
	method_not_found       = error_with_code('Method not found.', -32601)
	// Invalid method parameter(s).
	invalid_params         = error_with_code('Invalid params', -32602)
	// Internal JSON-RPC error.
	internal_error         = error_with_code('Internal error.', -32693)
	// Server errors.
	server_error_start     = error_with_code('Error occurred when starting server.', -32099)
	server_not_initialized = error_with_code('Server not initialized.', -32002)
	unknown_error          = error_with_code('Unknown error.', -32001)
	server_error_end       = error_with_code('Error occurred when stopping the server.', -32000)
	error_codes            = [
		parse_error.code(), 
		invalid_request.code(), 
		method_not_found.code(), 
		invalid_params.code(), 
		internal_error.code(),
		server_error_start.code(),
		server_not_initialized.code(),
		server_error_end.code(),
		unknown_error.code()
	]
)

// Null represents the null value in JSON.
pub struct Null {}

pub const null = Null{}

// Request is a representation of a rpc call to the server.
// https://www.jsonrpc.org/specification#request_object
pub struct Request {
pub mut:
	jsonrpc string = jsonrpc.version
	id      string [raw]
	method  string
	params  string [raw]
}

// json returns the JSON string form of the Request.
pub fn (req Request) json() string {
	// NOTE: make request act as a notification for server_test_utils
	id_payload := if req.id.len != 0 { ',"id":$req.id,' } else { ',' }
	return '{"jsonrpc":"$jsonrpc.version"$id_payload"method":"$req.method","params":$req.params}'
}

// decode_params decodes the parameters of a Request.
pub fn (req Request) decode_params<T>() ?T {
	return json.decode(T, req.params)
}

// Response is a representation of server reply after an rpc call was made.
// https://www.jsonrpc.org/specification#response_object
pub struct Response<T> {
pub:
	jsonrpc string = jsonrpc.version
	id      string
	//	error   ResponseError
	result T
	error  ResponseError
}

// json returns the JSON string form of the Response<T>
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
		$if T is Null {
			writer.write(null_in_u8) or {}
		} $else {
			res := json.encode(resp.result)
			writer.write(res.bytes()) or {}
		}
	}
	writer.write([u8(`}`)]) or {}
}

// NotificationMessage is a Request object without the ID. A Request object that is a
// Notification signifies the Client's lack of interest in the corresponding Response object,
// and as such no Response object needs to be returned to the client. The Server MUST NOT reply
// to a Notification, including those that are within a batch request.
//
// Notifications are not confirmable by definition, since they do not have a Response object to be
// returned. As such, the Client would not be aware of any errors (like e.g. "Invalid params","Internal error").
// https://www.jsonrpc.org/specification#notification
pub struct NotificationMessage<T> {
pub:
	jsonrpc string = jsonrpc.version
	method  string
	params  T
}

// json returns the JSON string form of the NotificationMessage.
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
	$if T is Null {
		writer.write(null_in_u8) or {}
	} $else {
		res := json.encode(notif.params)
		writer.write(res.bytes()) or {}
	}
	writer.write([u8(`}`)]) or {}
}

// ResponseError is a representation of an error when a rpc call encounters an error.
//When a rpc call encounters an error, the Response Object MUST contain the error member
// with a value that is a Object with the following members:
// https://www.jsonrpc.org/specification#error_object
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

// err returns the ResponseError as an implementation of IError.
pub fn (e ResponseError) err() IError {
	return IError(e)
}

[params]
pub struct ResponseErrorGeneratorParams {
	error IError [required]
	data  string
}

// response_error creates a ResponseError from the given IError.
[inline]
pub fn response_error(params ResponseErrorGeneratorParams) ResponseError {
	return ResponseError{
		code: params.error.code()
		message: params.error.msg()
		data: params.data
	}
}
