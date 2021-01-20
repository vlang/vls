import vls
import vls.testing
import json
import benchmark
import lsp
import os

// results
import test_files.document_symbols { doc_symbols_result }
import test_files.workspace_symbols { workspace_symbols_result }
import test_files.diagnostics { diagnostics_result }
import test_files.completion { completion_contexts, completion_positions, completion_results }

const test_files_dir = os.join_path(os.dir(@FILE), 'test_files') 

fn open_document(mut io testing.Testio, file_path string, contents string) (string, lsp.TextDocumentIdentifier) {
	doc_uri := lsp.document_uri_from_path(file_path)
	req := io.request_with_params('textDocument/didOpen', lsp.DidOpenTextDocumentParams{
		text_document: lsp.TextDocumentItem {
			uri: doc_uri
			language_id: 'v'
			version: 1
			text: contents
		}
	})
	docid := lsp.TextDocumentIdentifier{ uri: doc_uri }
	return req, docid
}

fn file_errors(mut io testing.Testio) ?[]lsp.Diagnostic {
	mut errors := []lsp.Diagnostic{}
	_, diag_params := io.notification() ?
	diag_info := json.decode(lsp.PublishDiagnosticsParams, diag_params) ?
	for diag in diag_info.diagnostics {
		if diag.severity != .error {
			continue
		}
		errors << diag		
	}
	return errors
}

fn get_input_filepaths(folder_name string) ?[]string {
	target_path := os.join_path(test_files_dir, folder_name)
	dir := os.ls(target_path) ?
	mut filtered := []string{}
	for path in dir {
		if !path.ends_with('.vv') || path.ends_with('_skip.vv') {
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
		req, doc_id := open_document(mut io, test_file_path, content)
		ls.dispatch(req)
		errors := file_errors(mut io) or {
			assert false
			return
		}
		if test_file_path.ends_with('error.vv') {
			assert errors.len > 0
			continue
		} else {
			assert errors.len == 0
		}
		// initiate formatting request
		ls.dispatch(io.request_with_params('textDocument/formatting', lsp.DocumentFormattingParams{
			text_document: doc_id
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
			new_text: exp_content.replace("\r\n", "\n")
		}])
		bench.ok()
		println(bench.step_message_ok(os.base(test_file_path)))
		// Delete document
		ls.dispatch(io.request_with_params('textDocument/didClose', lsp.DidCloseTextDocumentParams{
			text_document: doc_id
		}))
		bench.step()
	}
	bench.stop()
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
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			assert false
			continue
		}
		// open document
		req, doc_id := open_document(mut io, test_file_path, content)
		ls.dispatch(req)
		// initiate formatting request
		ls.dispatch(io.request_with_params('textDocument/documentSymbol', lsp.DocumentFormattingParams{
			text_document: doc_id
		}))
		// compare content
		eprintln(bench.step_message('Testing $test_file_path'))
		result := doc_symbols_result[test_name].map(lsp.SymbolInformation{
			name: it.name
			kind: it.kind
			location: lsp.Location{
				uri: doc_id.uri
				range: it.location.range
			}
		})
		assert io.result() == json.encode(result)
		bench.ok()
		println(bench.step_message_ok(test_name))
		// Delete document
		ls.dispatch(io.request_with_params('textDocument/didClose', lsp.DidCloseTextDocumentParams{
			text_document: doc_id
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
	for file_path in files {
		content := os.read_file(file_path) or {
			assert false
			continue
		}
		// open document
		req, _ := open_document(mut io, file_path, content)
		ls.dispatch(req)
	}
	ls.dispatch(io.request_with_params('workspace/symbol', lsp.WorkspaceSymbolParams{}))
	assert io.result() == json.encode(workspace_symbols_result)
}

fn test_diagnostics() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('initialize'))
	files := get_input_filepaths('diagnostics') or {
		assert false
		return
	}
	for file_path in files {
		content := os.read_file(file_path) or {
			assert false
			continue
		}
		// open document
		req, _ := open_document(mut io, file_path, content)
		ls.dispatch(req)
	}
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == 'textDocument/publishDiagnostics'
	assert params == json.encode(diagnostics_result)
}

fn test_completion() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request('initialize'))

	mut bench := benchmark.new_benchmark()
	test_files := get_input_filepaths('completion') or {
		assert false
		return
	}
	
	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		test_name := os.base(test_file_path)
		mut has_err := false
		if test_name !in completion_results {
			bench.fail()
			eprintln(bench.step_message_fail('missing results for $test_name'))
			has_err = true
		} else if test_name !in completion_contexts{
			bench.fail()
			eprintln(bench.step_message_fail('missing context data for $test_name'))
			has_err = true
		} else if test_name !in completion_positions {
			bench.fail()
			eprintln(bench.step_message_fail('missing position data for $test_name'))
			has_err = true
		}
		if has_err {
			assert false
		}
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			assert false
			return
		}
		// open document
		req, doc_id := open_document(mut io, test_file_path, content)
		ls.dispatch(req)
		// initiate completion request
		ls.dispatch(io.request_with_params('textDocument/completion', lsp.CompletionParams{
			text_document: doc_id
			position: completion_positions[test_name]
			context: completion_contexts[test_name]
		}))
		// compare content
		eprintln(bench.step_message('Testing $test_file_path'))
		assert io.result() == json.encode(completion_results[test_name])
		bench.ok()
		println(bench.step_message_ok(test_name))
		// Delete document
		ls.dispatch(io.request_with_params('textDocument/didClose', lsp.DidCloseTextDocumentParams{
			text_document: doc_id
		}))
		bench.step()
	}
	bench.stop()
}
