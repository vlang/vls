module testing

import json
import jsonrpc

struct TestResponse {
	jsonrpc string = jsonrpc.version
	id      int
	result  string [raw]
	error   jsonrpc.ResponseError
}

struct TestNotification {
	jsonrpc string = jsonrpc.version
	method  string
	params  string [raw]
}

pub struct Testio {
mut:
	current_req_id    int = 1
	has_decoded       bool
	response          TestResponse // parsed response data from raw_response
pub mut:
	raw_response     string // raw JSON string of the response data
}

pub fn (mut io Testio) send(data string) {
	io.has_decoded = false
	io.raw_response = data
}

pub fn (io Testio) receive() ?string {
	return ''
}

// request returns a JSON string of JSON-RPC request with empty parameters
pub fn (mut io Testio) request(method string) string {
	return io.request_with_params(method, map[string]string{})
}

// request_with_params returns a JSON string of JSON-RPC request with parameters
pub fn (mut io Testio) request_with_params<T>(method string, params T) string {
	enc_params := json.encode(params)
	payload := '{"jsonrpc":"$jsonrpc.version","id":$io.current_req_id,"method":"$method","params":$enc_params}'
	io.current_req_id++
	return payload
}

// result verifies the response result/notification params
pub fn (mut io Testio) result() string {
	io.decode_response() or {
		return ''
	}
	return io.response.result
}

// notification verifies the parameters of the notification
pub fn (io Testio) notification() ?(string, string) {
	resp := json.decode(TestNotification, io.raw_response) ?
	return resp.method, resp.params
}

// response_error verifies the error code and message from the response
pub fn (mut io Testio) response_error() ?(int, string) {
	io.decode_response() ?
	return io.response.error.code, io.response.error.message
}

fn (mut io Testio) decode_response() ? {
	if !io.has_decoded {
		io.response = json.decode(TestResponse, io.raw_response)?
		io.has_decoded = true
	}
}