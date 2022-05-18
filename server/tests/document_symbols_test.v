import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp

// file_uris will be replaced inside the test case
// because the uri may be different in each platform
const doc_symbols_result = {
	'simple.vv': [
		lsp.SymbolInformation{
			name: 'Uri'
			kind: .type_parameter
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{2, 5}
					end: lsp.Position{2, 8}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'text'
			kind: .constant
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{5, 2}
					end: lsp.Position{5, 6}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'two'
			kind: .constant
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{6, 2}
					end: lsp.Position{6, 5}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'Color'
			kind: .enum_
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{9, 5}
					end: lsp.Position{9, 10}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'Person'
			kind: .struct_
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{15, 7}
					end: lsp.Position{15, 13}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'p.say'
			kind: .method
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{19, 14}
					end: lsp.Position{19, 17}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'main'
			kind: .function
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{23, 3}
					end: lsp.Position{23, 7}
				}
			}
		},
	]
}

fn test_document_symbols() ? {
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'document_symbols'
		client: new_test_client(server.new())
	}

	test_files := t.initialize() ?
	for file in test_files {
		// open document
		doc_id := t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}

		// initiate formatting request
		actual := t.client.send<lsp.DocumentSymbolParams, []lsp.SymbolInformation>('textDocument/documentSymbol', lsp.DocumentSymbolParams{
			text_document: doc_id
		}) ?

		// compare content
		expected := doc_symbols_result[file.file_name].map(lsp.SymbolInformation{
			name: it.name
			kind: it.kind
			location: lsp.Location{
				uri: doc_id.uri
				range: it.location.range
			}
		})

		assert actual == expected

		// Delete document
		t.close_document(doc_id) or {
			t.fail(file, err.msg())
			continue
		}

		t.ok(file)
	}
	assert t.is_ok()
}
