module server_test_utils

import jsonrpc
import json
import datatypes

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

struct TestResponse {
	raw_id string [raw; json:id]
	raw_result string [raw; json:result]
}

pub struct TestClient {
mut:
	id int
pub mut:
	server &jsonrpc.Server
	stream &TestStream
}

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
	if raw_json_content.len == 0 {
		return none
	}
	return json.decode(U, raw_json_content)
}

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

pub struct TestStream {
mut:
	notif_idx int
	notif_buf [][]u8 = [][]u8{cap: 10, len: 10}
	resp_buf  map[string]TestResponse
	req_buf datatypes.Queue<[]u8>
}

pub fn (mut rw TestStream) read(mut buf []u8) ?int {
	req := rw.req_buf.pop() ?
	buf << req
	return req.len
}

pub fn (mut rw TestStream) write(buf []u8) ?int {
	raw_json_content := buf.bytestr().all_after('\r\n\r\n')
	if raw_json_content.contains('"result":') {
		resp := json.decode(TestResponse, raw_json_content) ?
		rw.resp_buf[resp.raw_id] = resp
	} else if raw_json_content.contains('"params":') {
		idx := rw.notif_idx % 10
		if rw.notif_buf[idx].len != 0 {
			rw.notif_buf[idx].clear()
		}
		rw.notif_buf[idx] << buf
		rw.notif_idx++
	} else {
		return none
	}
	return buf.len
}

pub fn (mut rw TestStream) send(req jsonrpc.Request) {
	req_json := req.json()
	rw.req_buf.push('Content-Length: $req_json.len\r\n\r\n$req_json'.bytes())
}

pub fn (rw &TestStream) response_text(raw_id string) string {
	return rw.resp_buf[raw_id].raw_result
}

pub fn (rw &TestStream) notification_at<T>(idx int) ?jsonrpc.NotificationMessage<T> {
	raw_json_content := rw.notif_buf[idx].bytestr().all_after('\r\n\r\n')
	return json.decode(jsonrpc.NotificationMessage<T>, raw_json_content)
}

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

// for primitive types
pub struct RpcResult<T> {
	result T
}
