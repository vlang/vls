module test_utils

import json
import jsonrpc

struct Foo {
	hello string
}

fn test_send() {
	mut io := Testio{}
	io.send('request message')
	assert io.raw_responses[0] == 'request message'
}

fn test_request() {
	mut io := Testio{}
	assert io.current_req_id == 1
	payload := io.request('foo')
	assert payload == '{"jsonrpc":"2.0","id":1,"method":"foo","params":{}}'
	assert io.current_req_id == 2
}

fn test_request_with_params() {
	mut io := Testio{}
	param := {
		'hello': 'world'
	}
	payload := io.request_with_params('foo', param)
	assert payload == '{"jsonrpc":"2.0","id":1,"method":"foo","params":{"hello":"world"}}'
	assert io.current_req_id == 2
}

fn test_result() {
	mut io := Testio{}
	result := {
		'hello': 'world'
	}
	resp := jsonrpc.Response<map[string]string>{
		id: '1'
		result: result
	}
	io.send(json.encode(resp))
	assert io.result() == json.encode(result)
}

fn test_notification() ? {
	mut io := Testio{}
	request := json.encode(jsonrpc.NotificationMessage<string>{
		method: 'log'
		params: 'just a log'
	})
	io.send(request)
	method, params := io.notification() ?
	assert method == 'log'
	assert params == '"just a log"'
}

fn test_response_error() ? {
	mut io := Testio{}
	payload := jsonrpc.Response<map[string]string>{
		error: jsonrpc.response_error(error: jsonrpc.method_not_found)
	}
	request := json.encode(payload)
	io.send(request)
	err_code, err_message := io.response_error() ?
	assert err_code == jsonrpc.method_not_found.code()
	assert err_message == jsonrpc.method_not_found.msg()
}
