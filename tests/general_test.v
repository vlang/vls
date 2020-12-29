import vls
import vls.testing

fn test_wrong_first_request() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('shutdown'))
	status := ls.status()
	assert status == .off
	io.assert_error(-32002, "Server not yet initialized.")
}

fn test_initialize_with_capabilities() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('initialize'))
	status := ls.status()
	assert status == .initialized
	testing.assert_response(io, ls.capabilities())
}

fn test_initialized() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialized","params":{}}'
	mut ls := init()
	ls.dispatch(payload)
	status := ls.status()
	assert status == .initialized
}

// fn test_shutdown() {
// 	payload := '{"jsonrpc":"2.0","method":"shutdown","params":{}}'
// 	mut ls := init()
// 	ls.dispatch(payload)
// 	status := ls.status()
// 	assert status == .shutdown
// }

fn init() vls.Vls {
	mut io := testing.Testio{}
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	mut ls := vls.new(io)
	ls.dispatch(payload)
	return ls
}
