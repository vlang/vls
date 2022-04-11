import server
import test_utils
import json
import lsp
import os

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

fn test_document_symbols() {
	mut io := &test_utils.Testio{
		test_files_dir: test_utils.get_test_files_path(@FILE)
	}
	mut ls := server.new(io)
	ls.dispatch(io.request('initialize'))
	test_files := io.load_test_file_paths('document_symbols') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg()))
		assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		test_name := os.base(test_file_path)
		content := os.read_file(test_file_path) or {
			io.bench.fail()
			eprintln(io.bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		// open document
		req, doc_id := io.open_document(test_file_path, content)
		ls.dispatch(req)
		// initiate formatting request
		ls.dispatch(io.request_with_params('textDocument/documentSymbol', lsp.DocumentFormattingParams{
			text_document: doc_id
		}))
		// compare content
		println(io.bench.step_message('Testing $test_file_path'))
		result := doc_symbols_result[test_name].map(lsp.SymbolInformation{
			name: it.name
			kind: it.kind
			location: lsp.Location{
				uri: doc_id.uri
				range: it.location.range
			}
		})
		assert io.result() == json.encode(result)
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
		// Delete document
		ls.dispatch(io.close_document(doc_id))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
