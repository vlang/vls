import os
import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp

const hover_inputs = {
	'call_expr_method.vv':      lsp.HoverParams{
		position: lsp.Position{10, 16}
	}
	'call_expr_simple.vv':      lsp.HoverParams{
		position: lsp.Position{5, 6}
	}
	'enum.vv':                  lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'fn_literal.vv':            lsp.HoverParams{
		position: lsp.Position{5, 13}
	}
	'function_param.vv':        lsp.HoverParams{
		position: lsp.Position{2, 18}
	}
	'function.vv':              lsp.HoverParams{
		position: lsp.Position{1, 5}
	}
	'import.vv':                lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'interface_spec.vv':        lsp.HoverParams{
		position: lsp.Position{1, 10}
	}
	'interface_spec_params.vv': lsp.HoverParams{
		position: lsp.Position{1, 8}
	}
	'module.vv':                lsp.HoverParams{
		position: lsp.Position{0, 5}
	}
	'node_error.vv':            lsp.HoverParams{
		position: lsp.Position{6, 5}
	}
	'selector_expr.vv':         lsp.HoverParams{
		position: lsp.Position{6, 10}
	}
	'struct.vv':                lsp.HoverParams{
		position: lsp.Position{0, 8}
	}
	'struct_field.vv':          lsp.HoverParams{
		position: lsp.Position{3, 4}
	}
	'struct_init_a.vv':         lsp.HoverParams{
		position: lsp.Position{8, 7}
	}
	'struct_init_b.vv':         lsp.HoverParams{
		position: lsp.Position{7, 5}
	}
	'type_alias.vv':            lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'type_fn.vv':               lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'type_sum.vv':              lsp.HoverParams{
		position: lsp.Position{0, 7}
	}
	'variable.vv':              lsp.HoverParams{
		position: lsp.Position{2, 12}
	}
	'with_call_expr_below.vv':  lsp.HoverParams{
		position: lsp.Position{3, 4}
	}
}

const hover_should_return_null = ['node_error.vv']

const hover_results = {
	'call_expr_method.vv':      lsp.Hover{
		contents: lsp.MarkedString{'v', 'fn (foo Foo) call() string'}
		range: lsp.Range{
			start: lsp.Position{10, 13}
			end: lsp.Position{10, 17}
		}
	}
	'call_expr_simple.vv':      lsp.Hover{
		contents: lsp.MarkedString{'v', 'fn greet(name string)'}
		range: lsp.Range{
			start: lsp.Position{5, 2}
			end: lsp.Position{5, 7}
		}
	}
	'enum.vv':                  lsp.Hover{
		contents: lsp.MarkedString{'v', 'enum Color'}
		range: lsp.Range{
			start: lsp.Position{0, 5}
			end: lsp.Position{0, 10}
		}
	}
	'function_param.vv':        lsp.Hover{
		contents: lsp.MarkupContent{
			kind: 'markdown'
			value: '```v\n[]string\n```'
		}
		range: lsp.Range{
			start: lsp.Position{2, 17}
			end: lsp.Position{2, 20}
		}
	}
	'function.vv':              lsp.Hover{
		contents: lsp.MarkupContent{
			kind: lsp.markup_kind_markdown,
			value: '```v\nfn foo(param1 string, mut param2 []string) bool\n```\n\n---\n\nthis is docstring'
		}
		range: lsp.Range{
			start: lsp.Position{1, 3}
			end: lsp.Position{1, 6}
		}
	}
	'import.vv':                lsp.Hover{
		contents: lsp.MarkupContent{
			kind: 'markdown'
			value: '```v\nimport os\n```\n\n---\n\nFound at ${os.join_path(@VEXEROOT, 'vlib', 'os')}'
		}
		range: lsp.Range{
			start: lsp.Position{0, 7}
			end: lsp.Position{0, 9}
		}
	}
	'interface_spec.vv':        lsp.Hover{
		contents: lsp.MarkedString{'v', 'pub fn (Fooer) random_num() int'}
		range: lsp.Range{
			start: lsp.Position{1, 1}
			end: lsp.Position{1, 11}
		}
	}
	'interface_spec_params.vv': lsp.Hover{
		contents: lsp.MarkupContent{
			kind: 'markdown'
			value: '```v\ntype int\n```'
		}
		range: lsp.Range{
			start: lsp.Position{1, 6}
			end: lsp.Position{1, 9}
		}
	}
	'fn_literal.vv':            lsp.Hover{
		contents: lsp.MarkupContent{
			kind: 'markdown'
			value: '```v\ntype int\n```'
		}
		range: lsp.Range{
			start: lsp.Position{5, 12}
			end: lsp.Position{5, 15}
		}
	}
	'module.vv':                lsp.Hover{
		contents: lsp.MarkedString{'v', 'module foo'}
		range: lsp.Range{
			start: lsp.Position{0, 7}
			end: lsp.Position{0, 10}
		}
	}
	'node_error.vv':            lsp.Hover{}
	'selector_expr.vv':         lsp.Hover{
		contents: lsp.MarkedString{'v', 'Person.name string'}
		range: lsp.Range{
			start: lsp.Position{6, 9}
			end: lsp.Position{6, 13}
		}
	}
	'struct.vv':                lsp.Hover{
		contents: lsp.MarkedString{'v', 'struct Abc'}
		range: lsp.Range{
			start: lsp.Position{0, 7}
			end: lsp.Position{0, 10}
		}
	}
	'struct_field.vv':          lsp.Hover{
		contents: lsp.MarkedString{'v', 'Foo.bar string'}
		range: lsp.Range{
			start: lsp.Position{3, 2}
			end: lsp.Position{3, 5}
		}
	}
	'struct_init_a.vv':         lsp.Hover{
		contents: lsp.MarkedString{'v', 'Person.name string'}
		range: lsp.Range{
			start: lsp.Position{8, 4}
			end: lsp.Position{8, 8}
		}
	}
	'struct_init_b.vv':         lsp.Hover{
		contents: lsp.MarkedString{'v', 'pub mut cli.Command.usage string'}
		range: lsp.Range{
			start: lsp.Position{7, 2}
			end: lsp.Position{7, 7}
		}
	}
	'type_alias.vv':            lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Str = string'}
		range: lsp.Range{
			start: lsp.Position{0, 5}
			end: lsp.Position{0, 8}
		}
	}
	'type_fn.vv':               lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Handler = fn (test string) string'}
		range: lsp.Range{
			start: lsp.Position{0, 5}
			end: lsp.Position{0, 12}
		}
	}
	'type_sum.vv':              lsp.Hover{
		contents: lsp.MarkedString{'v', 'type Any = int | string'}
		range: lsp.Range{
			start: lsp.Position{0, 5}
			end: lsp.Position{0, 8}
		}
	}
	'variable.vv':              lsp.Hover{
		contents: lsp.MarkupContent{
			kind: 'markdown'
			value: '```v\ntype int\n```'
		}
		range: lsp.Range{
			start: lsp.Position{2, 10}
			end: lsp.Position{2, 13}
		}
	}
	'with_call_expr_below.vv':  lsp.Hover{
		contents: lsp.MarkupContent{
			kind: 'markdown'
			value: '```v\ntype int\n```'
		}
		range: lsp.Range{
			start: lsp.Position{3, 1}
			end: lsp.Position{3, 5}
		}
	}
}

fn test_hover() {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'hover'
		client: new_test_client(ls)
	}
	mut writer := t.client.server.writer()
	test_files := t.initialize()!
	for file in test_files {
		test_name := file.file_name
		err_msg := if test_name !in hover_results {
			'missing results'
		} else if test_name !in hover_inputs {
			'missing input data'
		} else {
			''
		}
		if err_msg.len != 0 {
			t.fail(file, err_msg)
			continue
		}
		// open document
		doc_id := t.open_document(file) or {
			t.fail(file, err.msg())
			continue
		}
		// initiate hover request
		if actual := ls.hover(lsp.HoverParams{
			...hover_inputs[test_name]
			text_document: doc_id
		}, mut writer)
		{
			// compare content
			if _ := t.is_equal(hover_results[test_name], actual) {
				t.ok(file)
			} else {
				t.fail(file, err.msg())
			}
		} else {
			t.is_null(file, test_name in hover_should_return_null, err)
		}
		// Delete document
		t.close_document(doc_id) or {
			t.fail(file, err.msg())
			continue
		}
	}
	assert t.is_ok()
}
