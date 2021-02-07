import vls
import vls.testing
import json
import lsp
import os

const base_dir = os.join_path(os.dir(@FILE), 'test_files', 'workspace_symbols')

const workspace_symbols_result = [
	lsp.SymbolInformation{
		name: 'foo'
		kind: .function
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file1.vv'))
			range: lsp.Range{
				start: lsp.Position{2, 0}
				end: lsp.Position{4, 15}
			}
		}
	},
	lsp.SymbolInformation{
		name: 'main'
		kind: .function
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file1.vv'))
			range: lsp.Range{
				start: lsp.Position{6, 0}
				end: lsp.Position{8, 9}
			}
		}
	},
	lsp.SymbolInformation{
		name: 'Person'
		kind: .struct_
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file2.vv'))
			range: lsp.Range{
				start: lsp.Position{2, 0}
				end: lsp.Position{4, 13}
			}
		}
	},
	lsp.SymbolInformation{
		name: 'hello'
		kind: .function
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file2.vv'))
			range: lsp.Range{
				start: lsp.Position{6, 0}
				end: lsp.Position{8, 21}
			}
		}
	},
]

fn test_workspace_symbols() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('initialize'))
	files := testing.load_test_file_paths('workspace_symbols') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err))
		assert false
		return
	}
	for file_path in files {
		content := os.read_file(file_path) or {
			io.bench.fail()
			continue
		}
		// open document
		req, _ := io.open_document(file_path, content)
		ls.dispatch(req)
	}
	assert io.bench.nfail == 0
	ls.dispatch(io.request_with_params('workspace/symbol', lsp.WorkspaceSymbolParams{}))
	assert io.result() == json.encode(workspace_symbols_result)
	io.bench.stop()
}
