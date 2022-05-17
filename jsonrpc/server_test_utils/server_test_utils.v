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

pub struct TestClient {
mut:
	id int
	server &jsonrpc.Server
pub mut:
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
	raw_resp := tc.stream.response_text()
	if raw_resp.len == 0 {
		return none
	}

	mut raw_json_content := raw_resp.all_after('"result":')
	raw_json_content = raw_json_content[..raw_json_content.len - 1]
	resp := json.decode(U, raw_json_content) ?
	return resp
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
	resp_idx int
	resp_buf [][]u8 = [][]u8{cap: 10, len: 10}
	req_buf datatypes.Queue<[]u8>
}

pub fn (mut rw TestStream) read(mut buf []u8) ?int {
	req := rw.req_buf.pop() ?
	buf << req
	return req.len
}

pub fn (mut rw TestStream) write(buf []u8) ?int {
	idx := rw.resp_idx % 10
	if rw.resp_buf[idx].len != 0 {
		rw.resp_buf[idx].clear()
	}
	rw.resp_buf[idx] << buf
	rw.resp_idx++
	return buf.len
}

pub fn (mut rw TestStream) send(req jsonrpc.Request) {
	req_json := req.json()
	rw.req_buf.push('Content-Length: $req_json.len\r\n\r\n$req_json'.bytes())
}

pub fn (mut rw TestStream) response_text() string {
	return rw.resp_buf[(rw.resp_idx - 1) % 10].bytestr()
}

pub fn (mut rw TestStream) notification_at<T>(idx int) ?jsonrpc.NotificationMessage<T> {
	raw_json_content := rw.resp_buf[idx].bytestr().all_after('\r\n\r\n')
	return json.decode(jsonrpc.NotificationMessage<T>, raw_json_content)
}

// for primitive types
pub struct RpcResult<T> {
	result T
}
