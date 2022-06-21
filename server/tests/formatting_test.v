import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp
import os
import json

fn test_formatting() ? {
	mut ls := server.new()
	ls.set_features(['v_diagnostics'], false)?

	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'formatting'
		client: new_test_client(ls)
	}
	mut writer := t.client.server.writer()
	test_files := t.initialize()?
	for file in test_files {
		exp_file_path := file.file_path.replace('.vv', '.out')
		content_lines := file.contents.split_into_lines()
		// open document
		doc_id := t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}
		errors := t.count_errors(file)
		if file.file_path.ends_with('error.vv') {
			// TODO: revisit this later
			// assert errors.len > 0
			t.ok(file)
			continue
		} else {
			assert errors == 0
		}
		mut exp_content := os.read_file(exp_file_path) or { '' }
		$if windows {
			exp_content = exp_content.replace('\n', '\r\n')
		}

		// initiate formatting request
		if actual := ls.formatting(lsp.DocumentFormattingParams{
			text_document: doc_id
		}, mut writer)
		{
			// compare content
			assert json.encode(actual) == json.encode([
				lsp.TextEdit{
					range: lsp.Range{
						start: lsp.Position{
							line: 0
							character: 0
						}
						end: lsp.Position{
							line: content_lines.len - 1
							character: content_lines.last().len
						}
					}
					new_text: exp_content
				},
			])
		} else {
			if file.file_path.ends_with('empty.vv') {
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
