import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp
import os

const base_dir = os.join_path(os.dir(@FILE), 'test_files', 'diagnostics')

const diagnostics_results = {
	'simple.vv':          lsp.PublishDiagnosticsParams{
		uri: lsp.document_uri_from_path(os.join_path(base_dir, 'simple.vv'))
		diagnostics: [
			lsp.Diagnostic{
				message: 'unexpected eof, expecting `}`'
				severity: .error
				range: lsp.Range{
					start: lsp.Position{4, 10}
					end: lsp.Position{4, 10}
				}
			},
			lsp.Diagnostic{
				message: "module 'os' is imported but never used"
				severity: .warning
				range: lsp.Range{
					start: lsp.Position{2, 7}
					end: lsp.Position{2, 7}
				}
			},
		]
	}
	'error_highlight.vv': lsp.PublishDiagnosticsParams{
		uri: lsp.document_uri_from_path(os.join_path(base_dir, 'error_highlight.vv'))
		diagnostics: [
			lsp.Diagnostic{
				message: 'unexpected name `asfasf`'
				severity: .error
				range: lsp.Range{
					start: lsp.Position{1, 1}
					end: lsp.Position{1, 1}
				}
			},
		]
	}
}

fn test_diagnostics() ? {
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'diagnostics'
		client: new_test_client(server.new())
	}

	test_files := t.initialize()?
	for file in test_files {
		doc_id := t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}

		diagnostic_params := t.diagnostics()?
		if diagnostic_params.uri.path() != file.file_path {
			t.fail(file, 'no diagnostics found')
			continue
		}

		expected := diagnostics_results[file.file_name] or { lsp.PublishDiagnosticsParams{} }
		assert diagnostic_params == expected
	}
	assert t.is_ok()
}
