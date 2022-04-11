import server
import test_utils
import json
import lsp
import os

const base_dir = os.join_path(os.dir(@FILE), 'test_files', 'definition')

const definition_inputs = {
	'call_arg.vv':                lsp.Position{4, 17}
	'call_expr.vv':               lsp.Position{3, 10}
	'enum_val.vv':                lsp.Position{7, 12}
	'expr_in_array.vv':           lsp.Position{2, 19}
	'expr_in_map_key.vv':         lsp.Position{4, 10}
	'expr_in_map_value.vv':       lsp.Position{4, 17}
	'fn_literal.vv':              lsp.Position{5, 13}
	'fn_param_type.vv':           lsp.Position{4, 15}
	'fn_return_type.vv':          lsp.Position{2, 18}
	'index_expr.vv':              lsp.Position{3, 18}
	'interface_field.vv':         lsp.Position{3, 11}
	'interface_method.vv':        lsp.Position{5, 13}
	'node_error.vv':              lsp.Position{3, 14}
	'selector_expr.vv':           lsp.Position{6, 10}
	'stmt.vv':                    lsp.Position{0, 23}
	'struct_field_type.vv':       lsp.Position{3, 8}
	'struct_init_field_name.vv':  lsp.Position{5, 16}
	'struct_init_field_value.vv': lsp.Position{10, 23}
	'struct_init.vv':             lsp.Position{5, 11}
	'var_receiver.vv':            lsp.Position{3, 9}
	'var.vv':                     lsp.Position{2, 11}
}

const definition_should_return_null = [
	'node_error.vv'
	// 'stmt.vv'
]

const definition_results = {
	'call_arg.vv':                [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'call_arg.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{4, 16}
				end: lsp.Position{4, 18}
			}
			target_range: lsp.Range{
				start: lsp.Position{3, 2}
				end: lsp.Position{3, 4}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{3, 2}
				end: lsp.Position{3, 4}
			}
		},
	]
	'call_expr.vv':               [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'call_expr.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{3, 2}
				end: lsp.Position{3, 15}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 3}
				end: lsp.Position{0, 16}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 3}
				end: lsp.Position{0, 16}
			}
		},
	]
	'enum_val.vv':                [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'enum_val.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{7, 9}
				end: lsp.Position{7, 19}
			}
			target_range: lsp.Range{
				start: lsp.Position{3, 2}
				end: lsp.Position{3, 6}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{3, 2}
				end: lsp.Position{3, 6}
			}
		},
	]
	'expr_in_array.vv':           [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'expr_in_array.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{2, 12}
				end: lsp.Position{2, 23}
			}
			target_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 13}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 13}
			}
		},
	]
	'expr_in_map_key.vv':         [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'expr_in_map_key.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{4, 4}
				end: lsp.Position{4, 15}
			}
			target_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 13}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 13}
			}
		},
	]
	'expr_in_map_value.vv':       [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'expr_in_map_value.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{4, 11}
				end: lsp.Position{4, 22}
			}
			target_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 13}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 13}
			}
		},
	]
	'fn_literal.vv':              [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'fn_literal.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{5, 12}
				end: lsp.Position{5, 14}
			}
			target_range: lsp.Range{
				start: lsp.Position{4, 4}
				end: lsp.Position{4, 6}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{4, 4}
				end: lsp.Position{4, 6}
			}
		},
	]
	'fn_param_type.vv':           [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'fn_param_type.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{4, 14}
				end: lsp.Position{4, 16}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 7}
				end: lsp.Position{0, 9}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 7}
				end: lsp.Position{0, 9}
			}
		},
	]
	'fn_return_type.vv':          [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'fn_return_type.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{2, 16}
				end: lsp.Position{2, 20}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 5}
				end: lsp.Position{0, 9}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 5}
				end: lsp.Position{0, 9}
			}
		},
	]
	'index_expr.vv':              [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'index_expr.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{3, 16}
				end: lsp.Position{3, 20}
			}
			target_range: lsp.Range{
				start: lsp.Position{2, 2}
				end: lsp.Position{2, 6}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{2, 2}
				end: lsp.Position{2, 6}
			}
		},
	]
	'interface_field.vv':         [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'interface_field.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{3, 10}
				end: lsp.Position{3, 13}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 5}
				end: lsp.Position{0, 8}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 5}
				end: lsp.Position{0, 8}
			}
		},
	]
	'interface_method.vv':        [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'interface_method.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{5, 10}
				end: lsp.Position{6, 16}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 0}
				end: lsp.Position{2, 11}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 0}
				end: lsp.Position{2, 11}
			}
		},
	]
	'selector_expr.vv':           [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'selector_expr.vv'))
			origin_selection_range: lsp.Range{
				// TODO:
				start: lsp.Position{6, 5}
				end: lsp.Position{6, 12}
			}
			target_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 9}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 9}
			}
		},
	]
	'struct_init_field_name.vv':  [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'struct_init_field_name.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{5, 15}
				end: lsp.Position{5, 19}
			}
			target_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 6}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 6}
			}
		},
	]
	'struct_field_type.vv':       [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'struct_field_type.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{3, 6}
				end: lsp.Position{3, 9}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 5}
				end: lsp.Position{0, 8}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 5}
				end: lsp.Position{0, 8}
			}
		},
	]
	'struct_init_field_value.vv': [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'struct_init_field_value.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{10, 22}
				end: lsp.Position{10, 27}
			}
			target_range: lsp.Range{
				start: lsp.Position{2, 2}
				end: lsp.Position{2, 6}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{2, 2}
				end: lsp.Position{2, 6}
			}
		},
	]
	'struct_init.vv':             [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'struct_init.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{5, 8}
				end: lsp.Position{5, 15}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 7}
				end: lsp.Position{0, 14}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 7}
				end: lsp.Position{0, 14}
			}
		},
	]
	'stmt.vv':                    [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'stmt.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{0, 3}
				end: lsp.Position{0, 28}
			}
			target_range: lsp.Range{
				start: lsp.Position{0, 3}
				end: lsp.Position{0, 28}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{0, 3}
				end: lsp.Position{0, 28}
			}
		},
	]
	'var_receiver.vv':            [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'var_receiver.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{3, 8}
				end: lsp.Position{3, 10}
			}
			target_range: lsp.Range{
				start: lsp.Position{2, 4}
				end: lsp.Position{2, 6}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{2, 4}
				end: lsp.Position{2, 6}
			}
		},
	]
	'var.vv':                     [
		lsp.LocationLink{
			target_uri: lsp.document_uri_from_path(os.join_path(base_dir, 'var.vv'))
			origin_selection_range: lsp.Range{
				start: lsp.Position{2, 10}
				end: lsp.Position{2, 13}
			}
			target_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 5}
			}
			target_selection_range: lsp.Range{
				start: lsp.Position{1, 2}
				end: lsp.Position{1, 5}
			}
		},
	]
}

fn test_definition() {
	mut io := test_utils.Testio{
		test_files_dir: test_utils.get_test_files_path(@FILE)
	}
	mut ls := server.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(base_dir)
	}))
	test_files := io.load_test_file_paths('definition') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg()))
		assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in definition_results
			&& test_name !in definition_should_return_null {
			'missing results for $test_name'
		} else if test_name !in definition_inputs {
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
		ls.dispatch(io.request_with_params('textDocument/definition', lsp.TextDocumentPositionParams{
			text_document: doc_id
			position: definition_inputs[test_name]
		}))
		// compare content
		println(io.bench.step_message('Testing $test_file_path'))
		result := io.result()
		if test_name in definition_should_return_null {
			assert result == 'null'
		} else {
			assert result == json.encode(definition_results[test_name])
		}
		// Delete document
		ls.dispatch(io.close_document(doc_id))
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
