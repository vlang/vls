import jsonrpc
import json
import datatypes

struct TestClient {
mut:
	id int
	stream &TestStream
	server &jsonrpc.Server
}

fn (mut tc TestClient) send<T,U>(method string, params T) ?U {
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

struct TestStream {
mut:
	resp_buf []u8
	req_buf datatypes.Queue<[]u8>
}

fn (mut rw TestStream) read(mut buf []u8) ?int {
	req := rw.req_buf.pop() ?
	buf << req
	return req.len
}

fn (mut rw TestStream) write(buf []u8) ?int {
	rw.resp_buf << buf
	return buf.len
}

fn (mut rw TestStream) send(req jsonrpc.Request) {
	req_json := req.json()
	rw.req_buf.push('Content-Length: $req_json.len\r\n\r\n$req_json'.bytes())
}

fn (mut rw TestStream) response_text() string {
	return rw.resp_buf.bytestr()
}

struct TestHandler {}

struct SumParams {
mut:
	nums []int
}

struct RpcResult<T> {
	result T
}

fn (mut h TestHandler) handle_jsonrpc(req &jsonrpc.Request, mut wr jsonrpc.ResponseWriter) ? {
	match req.method {
		'sum' {
			params := req.decode_params<SumParams>() ?

			mut res := 0
			for n in params.nums {
				res += n
			}

			wr.write(RpcResult<int>{ result: res })
		}
		'hello' {
			wr.write(RpcResult<string>{'Hello world!'})
		}
		else {
			return jsonrpc.response_error(jsonrpc.method_not_found).err()
		}
	}
}

fn test_server() ? {
	mut stream := &TestStream{}
	mut server := &jsonrpc.Server{
		handler: &TestHandler{}
		stream: stream
	}

	mut client := TestClient{
		server: server
		stream: stream
	}

	sum_result := client.send<SumParams, RpcResult<int>>('sum', SumParams{ nums: [1,2,4] }) ?
	assert sum_result.result == 7

	hello_result := client.send<string, RpcResult<string>>('hello', '') ?
	assert hello_result.result == 'Hello world!'

	client.send<string, RpcResult<int>>('multiply', 'test') or {
		assert err.msg() == 'Method not found.'
	}
}

struct TestInterceptor {
mut:
	methods_recv []string
	messages []string
}

fn (mut t TestInterceptor) on_raw_request(req []u8) ? {}

fn (mut t TestInterceptor) on_request(req &jsonrpc.Request) ? {
	t.methods_recv << req.method
}

fn (mut t TestInterceptor) on_encoded_response(resp []u8) {
	t.messages << 'test!'
}

fn test_interceptor() ? {
	mut test_inter := &TestInterceptor{}
	mut stream := &TestStream{}

	mut server := &jsonrpc.Server{
		handler: &TestHandler{}
		interceptors: [test_inter]
		stream: stream
	}

	mut client := TestClient{
		server: server
		stream: stream
	}

	client.send<SumParams, RpcResult<int>>('sum', SumParams{ nums: [1,2,4] }) ?

	assert test_inter.methods_recv.len == 1
	assert test_inter.methods_recv[0] == 'sum'
	assert test_inter.messages.len == 1
	assert test_inter.messages[0] == 'test!'
}
