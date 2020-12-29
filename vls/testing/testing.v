module testing

import json
import jsonrpc

struct TestResponse {
	jsonrpc string = jsonrpc.version
	id 			int
	result 	string [raw]
	error   jsonrpc.ResponseError
}

// NB: map[string]string doesn't work for some reason
// aka cannot use type `map[string]string` as type `T` in argument 2
struct EmptyParam {}

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
	payload := '{"jsonrpc":"${jsonrpc.version}","id":$io.current_req_id,"params":{}}'
	io.current_req_id++
	return payload
}

pub fn (mut io Testio) request_with_params<T>(method string, params T) string {
	payload := jsonrpc.Request<T>{
		id: io.current_req_id
		params: params
	}
	io.current_req_id++
	return json.encode(payload)
}

// NB: unfortunately, it does not work as a generic struct method right now
pub fn assert_response<T>(io Testio, payload T) {
	expected := json.encode(payload)
	resp := json.decode(TestResponse, io.response) or {
		assert false
		return
	}

	assert resp.result == expected
}

pub fn (io Testio) assert_error(code int, message string) {
	resp := json.decode(TestResponse, io.response) or {
		assert false
		return
	}

	assert resp.error.code == code
	assert resp.error.message == message
}

