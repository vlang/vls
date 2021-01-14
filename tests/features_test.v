import vls
import vls.testing
import json
import benchmark
import lsp
import os

const test_files_dir = os.join_path(os.dir(@FILE), 'features_test_files') 

fn get_input_filepaths(folder_name string) ?[]string {
	target_path := os.join_path(test_files_dir, folder_name)
	dir := os.ls(target_path) ?
	mut filtered := []string{}

	for path in dir {
		if !path.ends_with('.vv') {
			continue
		}
		filtered << os.join_path(target_path, path)
	}

	unsafe { dir.free() }
	return filtered
}

fn test_formatting() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('initialize'))

	mut bench := benchmark.new_benchmark()
	test_files := get_input_filepaths('formatting') or {
		assert false
		return
	}
	
	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		doc_uri := lsp.document_uri_from_path(test_file_path)
		exp_file_path := test_file_path.replace('.vv', '.out')
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			assert false
			continue
		}
		
		content_lines := content.split_into_lines()
		exp_content := os.read_file(exp_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $exp_file_path is missing'))
			assert false
			continue
		}

		// open document
		ls.dispatch(io.request_with_params('textDocument/didOpen', lsp.DidOpenTextDocumentParams{
			text_document: lsp.TextDocumentItem {
				uri: doc_uri
				language_id: 'v'
				version: 1
				text: content
			}
		}))

		// initiate formatting request
		ls.dispatch(io.request_with_params('textDocument/formatting', lsp.DocumentFormattingParams{
			text_document: lsp.TextDocumentIdentifier{
				uri: doc_uri
			}
		}))

		// compare content
		eprintln(bench.step_message('Testing $test_file_path'))
		assert io.result() == json.encode([lsp.TextEdit{
			range: lsp.Range{
				start: lsp.Position{
					line: 0
					character: 0
				}
				end: lsp.Position{
					line: content_lines.len
					character: content_lines.last().len - 1
				}
			}
			new_text: exp_content.replace("\\r\\n", "\\n")
		}])

		bench.ok()
		println(bench.step_message_ok(os.base(test_file_path)))

		// Delete document
		ls.dispatch(io.request_with_params('textDocument/didClose', lsp.DidCloseTextDocumentParams{
			text_document: lsp.TextDocumentIdentifier{
				uri: doc_uri
			}
		}))

		bench.step()
	}
	bench.stop()
}

// file_uris will be replaced inside the test case
// because the uri may be different in each platform
const doc_symbols_results = {
	'simple.vv': [
		lsp.SymbolInformation{
			name: 'Uri'
			kind: .type_parameter
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{2, 0}
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
					start: lsp.Position{9, 0}
					end: lsp.Position{13, 10}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'Person'
			kind: .struct_
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{15, 0}
					end: lsp.Position{17, 13}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'Person.say'
			kind: .method
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{19, 0}
					end: lsp.Position{21, 19}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'main'
			kind: .function
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{23, 0}
					end: lsp.Position{26, 9}
				}
			}
		}
	]
}

fn test_document_symbols() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('initialize'))

	mut bench := benchmark.new_benchmark()
	test_files := get_input_filepaths('document_symbols') or {
		assert false
		return
	}
	
	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		test_name := os.base(test_file_path)
		doc_uri := lsp.document_uri_from_path(test_file_path)
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			assert false
			continue
		}

		// open document
		ls.dispatch(io.request_with_params('textDocument/didOpen', lsp.DidOpenTextDocumentParams{
			text_document: lsp.TextDocumentItem {
				uri: doc_uri
				language_id: 'v'
				version: 1
				text: content
			}
		}))

		// initiate formatting request
		ls.dispatch(io.request_with_params('textDocument/documentSymbol', lsp.DocumentFormattingParams{
			text_document: lsp.TextDocumentIdentifier{
				uri: doc_uri
			}
		}))

		// compare content
		eprintln(bench.step_message('Testing $test_file_path'))
		result := doc_symbols_results[test_name].map(lsp.SymbolInformation{
			name: it.name
			kind: it.kind
			location: lsp.Location{
				uri: doc_uri
				range: it.location.range
			}
		})
		assert io.result() == json.encode(result)

		bench.ok()
		println(bench.step_message_ok(test_name))

		// Delete document
		ls.dispatch(io.request_with_params('textDocument/didClose', lsp.DidCloseTextDocumentParams{
			text_document: lsp.TextDocumentIdentifier{
				uri: doc_uri
			}
		}))

		bench.step()
	}
	bench.stop()
}

fn test_workspace_symbols() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('initialize'))

	files := get_input_filepaths('workspace_symbols') or {
		assert false
		return
	}

	workspace_symbols_result := [
		lsp.SymbolInformation{
			name: 'main'
			kind: .function
			location: lsp.Location{
				uri: lsp.document_uri_from_path(files[0])
				range: lsp.Range{
					start: lsp.Position{2, 0}
					end: lsp.Position{4, 9}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'Person'
			kind: .struct_
			location: lsp.Location{
				uri: lsp.document_uri_from_path(files[1])
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
				uri: lsp.document_uri_from_path(files[1])
				range: lsp.Range{
					start: lsp.Position{6, 0}
					end: lsp.Position{8, 21}
				}
			}
		}
	]

	for file_path in files {
		content := os.read_file(file_path) or {
			assert false
			continue
		}

		// open document
		ls.dispatch(io.request_with_params('textDocument/didOpen', lsp.DidOpenTextDocumentParams{
			text_document: lsp.TextDocumentItem {
				uri: lsp.document_uri_from_path(file_path)
				language_id: 'v'
				version: 1
				text: content
			}
		}))
	}

	ls.dispatch(io.request_with_params('workspace/symbol', lsp.WorkspaceSymbolParams{}))
	assert io.result() == json.encode(workspace_symbols_result)
}

// fn test_completion() {}