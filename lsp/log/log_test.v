module log

import json

struct TestLogItem {
	kind    string
	payload string
}

fn test_notification_send() ? {
	mut lg := new()

	lg.log(kind: .send_notification, payload: '"Hello!"'.bytes())
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) ?

	assert result.kind == 'send-notification'
	assert result.payload == 'Hello!'
}

fn test_notification_receive() ? {
	mut lg := new()

	lg.log(kind: .recv_notification, payload: '"Received!"'.bytes())
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) ?

	assert result.kind == 'recv-notification'
	assert result.payload == 'Received!'
}

fn test_request_send() ? {
	mut lg := new()

	lg.log(kind: .recv_request, payload: '"Request sent."'.bytes())
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) ?

	assert result.kind == 'recv-request'
	assert result.payload == 'Request sent.'
}

fn test_request_receive() ? {
	mut lg := new()

	lg.log(kind: .recv_request, payload: '"Request received."'.bytes())
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) ?

	assert result.kind == 'recv-request'
	assert result.payload == 'Request received.'
}

fn test_response_send() ? {
	mut lg := new()

	lg.log(kind: .send_response, payload: '"Response sent."'.bytes())
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) ?

	assert result.kind == 'send-response'
	assert result.payload == 'Response sent.'
}

fn test_response_receive() ? {
	mut lg := new()

	lg.log(kind: .send_response, payload: '"Response received."'.bytes())
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) ?

	assert result.kind == 'send-response'
	assert result.payload == 'Response received.'
}
