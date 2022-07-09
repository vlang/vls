import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp

fn test_code_lens() ? {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'document_link'
		client: new_test_client(ls)
	}

	mut writer := t.client.server.writer()
	test_files := t.initialize() ?
	for file in test_files {
		// open document
		doc_id := t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}

		if _ := ls.document_link(lsp.DocumentLinkParams{
			text_document: doc_id
		}, mut writer) {
			assert false
		} else {
			assert err is none

			// Delete document
			t.close_document(doc_id) or {
				t.fail(file, err.msg())
				continue
			}

			t.ok(file)
		}
	}

	assert t.is_ok()
}
