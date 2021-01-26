import vls
import vls.testing
import json
import lsp
import os

const base_dir = os.join_path(os.dir(@FILE), 'test_files', 'diagnostics')

const diagnostics_result = lsp.PublishDiagnosticsParams{
	uri: lsp.document_uri_from_path(os.join_path(base_dir, 'simple.vv'))
	diagnostics: [
		lsp.Diagnostic{
			message: 'unexpected `eof`, expecting `}`'
			severity: .error
			range: lsp.Range{
				start: lsp.Position{4, 10}
				end: lsp.Position{4, 11}
			}
		},
		lsp.Diagnostic{
			message: "module 'os' is imported but never used"
			severity: .warning
			range: lsp.Range{
				start: lsp.Position{2, 7}
				end: lsp.Position{2, 9}
			}
		},
	]
}

fn test_diagnostics() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('initialize'))
	files := testing.load_test_file_paths('diagnostics') or {
		assert false
		return
	}
	for file_path in files {
		content := os.read_file(file_path) or {
			assert false
			continue
		}
		// open document
		req, _ := io.open_document(file_path, content)
		ls.dispatch(req)
	}
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == 'textDocument/publishDiagnostics'
	assert params == json.encode(diagnostics_result)
}
