import server
import server.testing
import lsp
import json

fn test_wrong_first_request() {
	mut io := &testing.Testio{}
	mut ls := server.new(io)
	payload := io.request('shutdown')
	ls.dispatch(payload)
	assert ls.status() == .off
	err_code, err_msg := io.response_error() or {
		assert false
		return
	}
	assert err_code == -32002
	assert err_msg == 'Server not yet initialized.'
}

fn test_initialize_with_capabilities() {
	mut io, mut ls := init_tests()
	assert ls.status() == .initialized
	assert io.result() == json.encode(lsp.InitializeResult{
		capabilities: ls.capabilities()
	})
}

fn test_initialized() {
	mut io, mut ls := init_tests()
	payload := io.request('initialized')
	ls.dispatch(payload)
	assert ls.status() == .initialized
}

// fn test_shutdown() {
// 	payload := '{"jsonrpc":"2.0","method":"shutdown","params":{}}'
// 	mut ls := init_tests()
// 	ls.dispatch(payload)
// 	status := ls.status()
// 	assert status == .shutdown
// }
fn test_set_features() {
	mut io := &testing.Testio{}
	mut ls := server.new(io)
	assert ls.features() == server.default_features_list
	ls.set_features(['formatting'], false) or {
		assert false
		return
	}
	assert ls.features() == [
		.diagnostics,
		.document_symbol,
		.workspace_symbol,
		.signature_help,
		.completion,
		.hover,
		.folding_range,
		.definition,
		.implementation,
	]
	ls.set_features(['formatting'], true) or {
		assert false
		return
	}
	assert ls.features() == [
		.diagnostics,
		.document_symbol,
		.workspace_symbol,
		.signature_help,
		.completion,
		.hover,
		.folding_range,
		.definition,
		.implementation,
		.formatting,
	]
	ls.set_features(['logging'], true) or {
		assert err.msg == 'feature "logging" not found'
		return
	}
}

fn init_tests() (&testing.Testio, server.Vls) {
	mut io := &testing.Testio{}
	mut ls := server.new(io)
	payload := io.request('initialize')
	ls.dispatch(payload)
	return io, ls
}
