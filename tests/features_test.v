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
		if !path.ends_with('_input.vv') {
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

	mut bmark := benchmark.new_benchmark()
	test_files := get_input_filepaths('formatting') or {
		assert false
		return
	}
	
	bmark.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		doc_uri := lsp.document_uri_from_path(test_file_path)
		exp_file_path := test_file_path.replace('_input.vv', '_expected.vv')
		content := os.read_file(test_file_path) or {
			bmark.fail()
			eprintln(bmark.step_message_fail('file $test_file_path is missing'))
			assert false
			continue
		}
		
		content_lines := content.split_into_lines()
		exp_content := os.read_file(exp_file_path) or {
			bmark.fail()
			eprintln(bmark.step_message_fail('file $exp_file_path is missing'))
			assert false
			continue
		}

		// open document
		open_doc_req := io.request_with_params('textDocument/didOpen', lsp.DidOpenTextDocumentParams{
			text_document: lsp.TextDocumentItem {
				uri: doc_uri
				language_id: 'v'
				version: 1
				text: content
			}
		})

		ls.dispatch(open_doc_req)

		// initiate formatting request
		formatting_req := io.request_with_params('textDocument/formatting', lsp.DocumentFormattingParams{
			text_document: lsp.TextDocumentIdentifier{
				uri: doc_uri
			}
		})

		ls.dispatch(formatting_req)

		// compare content
		eprintln(bmark.step_message('Testing $test_file_path'))
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

		bmark.ok()
		println(bmark.step_message_ok(os.base(test_file_path)))

		// Delete document
		delete_doc_params := io.request_with_params('textDocument/didClose', lsp.DidCloseTextDocumentParams{
			text_document: lsp.TextDocumentIdentifier{
				uri: doc_uri
			}
		})
		ls.dispatch(delete_doc_params)

		bmark.step()
	}
	bmark.stop()
}

// fn test_completion() {}
// fn test_workspace_symbols() {}
// fn test_document_symbols() {}