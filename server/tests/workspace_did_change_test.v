import server
import jsonrpc.server_test_utils { new_test_client }
import test_utils
import lsp
import os

fn test_workspace_did_change() ? {
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'workspace_did_change'
		client: new_test_client(server.new())
	}

	// TODO: add a mock filesystem
	test_files := t.initialize() ?
	for file in test_files {
		// open document
		t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}
	}

	method_name := 'workspace/didChangeWatchedFiles'
	assert t.is_ok()

	// delete
	t.client.notify(method_name, lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(test_files.get(1)?.file_path)
				typ: .deleted
			},
		]
	}) ?

	// rename
	t.client.notify(method_name, lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(test_files.get(2)?.file_path)
				typ: .deleted
			},
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(os.join_path(os.dir(test_files.get(2)?.file_path), 'renamed.vv'))
				typ: .created
			},
		]
	}) ?

	// on save
	t.client.notify(method_name, lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(test_files.get(0)?.file_path)
				typ: .changed
			},
		]
	}) ?
}
