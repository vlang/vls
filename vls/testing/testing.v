module testing

import json
import jsonrpc

struct TestResponse {
	jsonrpc string = jsonrpc.version
	id 			int
	result 	string [raw]
	params  string [raw] // for notification
	error   jsonrpc.ResponseError
}

pub struct Testio {
mut:
	current_req_id int = 1
pub mut:
	response string
}

pub fn (mut io Testio) send(data string) {
	io.response = data
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

// assert_response verifies the response result/notification params
pub fn (io Testio) assert_response<T>(payload T) {
	expected := json.encode(payload)
	resp := json.decode(TestResponse, io.response) or {
		assert false
		return
	}
	if resp.params.len > 0 {
		assert resp.result.len == 0
		assert resp.params == expected
	} else {
		assert resp.params.len == 0
		assert resp.result == expected
	}
}

// assert_error verifies the error code and message from the response
pub fn (io Testio) assert_error(code int, message string) {
	resp := json.decode(TestResponse, io.response) or {
		assert false
		return
	}
	assert resp.error.code == code
	assert resp.error.message == message
}

