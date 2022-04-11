import server
import test_utils
import json
import lsp
import os

fn test_formatting() {
	mut io := &test_utils.Testio{
		test_files_dir: test_utils.get_test_files_path(@FILE)
	}
	mut ls := server.new(io)
	ls.dispatch(io.request('initialize'))
	test_files := io.load_test_file_paths('formatting') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg()))
		assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		exp_file_path := test_file_path.replace('.vv', '.out')
		content := os.read_file(test_file_path) or {
			io.bench.fail()
			eprintln(io.bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		content_lines := content.split_into_lines()
		// open document
		req, doc_id := io.open_document(test_file_path, content)
		ls.dispatch(req)
		errors := io.file_errors() or {
			io.bench.fail()
			eprintln(io.bench.step_message_fail('file $test_file_path has errors'))
			continue
		}
		if test_file_path.ends_with('error.vv') {
			// TODO: revisit this later
			// assert errors.len > 0
			io.bench.ok()
			continue
		} else {
			assert errors.len == 0
		}
		exp_content := os.read_file(exp_file_path) or { '' }
		// initiate formatting request
		ls.dispatch(io.request_with_params('textDocument/formatting', lsp.DocumentFormattingParams{
			text_document: doc_id
		}))
		// compare content
		println(io.bench.step_message('Testing $test_file_path'))
		if test_file_path.ends_with('empty.vv') {
			assert io.result() == 'null'
		} else {
			assert io.result() == json.encode([
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
		}
		io.bench.ok()
		println(io.bench.step_message_ok(os.base(test_file_path)))
		// Delete document
		ls.dispatch(io.close_document(doc_id))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
