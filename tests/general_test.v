import vls
import vls.testing
import lsp

fn test_wrong_first_request() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	payload := io.request('shutdown')
	ls.dispatch(payload)
	assert ls.status() == .off
	io.assert_error(-32002, 'Server not yet initialized.')
}

fn test_initialize_with_capabilities() {
	mut io, mut ls := init()
	assert ls.status() == .initialized
	io.assert_response(lsp.InitializeResult{
		capabilities: ls.capabilities()
	})
}

fn test_initialized() {
	mut io, mut ls := init()
	payload := io.request('initialized')
	ls.dispatch(payload)
	assert ls.status() == .initialized
}

// fn test_shutdown() {
// 	payload := '{"jsonrpc":"2.0","method":"shutdown","params":{}}'
// 	mut ls := init()
// 	ls.dispatch(payload)
// 	status := ls.status()
// 	assert status == .shutdown
// }
fn init() (testing.Testio, vls.Vls) {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	payload := io.request('initialize')
	ls.dispatch(payload)
	return io, ls
}
