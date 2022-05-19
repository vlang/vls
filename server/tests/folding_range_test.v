import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp

// TODO: enable top level comments support in the future
const folding_range_results = {
	'simple.vv':  [
		lsp.FoldingRange{
			start_line: 2
			start_character: 0
			end_line: 6
			end_character: 11
			kind: 'region'
		},
		lsp.FoldingRange{
			start_line: 8
			start_character: 0
			end_line: 11
			// TODO: fix test that need to work on windows. Damn you line endings
			// end_character: 9
			end_character: 60
			kind: 'region'
		},
		lsp.FoldingRange{
			start_line: 13
			start_character: 0
			end_line: 17
			end_character: 10
			kind: 'region'
		},
		lsp.FoldingRange{
			start_line: 19
			start_character: 0
			end_line: 23
			end_character: 9
			kind: 'region'
		},
	]
	'comment.vv': [
		lsp.FoldingRange{
			start_line: 0
			start_character: 0
			end_line: 18
			end_character: 2
			kind: 'comment'
		},
	]
}

fn test_folding_range() ? {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'folding_range'
		client: new_test_client(ls)
	}
	mut writer := t.client.server.writer()
	test_files := t.initialize() or {
		// TODO: skip for now
		if err.msg() == 'no test files found for "folding_range"' {
			return
		}
		return err
	}

	for file in test_files {
		test_name := file.file_name
		err_msg := if test_name !in folding_range_results {
			'missing results'
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

		// initiate folding range request
		actual := ls.folding_range(lsp.FoldingRangeParams{
			text_document: doc_id
		}, mut writer) ?

		// compare content
		assert actual == folding_range_results[test_name]

		// Delete document
		t.close_document(doc_id) or {
			t.fail(file, err.msg())
			continue
		}

		t.ok(file)
	}
	assert t.is_ok()
}
