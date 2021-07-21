import vls
import vls.testing
import json
import lsp
import os

const hover_inputs = map{
	'call_expr_method.vv':     lsp.HoverParams{
		position: lsp.Position{10, 16}
	}
	'call_expr_simple.vv':     lsp.HoverParams{
		position: lsp.Position{5, 6}
	}
	'enum.vv':                 lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'function_param.vv':       lsp.HoverParams{
		position: lsp.Position{2, 18}
	}
	'function.vv':             lsp.HoverParams{
		position: lsp.Position{0, 5}
	}
	'import.vv':               lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'module.vv':               lsp.HoverParams{
		position: lsp.Position{0, 5}
	}
	'node_error.vv':           lsp.HoverParams{
		position: lsp.Position{6, 5}
	}
	'selector_expr.vv':        lsp.HoverParams{
		position: lsp.Position{6, 10}
	}
	'struct.vv':               lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'struct_field.vv':         lsp.HoverParams{
		position: lsp.Position{3, 4}
	}
	'struct_init.vv':          lsp.HoverParams{
		position: lsp.Position{8, 7}
	}
	'type_alias.vv':           lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'type_fn.vv':              lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'type_sum.vv':             lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'variable.vv':             lsp.HoverParams{
		position: lsp.Position{2, 12}
	}
	'with_call_expr_below.vv': lsp.HoverParams{
		position: lsp.Position{3, 4}
	}
}

const hover_should_return_null = ['node_error.vv']

const hover_results = map{
	'call_expr_method.vv':     lsp.Hover{
		contents: lsp.MarkedString{'v', 'fn (Foo) call() string'}
		range: lsp.Range{
			start: lsp.Position{10, 13}
			end: lsp.Position{10, 17}
		}
	}
	'call_expr_simple.vv':     lsp.Hover{
		contents: lsp.MarkedString{'v', 'fn greet(name string) void'}
		range: lsp.Range{
			start: lsp.Position{5, 2}
			end: lsp.Position{5, 7}
		}
	}
	'enum.vv':                 lsp.Hover{
		contents: lsp.MarkedString{'v', 'Color'}
		range: lsp.Range{
			start: lsp.Position{0, 5}
			end: lsp.Position{0, 10}
		}
	}
	'function_param.vv':       lsp.Hover{
		contents: lsp.MarkedString{'v', 'mut arr []string'}
		range: lsp.Range{
			start: lsp.Position{2, 17}
			end: lsp.Position{2, 20}
		}
	}
	'function.vv':             lsp.Hover{
		contents: lsp.MarkedString{'v', 'fn foo(param1 string, mut param2 []string) bool'}
		range: lsp.Range{
			start: lsp.Position{0, 3}
			end: lsp.Position{0, 6}
		}
	}
	'import.vv':               lsp.Hover{
		contents: lsp.MarkedString{'v', 'import os as os'}
		range: lsp.Range{
			start: lsp.Position{0, 7}
			end: lsp.Position{0, 9}
		}
	}
	'module.vv':               lsp.Hover{
		contents: lsp.MarkedString{'v', 'module foo'}
		range: lsp.Range{
			start: lsp.Position{0, 0}
			end: lsp.Position{0, 10}
		}
	}
	'node_error.vv':           lsp.Hover{}
	'selector_expr.vv':        lsp.Hover{
		contents: lsp.MarkedString{'v', '(Person).name string'}
		range: lsp.Range{
			start: lsp.Position{6, 9}
			end: lsp.Position{6, 13}
		}
	}
	'struct.vv':               lsp.Hover{
		contents: lsp.MarkedString{'v', 'Abc'}
		range: lsp.Range{
			start: lsp.Position{0, 7}
			end: lsp.Position{0, 10}
		}
	}
	'struct_field.vv':         lsp.Hover{
		contents: lsp.MarkedString{'v', '(Foo).bar string'}
		range: lsp.Range{
			start: lsp.Position{3, 2}
			end: lsp.Position{3, 5}
		}
	}
	'struct_init.vv':          lsp.Hover{
		contents: lsp.MarkedString{'v', '(Person).name string'}
		range: lsp.Range{
			start: lsp.Position{8, 4}
			end: lsp.Position{8, 8}
		}
	}
	'type_alias.vv':           lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Str = string'}
		range: lsp.Range{
			start: lsp.Position{0, 5}
			end: lsp.Position{0, 8}
		}
	}
	'type_fn.vv':              lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Handler = fn (string) string'}
		range: lsp.Range{
			start: lsp.Position{0, 0}
			end: lsp.Position{0, 12}
		}
	}
	'type_sum.vv':             lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Any = int | string'}
		range: lsp.Range{
			start: lsp.Position{0, 0}
			end: lsp.Position{0, 8}
		}
	}
	'variable.vv':             lsp.Hover{
		contents: lsp.MarkedString{'v', 'num int'}
		range: lsp.Range{
			start: lsp.Position{2, 10}
			end: lsp.Position{2, 13}
		}
	}
	'with_call_expr_below.vv': lsp.Hover{
		contents: lsp.MarkedString{'v', 'test int'}
		range: lsp.Range{
			start: lsp.Position{3, 1}
			end: lsp.Position{3, 5}
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
		eprintln(io.bench.step_message_fail(err.msg))
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
		result := io.result()
		if test_name in hover_should_return_null {
			assert result == 'null'
		} else {
			assert result == json.encode(hover_results[test_name])
		}
		// Delete document
		ls.dispatch(io.close_document(doc_id))
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
