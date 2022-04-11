import server
import test_utils
import lsp
import json
import os

fn test_wrong_first_request() ? {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	payload := io.request('shutdown')
	ls.dispatch(payload)
	assert ls.status() == .off
	err_code, err_msg := io.response_error() ?
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
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	assert ls.features() == server.default_features_list
	ls.set_features(['formatting'], false) or {
		assert false
		return
	}
	assert ls.features() == [
		.diagnostics,
		.v_diagnostics,
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
		.v_diagnostics,
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
		assert err.msg() == 'feature "logging" not found'
		return
	}
}

fn test_setup_logger() ? {
	println('test_setup_logger')
	mut io := &test_utils.Testio{
		debug: true
		max_nr_responses: 10
	}
	mut ls := server.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path('non_existent', 'path'))
	}))

	method, params := io.notification_at_index(0) ?
	assert method == 'window/showMessage'

	expected_err_path := os.join_path('non_existent', 'path', 'vls.log').replace(r'\',
		r'\\')
	alt_log_filename := 'vls__non_existent_path.log'
	expected_alt_log_path := os.join_path(os.home_dir(), alt_log_filename).replace(r'\',
		r'\\')
	assert params == '{"type":1,"message":"Cannot save log to ${expected_err_path}. Saving log to $expected_alt_log_path"}'
}

fn init_tests() (&test_utils.Testio, server.Vls) {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	payload := io.request('initialize')
	ls.dispatch(payload)
	return io, ls
}
