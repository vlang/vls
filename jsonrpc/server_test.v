import jsonrpc
import jsonrpc.server_test_utils { TestClient, TestStream }

struct TestHandler {}

struct SumParams {
mut:
	nums []int
}

fn (mut h TestHandler) handle_jsonrpc(req &jsonrpc.Request, mut wr jsonrpc.ResponseWriter) ? {
	match req.method {
		'sum' {
			params := req.decode_params<SumParams>()?

			mut res := 0
			for n in params.nums {
				res += n
			}

			wr.write(RpcResult<int>{ result: res })
		}
		'hello' {
			wr.write(RpcResult<string>{'Hello world!'})
		}
		'trigger' {
			wr.server.dispatch_event('record', 'dispatched!')?
			wr.write(RpcResult<string>{'triggered'})
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

	sum_result := client.send<SumParams, RpcResult<int>>('sum', SumParams{ nums: [1, 2, 4] })?
	assert sum_result.result == 7

	hello_result := client.send<string, RpcResult<string>>('hello', '')?
	assert hello_result.result == 'Hello world!'

	client.send<string, RpcResult<int>>('multiply', 'test') or {
		assert err.msg() == 'Method not found.'
	}
}

struct TestInterceptor {
mut:
	methods_recv []string
	messages     []string
}

fn (mut t TestInterceptor) on_event(name string, data jsonrpc.InterceptorData) ? {
	if name == 'record' && data is string {
		t.messages << data
	}
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

	client.send<SumParams, RpcResult<int>>('sum', SumParams{ nums: [1, 2, 4] })?
	assert test_inter.methods_recv.len == 1
	assert test_inter.methods_recv[0] == 'sum'
	assert test_inter.messages.len == 1

	client.send<string, RpcResult<string>>('trigger', '')?
	assert test_inter.methods_recv.len == 2
	assert test_inter.methods_recv[1] == 'trigger'
	assert test_inter.messages.len == 3
	assert test_inter.messages[1] == 'dispatched!'
}
