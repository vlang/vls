module server_test_utils

import jsonrpc
import json
import datatypes

pub struct TestClient {
mut:
	id int
	stream &TestStream
	server &jsonrpc.Server
}

pub fn (mut tc TestClient) send<T,U>(method string, params T) ?U {
	if tc.stream.resp_buf.len != 0 {
		tc.stream.resp_buf.clear()
	}

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

pub struct TestStream {
mut:
	resp_buf []u8
	req_buf datatypes.Queue<[]u8>
}

pub fn (mut rw TestStream) read(mut buf []u8) ?int {
	req := rw.req_buf.pop() ?
	buf << req
	return req.len
}

pub fn (mut rw TestStream) write(buf []u8) ?int {
	rw.resp_buf << buf
	return buf.len
}

pub fn (mut rw TestStream) send(req jsonrpc.Request) {
	req_json := req.json()
	rw.req_buf.push('Content-Length: $req_json.len\r\n\r\n$req_json'.bytes())
}

pub fn (mut rw TestStream) response_text() string {
	return rw.resp_buf.bytestr()
}

// for primitive types
pub struct RpcResult<T> {
	result T
}
