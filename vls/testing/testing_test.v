module testing

import json
import jsonrpc

fn test_send() {
	mut io := Testio{}
	io.send('request message')
	assert io.response == 'request message'
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
	param := {'hello': 'world'}
	payload := io.request_with_params('foo', param)
	assert payload == '{"jsonrpc":"2.0","id":1,"method":"foo","params":{"hello":"world"}}'
	assert io.current_req_id == 2
}

fn test_assert_response() {
	mut io := Testio{}
	param := {'hello': 'world'}
	request := io.request_with_params('foo', param)
	io.send(request)
	io.assert_response(param)
}

fn test_assert_response_notification() {
	mut io := Testio{}
	request := json.encode(jsonrpc.NotificationMessage<string>{
		method: 'log'
		params: 'just a log'
	})
	io.send(request)
	io.assert_response('just a log')
}

fn test_assert_error() {
	mut io := Testio{}
	payload := jsonrpc.Response2<map[string]string>{
		error: jsonrpc.new_response_error(jsonrpc.method_not_found)
	}
	request := json.encode(payload)
	io.send(request)
	io.assert_error(jsonrpc.method_not_found, 'Method not found.')
}