module log

// import time
import json

// const current_time = time.now()

struct TestLogItem {
	kind    string
	message string
	// timestamp time.Time
}

fn test_notification_send() {
	mut lg := new(.json)

	lg.notification('"Hello!"', .send)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) or {
		eprintln(err.msg)
		assert false
		return
	}

	assert result.kind == 'send-notification'
	assert result.message == 'Hello!'
	// assert result.timestamp == current_time
}

fn test_notification_receive() {
	mut lg := new(.json)

	lg.notification('"Received!"', .receive)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) or {
		eprintln(err.msg)
		assert false
		return
	}

	assert result.kind == 'recv-notification'
	assert result.message == 'Received!'
	// assert result.timestamp == current_time
}

fn test_request_send() {
	mut lg := new(.json)

	lg.request('"Request sent."', .send)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) or {
		eprintln(err.msg)
		assert false
		return
	}

	assert result.kind == 'send-request'
	assert result.message == 'Request sent.'
	// assert result.timestamp == current_time
}

fn test_request_receive() {
	mut lg := new(.json)

	lg.request('"Request received."', .receive)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) or {
		eprintln(err.msg)
		assert false
		return
	}

	assert result.kind == 'recv-request'
	assert result.message == 'Request received.'
	// assert result.timestamp == current_time
}

fn test_response_send() {
	mut lg := new(.json)

	lg.response('"Response sent."', .send)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) or {
		eprintln(err.msg)
		assert false
		return
	}

	assert result.kind == 'send-response'
	assert result.message == 'Response sent.'
	// assert result.timestamp == current_time
}

fn test_response_receive() {
	mut lg := new(.json)

	lg.response('"Response received."', .receive)
	buf := lg.buffer.str()
	result := json.decode(TestLogItem, buf) or {
		eprintln(err.msg)
		assert false
		return
	}

	assert result.kind == 'recv-response'
	assert result.message == 'Response received.'
	// assert result.timestamp == current_time
}
