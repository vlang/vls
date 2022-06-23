// Copyright (c) 2022 Ned Palacios. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module server_test_utils

import jsonrpc
import json
import datatypes

// new_test_client creates a test client to be used for observing responses
// and notifications from the given handler and interceptors
pub fn new_test_client(handler jsonrpc.Handler, interceptors ...jsonrpc.Interceptor) &TestClient {
	mut stream := &TestStream{}
	mut server := &jsonrpc.Server{
		handler: handler
		interceptors: interceptors
		stream: stream
	}

	return &TestClient{
		server: server
		stream: stream
	}
}

// TestResponse is a version of jsonrpc.Response<T> that decodes
// incoming JSON as raw JSON string.
struct TestResponse {
	raw_id string [raw; json:id]
	raw_result string [raw; json:result]
}

// TestClient is a JSONRPC Client used for simulating communication between client and
// JSONRPC server. This exposes the JSONRPC server and a test stream for sending data
// as a server or as a client
pub struct TestClient {
mut:
	id int
pub mut:
	server &jsonrpc.Server
	stream &TestStream
}

// send<T,U> sends a request and receives a decoded response result.
pub fn (mut tc TestClient) send<T,U>(method string, params T) ?U {
	params_json := json.encode(params)
	req := jsonrpc.Request{
		id: '$tc.id'
		method: method
		params: params_json
	}

	tc.stream.send(req)
	tc.server.respond() ?
	raw_json_content := tc.stream.response_text(req.id)
	if raw_json_content.len == 0 || raw_json_content == 'null' {
		return none
	}
	return json.decode(U, raw_json_content)
}

// notify is a version of send but instead of returning a response,
// it only notifies the server. Effectively sending a request as a 
// notification.
pub fn (mut tc TestClient) notify<T>(method string, params T) ? {
	params_json := json.encode(params)
	req := jsonrpc.Request{
		id: ''
		method: method
		params: params_json
	}

	tc.stream.send(req)
	tc.server.respond() ?
}

// TestStream is a io.ReadWriter-compliant stream for sending
// and receiving responses from between the client and the server.
// Aside from being a ReaderWriter, it exposes additional methods
// for decoding JSONRPC response and notifications.
pub struct TestStream {
mut:
	notif_idx int
	notif_buf [][]u8 = [][]u8{cap: 20, len: 20}
	resp_buf  map[string]TestResponse
	req_buf datatypes.Queue<[]u8>
}

// read receives the incoming request buffer.
pub fn (mut rw TestStream) read(mut buf []u8) ?int {
	req := rw.req_buf.pop() ?
	buf << req
	return req.len
}

// write receives the outgoing response/notification buffer.
pub fn (mut rw TestStream) write(buf []u8) ?int {
	raw_json_content := buf.bytestr().all_after('\r\n\r\n')
	if raw_json_content.contains('"result":') {
		resp := json.decode(TestResponse, raw_json_content) ?
		rw.resp_buf[resp.raw_id] = resp
	} else if raw_json_content.contains('"params":') {
		idx := rw.notif_idx % 20
		for i := idx + 1; i < rw.notif_buf.len; i++ {
			if rw.notif_buf[i].len != 0 {
				rw.notif_buf[idx].clear()
			}
		} 
		rw.notif_buf[idx] << buf
		rw.notif_idx++
	} else {
		return none
	}
	return buf.len
}

// send stringifies and dispatches the jsonrpc.Request into the request queue.
pub fn (mut rw TestStream) send(req jsonrpc.Request) {
	req_json := req.json()
	rw.req_buf.push('Content-Length: $req_json.len\r\n\r\n$req_json'.bytes())
}

// response_text returns the raw response result of the given request id.
pub fn (rw &TestStream) response_text(raw_id string) string {
	return rw.resp_buf[raw_id].raw_result
}

// notification_at returns the jsonrpc.Notification<T> in a given index.
pub fn (rw &TestStream) notification_at<T>(idx int) ?jsonrpc.NotificationMessage<T> {
	raw_json_content := rw.notif_buf[idx].bytestr().all_after('\r\n\r\n')
	return json.decode(jsonrpc.NotificationMessage<T>, raw_json_content)
}

// last_notification_at_method returns the last jsonrpc.Notification<T> from the given method name.
pub fn (rw &TestStream) last_notification_at_method<T>(method_name string) ?jsonrpc.NotificationMessage<T> {
	for i := rw.notif_buf.len - 1; i >= 0; i-- {
		raw_notif_content := rw.notif_buf[i]
		if raw_notif_content.len == 0 {
			continue
		}

		if raw_notif_content.bytestr().contains('"method":"$method_name"') {
			return rw.notification_at<T>(i)
		}
	}
	return none
}

// RpcResult<T> is a result form used for primitive types.
pub struct RpcResult<T> {
	result T
}
