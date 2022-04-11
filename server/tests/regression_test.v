import server
import test_utils
import lsp
import os

// REGRESSION TEST
// NB: This is a simple implementation for now. What this test does is
// to open a file from a test folder and close if no panic or any related
// "stop-the-process" errors occur.
//
// Files are taken from the existing issues. If there is an issue related
// to checker / parser that only crashes within VLS, please tag the issue
// `needs-regression-test` and add the offending code here.
//
// This is just an extension of the existing V test suite. If the code also
// applies to the V compiler, it is better to add it there instead.

fn test_regression() {
	mut io := &test_utils.Testio{
		test_files_dir: test_utils.get_test_files_path(@FILE)
	}
	mut ls := server.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path(os.dir(@FILE), 'test_files',
			'regressions'))
	}))
	test_files := io.load_test_file_paths('regressions') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg()))
		assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		content := os.read_file(test_file_path) or {
			io.bench.fail()
			eprintln(io.bench.step_message_fail('file $test_file_path is missing'))
			continue
		}

		println(io.bench.step_message('Testing $test_file_path'))
		req, doc_id := io.open_document(test_file_path, content)
		ls.dispatch(req)

		io.bench.ok()
		ls.dispatch(io.close_document(doc_id))
	}

	io.bench.stop()
}
