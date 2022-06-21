module log

import json

struct TestLogItem {
	kind    string
	message string
}

fn test_notification_send() ? {
	mut lg := new()

	lg.notification('"Hello!"', .send)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf)?

	assert result.kind == 'send-notification'
	assert result.message == 'Hello!'
}

fn test_notification_receive() ? {
	mut lg := new()

	lg.notification('"Received!"', .receive)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf)?

	assert result.kind == 'recv-notification'
	assert result.message == 'Received!'
}

fn test_request_send() ? {
	mut lg := new()

	lg.request('"Request sent."', .send)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf)?

	assert result.kind == 'send-request'
	assert result.message == 'Request sent.'
}

fn test_request_receive() ? {
	mut lg := new()

	lg.request('"Request received."', .receive)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf)?

	assert result.kind == 'recv-request'
	assert result.message == 'Request received.'
}

fn test_response_send() ? {
	mut lg := new()

	lg.response('"Response sent."', .send)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf)?

	assert result.kind == 'send-response'
	assert result.message == 'Response sent.'
}

fn test_response_receive() ? {
	mut lg := new()

	lg.response('"Response received."', .receive)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf)?

	assert result.kind == 'recv-response'
	assert result.message == 'Response received.'
}
