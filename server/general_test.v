import jsonrpc.server_test_utils { new_test_client, RpcResult, TestClient }
import jsonrpc
import server
import lsp
import lsp.log { LogRecorder }
import os

fn test_wrong_first_request() ? {
	mut ls := server.new()
	mut io := new_test_client(ls)

	assert ls.status() == .off
	io.send<lsp.CodeLensParams, jsonrpc.Null>('textDocument/codeLens', lsp.CodeLensParams{}) or {
		assert err.code() == jsonrpc.server_not_initialized.code()
		assert err.msg() == jsonrpc.server_not_initialized.msg()
		return
	}
	assert false
}

fn test_initialize_with_capabilities() ? {
	mut ls := server.new()
	mut io := new_test_client(ls)
	result := io.send<map[string]string, lsp.InitializeResult>('initialize', map[string]string{}) ?

	assert ls.status() == .initialized
	assert result == lsp.InitializeResult{
		capabilities: ls.capabilities()
	}
}

fn test_initialized() ? {
	mut io, mut ls := init_tests() ?
	io.notify('initialized', map[string]string{}) ?
	assert ls.status() == .initialized
}

fn test_set_features() {
	mut ls := server.new()
	mut io := new_test_client(ls)
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
		.code_lens,
		.document_link
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
		.code_lens,
		.document_link,
		.formatting,
	]
	ls.set_features(['logging'], true) or {
		assert err.msg() == 'feature "logging" not found'
		return
	}
}

fn test_setup_logger() ? {
	println('test_setup_logger')
	mut io := new_test_client(server.new(), &LogRecorder{})
	io.send<lsp.InitializeParams, lsp.InitializeResult>('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path('non_existent', 'path'))
	}) ?

	notif := io.stream.notification_at<lsp.ShowMessageParams>(0) ?
	assert notif.method == 'window/showMessage'

	expected_err_path := os.join_path('non_existent', 'path', 'vls.log')
	expected_alt_log_path := os.join_path(server.get_folder_path(), 'logs', 'vls__non_existent_path.log')
	assert notif.params == lsp.ShowMessageParams{
		@type: .error
		message: 'Cannot save log to ${expected_err_path}. Saving log to $expected_alt_log_path'
	}
}

fn init_tests() ?(&TestClient, &server.Vls) {
	mut ls := server.new()
	mut io := new_test_client(ls)
	io.send<map[string]string, lsp.InitializeResult>('initialize', map[string]string{}) ?
	return io, ls
}
