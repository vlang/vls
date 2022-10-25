import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp

fn test_code_lens() {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'code_lens'
		client: new_test_client(ls)
	}

	mut writer := t.client.server.writer()
	test_files := t.initialize()?
	for file in test_files {
		// open document
		doc_id := t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}

		if _ := ls.code_lens(lsp.CodeLensParams{
			text_document: doc_id
		}, mut writer)
		{
			t.fail(file, 'should not return a result')
		} else {
			t.is_null(file, true, err)
		}

		// Delete document
		t.close_document(doc_id) or {
			t.fail(file, err.msg())
			continue
		}
	}

	assert t.is_ok()
}
