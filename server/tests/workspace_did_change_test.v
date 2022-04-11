import server
import test_utils
import lsp
import os

fn test_workspace_did_change() ? {
	mut io := &test_utils.Testio{
		test_files_dir: test_utils.get_test_files_path(@FILE)
	}
	mut ls := server.new(io)

	// TODO: add a mock filesystem
	files := io.load_test_file_paths('workspace_did_change') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg()))
		return err
	}

	for file_path in files {
		content := os.read_file(file_path) or {
			io.bench.fail()
			continue
		}
		// open document
		req, _ := io.open_document(file_path, content)
		ls.dispatch(req)
	}

	method_name := 'workspace/didChangeWatchedFiles'
	assert io.bench.nfail == 0

	// delete
	delete_ev := io.request_with_params(method_name, lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(files[1])
				typ: .deleted
			},
		]
	})

	ls.dispatch(delete_ev)

	// rename
	rename_ev := io.request_with_params(method_name, lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(files[2])
				typ: .deleted
			},
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(os.join_path(os.dir(files[2]), 'renamed.vv'))
				typ: .created
			},
		]
	})

	ls.dispatch(rename_ev)

	// on save
	changed_ev := io.request_with_params(method_name, lsp.DidChangeWatchedFilesParams{
		changes: [
			lsp.FileEvent{
				uri: lsp.document_uri_from_path(files[0])
				typ: .changed
			},
		]
	})

	ls.dispatch(changed_ev)
}
