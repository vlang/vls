import server
import test_utils
import json
import lsp
import os

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

fn test_folding_range() {
	mut io := test_utils.Testio{
		test_files_dir: test_utils.get_test_files_path(@FILE)
	}
	mut ls := server.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path(os.dir(@FILE), 'test_files',
			'folding_range'))
	}))
	test_files := io.load_test_file_paths('folding_range') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg()))
		// assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in folding_range_results {
			'missing results for $test_name'
		} else {
			''
		}
		if err_msg.len != 0 {
			io.bench.fail()
			eprintln(io.bench.step_message_fail(err_msg))
			continue
		}
		content := os.read_file(test_file_path) or {
			io.bench.fail()
			eprintln(io.bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		// open document
		req, doc_id := io.open_document(test_file_path, content)
		ls.dispatch(req)
		// initiate folding range request
		ls.dispatch(io.request_with_params('textDocument/foldingRange', lsp.FoldingRangeParams{
			text_document: doc_id
		}))
		// compare content
		println(io.bench.step_message('Testing $test_file_path'))
		assert io.result() == json.encode(folding_range_results[test_name])
		// Delete document
		ls.dispatch(io.close_document(doc_id))
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
