import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
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
				start: lsp.Position{2, 3}
				end: lsp.Position{2, 6}
			}
		}
	},
	lsp.SymbolInformation{
		name: 'main'
		kind: .function
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file1.vv'))
			range: lsp.Range{
				start: lsp.Position{6, 3}
				end: lsp.Position{6, 7}
			}
		}
	},
	lsp.SymbolInformation{
		name: 'Person'
		kind: .struct_
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file2.vv'))
			range: lsp.Range{
				start: lsp.Position{2, 7}
				end: lsp.Position{2, 13}
			}
		}
	},
	lsp.SymbolInformation{
		name: 'hello'
		kind: .function
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file2.vv'))
			range: lsp.Range{
				start: lsp.Position{6, 3}
				end: lsp.Position{6, 8}
			}
		}
	},
]

fn test_workspace_symbols() ? {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'workspace_symbols'
		client: new_test_client(ls)
	}
	mut writer := t.client.server.writer()
	test_files := t.initialize()?
	for file in test_files {
		// open document
		t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}
	}

	assert t.is_ok()
	symbols := ls.workspace_symbol(lsp.WorkspaceSymbolParams{}, mut writer)
	assert symbols == workspace_symbols_result
}
