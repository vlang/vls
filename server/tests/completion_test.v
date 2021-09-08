import server
import server.testing
import json
import lsp
import os

const completion_inputs = {
	'assign.vv':                            lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{6, 7}
	}
	'blank.vv':                             lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{0, 0}
	}
	'call_args.vv':                         lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{10, 14}
	}
	'enum_val_in_struct.vv':                lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{14, 20}
	}
	'filtered_fields_in_selector.vv':       lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{16, 9}
	}
	'filtered_methods_in_immutable_var.vv': lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{13, 6}
	}
	'filtered_methods_in_mutable_var.vv':   lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{13, 6}
	}
	'import_symbols.vv':                    lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{2, 12}
	}
	'import.vv':                            lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{2, 7}
	}
	'incomplete_module.vv':                 lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{0, 7}
	}
	'incomplete_call_expr_selector.vv':     lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{11, 20}
	}
	'incomplete_nested_selector.vv':        lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{14, 10}
	}
	'incomplete_selector.vv':               lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{12, 6}
	}
	'invalid_call.vv':                      lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '('}
		position: lsp.Position{0, 4}
	}
	'local_results.vv':                     lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{5, 2}
	}
	'module_selector.vv':                   lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{3, 0}
	}
	'module_symbols_selector.vv':           lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{5, 6}
	}
	'struct_init.vv':                       lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '{'}
		position: lsp.Position{8, 16}
	}
	'struct_init_string_field.vv':          lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{9, 8}
	}
	'type_decl.vv':                         lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{3, 12}
	}
}

const completion_results = {
	'assign.vv':                            [
		lsp.CompletionItem{
			label: 'two'
			kind: .variable
			detail: 'two int'
			insert_text: 'two'
		},
		lsp.CompletionItem{
			label: 'zero'
			kind: .variable
			detail: 'mut zero int'
			insert_text: 'zero'
		},
	]
	'blank.vv':                             [
		lsp.CompletionItem{
			label: 'module main'
			kind: .variable
			insert_text: 'module main'
		},
		lsp.CompletionItem{
			label: 'module completion'
			kind: .variable
			insert_text: 'module completion'
		},
	]
	'call_args.vv':                         [
		lsp.CompletionItem{
			label: 'sample_num'
			kind: .variable
			detail: 'sample_num int'
			insert_text: 'sample_num'
		},
		lsp.CompletionItem{
			label: 'sample_num2'
			kind: .variable
			detail: 'sample_num2 int'
			insert_text: 'sample_num2'
		},
		lsp.CompletionItem{
			label: 'add_to_four'
			kind: .function
			detail: 'fn add_to_four(num int) int'
			insert_text: 'add_to_four(\$0)'
			insert_text_format: .snippet
		},
	]
	'enum_val_in_struct.vv':                [
		lsp.CompletionItem{
			label: '.golden_retriever'
			detail: 'Breed.golden_retriever int'
			kind: .enum_member
			insert_text: '.golden_retriever'
		},
		lsp.CompletionItem{
			label: '.beagle'
			detail: 'Breed.beagle int'
			kind: .enum_member
			insert_text: '.beagle'
		},
		lsp.CompletionItem{
			label: '.chihuahua'
			detail: 'Breed.chihuahua int'
			kind: .enum_member
			insert_text: '.chihuahua'
		},
		lsp.CompletionItem{
			label: '.dalmatian'
			detail: 'Breed.dalmatian int'
			kind: .enum_member
			insert_text: '.dalmatian'
		},
	]
	'filtered_fields_in_selector.vv':       [
		lsp.CompletionItem{
			label: 'output_file_name'
			detail: 'pub mut (Log).output_file_name string'
			kind: .property
			insert_text: 'output_file_name'
		},
	]
	'filtered_methods_in_immutable_var.vv': [
		lsp.CompletionItem{
			label: 'lol'
			kind: .method
			detail: 'fn (Foo) lol() string'
			insert_text: 'lol()'
			insert_text_format: .plain_text
		},
	]
	'filtered_methods_in_mutable_var.vv':   [
		lsp.CompletionItem{
			label: 'set_name'
			kind: .method
			detail: 'mut fn (Foo) set_name(name string)'
			insert_text: 'set_name(\$0)'
			insert_text_format: .snippet
		},
		lsp.CompletionItem{
			label: 'lol'
			kind: .method
			detail: 'fn (Foo) lol() string'
			insert_text: 'lol()'
			insert_text_format: .plain_text
		},
	]
	'import_symbols.vv':                    [
		lsp.CompletionItem{
			label: 'DB'
			kind: .struct_
			detail: 'pub struct DB'
			insert_text: 'DB'
		},
		lsp.CompletionItem{
			label: 'Row'
			kind: .struct_
			detail: 'pub struct Row'
			insert_text: 'Row'
		},
		lsp.CompletionItem{
			label: 'Config'
			kind: .struct_
			detail: 'pub struct Config'
			insert_text: 'Config'
		},
		lsp.CompletionItem{
			label: 'connect'
			kind: .function
			detail: 'pub fn connect(config Config) ?DB'
			insert_text: 'connect'
		},
	]
	'import.vv':                            [
		lsp.CompletionItem{
			label: 'abc'
			kind: .folder
			insert_text: 'abc'
		},
		lsp.CompletionItem{
			label: 'abc.def'
			kind: .folder
			insert_text: 'abc.def'
		},
		lsp.CompletionItem{
			label: 'abc.def.ghi'
			kind: .folder
			insert_text: 'abc.def.ghi'
		},
	]
	'incomplete_module.vv':                 [
		lsp.CompletionItem{
			label: 'module main'
			kind: .variable
			insert_text: 'module main'
		},
		lsp.CompletionItem{
			label: 'module completion'
			kind: .variable
			insert_text: 'module completion'
		},
	]
	'incomplete_nested_selector.vv':        [
		lsp.CompletionItem{
			label: 'name'
			kind: .property
			detail: 'Barw.name string'
			insert_text: 'name'
		},
		lsp.CompletionItem{
			label: 'theres_a_method'
			kind: .method
			detail: 'fn (Barw) theres_a_method()'
			insert_text: 'theres_a_method()'
			insert_text_format: .plain_text
		},
	]
	'incomplete_selector.vv':               [
		lsp.CompletionItem{
			label: 'name'
			kind: .property
			detail: 'Foo.name string'
			insert_text: 'name'
		},
		lsp.CompletionItem{
			label: 'lol'
			kind: .method
			detail: 'fn (Foo) lol() string'
			insert_text: 'lol()'
			insert_text_format: .plain_text
		},
	]
	'incomplete_call_expr_selector.vv':     [
		lsp.CompletionItem{
			label: 'len'
			kind: .property
			detail: 'Bee.len int'
			insert_text: 'len'
		},
	]
	'invalid_call.vv':                      []lsp.CompletionItem{}
	'local_results.vv':                     [
		lsp.CompletionItem{
			label: 'foo'
			kind: .variable
			detail: 'foo string'
			insert_text: 'foo'
		},
		lsp.CompletionItem{
			label: 'bar'
			kind: .variable
			detail: 'bar int'
			insert_text: 'bar'
		},
	]
	'module_selector.vv':                   [
		lsp.CompletionItem{
			label: 'def'
			kind: .module_
			insert_text: 'def'
		},
	]
	'module_symbols_selector.vv':           [
		lsp.CompletionItem{
			label: 'Point'
			kind: .struct_
			detail: 'pub struct Point'
			insert_text: 'Point{a:\$0, b:\$1}'
			insert_text_format: .snippet
		},
		lsp.CompletionItem{
			label: 'this_is_a_function'
			kind: .function
			detail: 'pub fn this_is_a_function() string'
			insert_text: 'this_is_a_function()'
		},
	]
	'struct_init.vv':                       [
		lsp.CompletionItem{
			label: 'name:'
			detail: 'Person.name string'
			kind: .field
			insert_text_format: .snippet
			insert_text: 'name: \$0'
		},
		lsp.CompletionItem{
			label: 'age:'
			detail: 'Person.age int'
			kind: .field
			insert_text_format: .snippet
			insert_text: 'age: \$0'
		},
	]
	'struct_init_string_field.vv':          [
		lsp.CompletionItem{
			label: 'name'
			kind: .variable
			detail: 'name string'
			insert_text: 'name'
		},
		lsp.CompletionItem{
			label: 'another_name'
			kind: .variable
			detail: 'another_name string'
			insert_text: 'another_name'
		},
	]
	'type_decl.vv':                         [
		lsp.CompletionItem{
			label: 'Foo'
			kind: .struct_
			detail: 'struct Foo'
			insert_text: 'Foo'
		},
		lsp.CompletionItem{
			label: 'Bar'
			kind: .struct_
			detail: 'struct Bar'
			insert_text: 'Bar'
		},
	]
}

fn test_completion() {
	mut io := &testing.Testio{}
	mut ls := server.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path(os.dir(@FILE), 'test_files',
			'completion'))
	}))
	test_files := testing.load_test_file_paths('completion') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg))
		assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in completion_results {
			'missing results for $test_name'
		} else if test_name !in completion_inputs {
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
		// initiate completion request
		ls.dispatch(io.request_with_params('textDocument/completion', lsp.CompletionParams{
			...completion_inputs[test_name]
			text_document: doc_id
		}))
		// compare content
		println(io.bench.step_message('Testing $test_file_path'))
		assert io.result() == json.encode(completion_results[test_name])
		// Delete document
		ls.dispatch(io.close_document(doc_id))
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
