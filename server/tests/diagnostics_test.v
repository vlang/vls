import server
import test_utils
import json
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

fn test_diagnostics() {
	mut io := &test_utils.Testio{
		test_files_dir: test_utils.get_test_files_path(@FILE)
	}
	mut ls := server.new(io)
	ls.dispatch(io.request('initialize'))
	files := io.load_test_file_paths('diagnostics') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg()))
		assert false
		return
	}
	for file_path in files {
		test_name := os.base(file_path)
		content := os.read_file(file_path) or {
			io.bench.fail()
			eprintln(io.bench.step_message_fail('file $file_path is missing'))
			continue
		}
		// open document
		req, _ := io.open_document(file_path, content)
		ls.dispatch(req)

		method, params := io.notification() or { '', '{}' }
		diagnostic_params := json.decode(lsp.PublishDiagnosticsParams, params) or {
			lsp.PublishDiagnosticsParams{}
		}
		assert method == 'textDocument/publishDiagnostics'
		result := diagnostics_results[test_name] or { lsp.PublishDiagnosticsParams{} }
		assert diagnostic_params == result
	}
}
