import server
import jsonrpc.server_test_utils { new_test_client }
import test_utils
import lsp
import os

fn test_workspace_did_change() ? {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'workspace_did_change'
		client: new_test_client(ls)
	}

	// TODO: add a mock filesystem
	mut writer := t.client.server.writer()
	test_files := t.initialize() ?
	for file in test_files {
		// open document
		t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}
	}

	// delete
	first_file_uri := lsp.document_uri_from_path(test_files.get(1)?.file_path)
	ls.did_change_watched_files(lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: first_file_uri
				typ: .deleted
			},
		]
	}, mut writer)
	assert ls.files.keys().index(first_file_uri) == -1
	t.ok(test_files.get(1) ?)

	// rename
	second_file_uri_old := lsp.document_uri_from_path(test_files.get(2)?.file_path)
	second_file_uri_new := lsp.document_uri_from_path(os.join_path(os.dir(test_files.get(2)?.file_path), 'renamed.vv'))
	ls.did_change_watched_files(lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: second_file_uri_old
				typ: .deleted
			},
			lsp.FileEvent{
				uri: second_file_uri_new
				typ: .created
			},
		]
	}, mut writer)
	assert ls.files.keys().index(second_file_uri_old) == -1
	assert ls.files.keys().index(second_file_uri_new) != -1
	t.ok(test_files.get(2) ?)

	// on save
	ls.did_change_watched_files(lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(test_files.get(0)?.file_path)
				typ: .changed
			},
		]
	}, mut writer)
	t.ok(test_files.get(2) ?)

	assert t.is_ok()
}
