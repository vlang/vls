import jsonrpc
import jsonrpc.server_test_utils { new_test_client }
import server
import test_utils

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

fn test_regression() ? {
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'regressions'
		client: new_test_client(server.new())
	}

	test_files := t.initialize()?
	for file in test_files {
		doc_id := t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}

		t.close_document(doc_id) or {
			t.fail(file, err.msg())
			continue
		}

		t.ok(file)
	}

	assert t.is_ok()
}
