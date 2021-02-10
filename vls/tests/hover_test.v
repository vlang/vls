import vls
import vls.testing
import json
import lsp
import os

// TODO:
const hover_inputs = {
	'enum.vv': lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'function.vv': lsp.HoverParams{
		position: lsp.Position{0, 6}
	}
	'import.vv': lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'module.vv': lsp.HoverParams{
		position: lsp.Position{0, 5}
	}
	'selector_expr.vv': lsp.HoverParams{
		position: lsp.Position{6, 10}
	}
	'struct.vv': lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'type_alias.vv': lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'type_fn.vv': lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'type_sum.vv': lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'variable.vv': lsp.HoverParams{
		position: lsp.Position{2, 12}
	}
}

const hover_results = {
	'enum.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'enum Color'}
		range: lsp.Range{
			start: lsp.Position{0,0}
			end: lsp.Position{4,10}
		}
	}
	'function.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'fn foo(param1 string, mut param2 []string) bool'}
		range: lsp.Range{
			start: lsp.Position{0,0}
			end: lsp.Position{2,47}
		}
	}
	'import.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'import os as os'}
		range: lsp.Range{
			start: lsp.Position{0,0}
			end: lsp.Position{0,9}
		}
	}
	'module.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'module foo'}
		range: lsp.Range{
			start: lsp.Position{0,0}
			end: lsp.Position{0,10}
		}
	}
	'selector_expr.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'Person.name string'}
		range: lsp.Range{
			start: lsp.Position{6,9}
			end: lsp.Position{6,13}
		}
	}
	'struct.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'struct Abc'}
		range: lsp.Range{
			start: lsp.Position{0,0}
			end: lsp.Position{2,10}
		}
	}
	'type_alias.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Str = string'}
		range: lsp.Range{
			start: lsp.Position{0,0}
			end: lsp.Position{0,8}
		}
	}
	'type_fn.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Handler = fn (string) string'}
		range: lsp.Range{
			start: lsp.Position{0,0}
			end: lsp.Position{0,12}
		}
	}
	'type_sum.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Any = int | string'}
		range: lsp.Range{
			start: lsp.Position{0,0}
			end: lsp.Position{0,8}
		}
	}
	'variable.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'num int'}
		range: lsp.Range{
			start: lsp.Position{2,10}
			end: lsp.Position{2,13}
		}
	}
}

fn test_hover() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path(os.dir(@FILE), 'test_files',
			'hover'))
	}))
	test_files := testing.load_test_file_paths('hover') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err))
		assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in hover_results {
			'missing results for $test_name'
		} else if test_name !in hover_inputs {
			'missing input data for $test_name'
		} else {
			''
		}
		if err_msg.len != 0 {
			io.bench.fail()
			eprintln(io.bench.step_message_fail(err_msg))
			continue
		}
		content := os.read_file(test_file_path) or {
			io.bench.fail()
			eprintln(io.bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		// open document
		req, doc_id := io.open_document(test_file_path, content)
		ls.dispatch(req)
		// initiate hover request
		ls.dispatch(io.request_with_params('textDocument/hover', lsp.HoverParams{
			...hover_inputs[test_name]
			text_document: doc_id
		}))
		// compare content
		println(io.bench.step_message('Testing $test_file_path'))
		assert io.result() == json.encode(hover_results[test_name])
		// Delete document
		ls.dispatch(io.close_document(doc_id))
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
