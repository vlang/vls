import server
import test_utils
import json
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

fn test_implementation() {
	mut io := test_utils.Testio{
		test_files_dir: test_utils.get_test_files_path(@FILE)
	}
	mut ls := server.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(base_dir)
	}))
	test_files := io.load_test_file_paths('implementation') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg()))
		assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in implementation_results
			&& test_name !in implementation_should_return_null {
			'missing results for $test_name'
		} else if test_name !in implementation_inputs {
			'missing input data for $test_name'
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
		// initiate hover request
		ls.dispatch(io.request_with_params('textDocument/implementation', lsp.TextDocumentPositionParams{
			text_document: doc_id
			position: implementation_inputs[test_name]
		}))
		// compare content
		println(io.bench.step_message('Testing $test_file_path'))
		result := io.result()
		if test_name in implementation_should_return_null {
			assert result == 'null'
		} else {
			assert result == json.encode(implementation_results[test_name])
		}
		// Delete document
		ls.dispatch(io.close_document(doc_id))
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
