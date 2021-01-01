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

pub fn (mut io Testio) request(method string) string {
	return io.request_with_params(method, map[string]string{})
}

pub fn (mut io Testio) request_with_params<T>(method string, params T) string {
	enc_params := json.encode(params)
	payload := '{"jsonrpc":"$jsonrpc.version","id":$io.current_req_id,"method":"$method","params":$enc_params}'
	io.current_req_id++
	return payload
}

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

pub fn (io Testio) assert_error(code int, message string) {
	resp := json.decode(TestResponse, io.response) or {
		assert false
		return
	}
	assert resp.error.code == code
	assert resp.error.message == message
}

