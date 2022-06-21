import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp
import os

const base_dir = os.join_path(os.dir(@FILE), 'test_files', 'implementation')

const implementation_inputs = {
	'simple.vv': lsp.Position{9, 8}
}

const implementation_results = {
	'simple.vv': [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'simple.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{9, 7}
				end: lsp.Position{9, 10}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 10}
				end: lsp.Position{0, 17}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 10}
				end: lsp.Position{0, 17}
			}
		},
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'simple.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{9, 7}
				end: lsp.Position{9, 10}
			}
			target_range: lsp.Range{
				start: lsp.Position{4, 10}
				end: lsp.Position{4, 16}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{4, 10}
				end: lsp.Position{4, 16}
			}
		},
	]
}

const implementation_should_return_null = []string{}

fn test_implementation() ? {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'implementation'
		client: new_test_client(ls)
	}
	mut writer := t.client.server.writer()
	test_files := t.initialize() ?
	for file in test_files {
		test_name := file.file_name
		err_msg := if test_name !in implementation_results {
			'missing results'
		} else if test_name !in implementation_inputs {
			'missing input data'
		} else {
			''
		}
		if err_msg.len != 0 {
			t.fail(file, err_msg)
			continue
		}
		// open document
		doc_id := t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}
		// initiate implementation request
		if actual := ls.implementation(lsp.TextDocumentPositionParams{
			text_document: doc_id
			position: implementation_inputs[test_name]
		}, mut writer) {
			// compare content
			assert actual == implementation_results[test_name]
		} else {
			if test_name in implementation_should_return_null {
				assert err is none
			}
		}
		// Delete document
		t.close_document(doc_id) or {
			t.fail(file, err.msg())
			continue
		}

		t.ok(file)
	}

	assert t.is_ok()
}
