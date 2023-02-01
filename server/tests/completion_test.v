import os
import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp

const github_job = os.getenv('GITHUB_JOB')

const flaky_tests = [
	'import_symbols.vv',
]

const c_completion_item = lsp.CompletionItem{
	label: 'C'
	kind: .module_
	detail: 'C symbol definitions'
	insert_text: 'C.'
}

const completion_inputs = {
	'assign.vv':                             lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{6, 7}
	}
	'binded_symbol.vv':                      lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{5, 4}
	}
	'blank.vv':                              lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{0, 0}
	}
	'call_args.vv':                          lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{10, 14}
	}
	'embedded_struct_field.vv':              lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{15, 15}
	}
	'enum_member.vv':                        lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{5, 20}
	}
	'enum_method.vv':                        lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{5, 27}
	}
	'enum_val_in_struct.vv':                 lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{18, 20}
	}
	'filtered_fields_in_selector.vv':        lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{16, 9}
	}
	'filtered_methods_in_immutable_var.vv':  lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{13, 6}
	}
	'filtered_methods_in_mutable_var.vv':    lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{13, 6}
	}
	'fn_literal.vv':                         lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, '.'}
		position: lsp.Position{5, 3}
	}
	'import_symbols.vv':                     lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{2, 12}
	}
	'import.vv':                             lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{2, 7}
	}
	'incomplete_enum_selector.vv':           lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{12, 6}
	}
	'incomplete_module.vv':                  lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{0, 7}
	}
	'incomplete_call_expr_selector.vv':      lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{11, 20}
	}
	'incomplete_nested_selector.vv':         lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{14, 10}
	}
	'incomplete_selector.vv':                lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{12, 6}
	}
	'invalid_call.vv':                       lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '('}
		position: lsp.Position{0, 4}
	}
	'local_results.vv':                      lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{5, 2}
	}
	'module_selector.vv':                    lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{3, 0}
	}
	'module_symbols_selector.vv':            lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '.'}
		position: lsp.Position{5, 6}
	}
	'self_reference_var_in_struct_field.vv': lsp.CompletionParams{
		context: lsp.CompletionContext{.invoked, ''}
		position: lsp.Position{6, 9}
	}
	'struct_init.vv':                        lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, '{'}
		position: lsp.Position{8, 16}
	}
	'struct_init_string_field.vv':           lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{9, 8}
	}
	'type_decl.vv':                          lsp.CompletionParams{
		context: lsp.CompletionContext{.trigger_character, ' '}
		position: lsp.Position{3, 12}
	}
}

const completion_results = {
	'assign.vv':                             [
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
	'binded_symbol.vv':                      [
		lsp.CompletionItem{
			label: 'C.Foo'
			kind: .struct_
			detail: 'struct C.Foo'
			insert_text: 'Foo\{bar:\$1, baz:\$2, data:\$3, count:\$4}'
			insert_text_format: .snippet
		},
	]
	'blank.vv':                              [
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
	'call_args.vv':                          [
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
	'embedded_struct_field.vv':              [
		lsp.CompletionItem{
			label: 'Point'
			kind: .property
			detail: 'Point'
			insert_text: 'Point'
		},
		lsp.CompletionItem{
			label: 'Point.a'
			kind: .property
			detail: 'pub abc.Point.a int'
			insert_text: 'Point.a'
		},
		lsp.CompletionItem{
			label: 'Point.b'
			kind: .property
			detail: 'pub abc.Point.b int'
			insert_text: 'Point.b'
		},
		lsp.CompletionItem{
			label: 'z'
			kind: .property
			detail: 'ThreeDPoint.z int'
			insert_text: 'z'
		},
	]
	'enum_member.vv':                        [
		lsp.CompletionItem{
			label: 'shift'
			kind: .enum_member
			detail: 'pub abc.KeyCode.shift abc.KeyCode'
			insert_text: 'shift'
		},
		lsp.CompletionItem{
			label: 'control'
			kind: .enum_member
			detail: 'pub abc.KeyCode.control abc.KeyCode'
			insert_text: 'control'
		},
	]
	'enum_method.vv':                        [
		lsp.CompletionItem{
			label: 'print'
			kind: .method
			detail: 'pub fn (code abc.KeyCode) print()'
			insert_text: 'print()'
		},
	]
	'enum_val_in_struct.vv':                 [
		lsp.CompletionItem{
			label: '.golden_retriever'
			detail: 'Breed.golden_retriever Breed'
			kind: .enum_member
			insert_text: '.golden_retriever'
		},
		lsp.CompletionItem{
			label: '.beagle'
			detail: 'Breed.beagle Breed'
			kind: .enum_member
			insert_text: '.beagle'
		},
		lsp.CompletionItem{
			label: '.chihuahua'
			detail: 'Breed.chihuahua Breed'
			kind: .enum_member
			insert_text: '.chihuahua'
		},
		lsp.CompletionItem{
			label: '.dalmatian'
			detail: 'Breed.dalmatian Breed'
			kind: .enum_member
			insert_text: '.dalmatian'
		},
	]
	'filtered_fields_in_selector.vv':        [
		lsp.CompletionItem{
			label: 'output_file_name'
			detail: 'pub mut Log.output_file_name string'
			kind: .property
			insert_text: 'output_file_name'
		},
	]
	'filtered_methods_in_immutable_var.vv':  [
		lsp.CompletionItem{
			label: 'set_name'
			kind: .method
			detail: 'fn (mut f Foo) set_name(name string)'
			insert_text: 'set_name(\$0)'
			insert_text_format: .snippet
		},
		lsp.CompletionItem{
			label: 'lol'
			kind: .method
			detail: 'fn (f Foo) lol() string'
			insert_text: 'lol()'
			insert_text_format: .plain_text
		},
	]
	'filtered_methods_in_mutable_var.vv':    [
		lsp.CompletionItem{
			label: 'set_name'
			kind: .method
			detail: 'fn (mut f Foo) set_name(name string)'
			insert_text: 'set_name(\$0)'
			insert_text_format: .snippet
		},
		lsp.CompletionItem{
			label: 'lol'
			kind: .method
			detail: 'fn (f Foo) lol() string'
			insert_text: 'lol()'
			insert_text_format: .plain_text
		},
	]
	'fn_literal.vv':                         [
		c_completion_item,
		lsp.CompletionItem{
			label: 'cmd'
			kind: .variable
			detail: 'cmd int'
			insert_text: 'cmd'
		},
		lsp.CompletionItem{
			label: 'gs'
			kind: .variable
			detail: 'gs string'
			insert_text: 'gs'
		},
		lsp.CompletionItem{
			label: 'list_exec'
			kind: .variable
			detail: 'list_exec fn (cmd int)'
			insert_text: 'list_exec'
		},
	]
	'import_symbols.vv':                     [
		lsp.CompletionItem{
			label: 'DB'
			kind: .struct_
			detail: 'pub struct pg.DB'
			insert_text: 'DB'
		},
		lsp.CompletionItem{
			label: 'Row'
			kind: .struct_
			detail: 'pub struct pg.Row'
			insert_text: 'Row'
		},
		lsp.CompletionItem{
			label: 'Config'
			kind: .struct_
			detail: 'pub struct pg.Config'
			insert_text: 'Config'
		}
		lsp.CompletionItem{
			label: 'connect'
			kind: .function
			detail: 'pub fn pg.connect(config pg.Config) !pg.DB'
			insert_text: 'connect'
		},
		lsp.CompletionItem{
			label: 'ConnStatusType'
			kind: .enum_
			detail: 'pub enum pg.ConnStatusType'
			insert_text: 'ConnStatusType'
			insert_text_format: .plain_text
		},
		lsp.CompletionItem{
			label: 'Oid'
			kind: .enum_
			detail: 'pub enum pg.Oid'
			insert_text: 'Oid'
		},
	]
	'import.vv':                             [
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
	'incomplete_enum_selector.vv':           [
		lsp.CompletionItem{
			label: 'print'
			kind: .method
			detail: 'fn (c Color) print()'
			insert_text: 'print()'
			insert_text_format: .plain_text
		},
	]
	'incomplete_module.vv':                  [
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
	'incomplete_nested_selector.vv':         [
		lsp.CompletionItem{
			label: 'name'
			kind: .property
			detail: 'Barw.name string'
			insert_text: 'name'
		},
		lsp.CompletionItem{
			label: 'theres_a_method'
			kind: .method
			detail: 'fn (b Barw) theres_a_method()'
			insert_text: 'theres_a_method()'
			insert_text_format: .plain_text
		},
	]
	'incomplete_selector.vv':                [
		lsp.CompletionItem{
			label: 'name'
			kind: .property
			detail: 'Foo.name string'
			insert_text: 'name'
		},
		lsp.CompletionItem{
			label: 'lol'
			kind: .method
			detail: 'fn (f Foo) lol() string'
			insert_text: 'lol()'
			insert_text_format: .plain_text
		},
	]
	'incomplete_call_expr_selector.vv':      [
		lsp.CompletionItem{
			label: 'len'
			kind: .property
			detail: 'Bee.len int'
			insert_text: 'len'
		},
	]
	'invalid_call.vv':                       []lsp.CompletionItem{}
	'local_results.vv':                      [
		c_completion_item,
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
	'module_selector.vv':                    [
		lsp.CompletionItem{
			label: 'def'
			kind: .module_
			insert_text: 'def'
		},
		c_completion_item,
	]
	'module_symbols_selector.vv':            [
		lsp.CompletionItem{
			label: 'Point'
			kind: .struct_
			detail: 'pub struct abc.Point'
			insert_text: 'Point\{a:\$1, b:\$2}'
			insert_text_format: .snippet
		},
		lsp.CompletionItem{
			label: 'this_is_a_function'
			kind: .function
			detail: 'pub fn abc.this_is_a_function() string'
			insert_text: 'this_is_a_function()'
		},
		lsp.CompletionItem{
			label: 'KeyCode'
			kind: .enum_
			detail: 'pub enum abc.KeyCode'
			insert_text: 'KeyCode'
		},
		lsp.CompletionItem{
			label: 'KeyCode.shift'
			kind: .enum_member
			detail: 'pub abc.KeyCode.shift abc.KeyCode'
			insert_text: 'KeyCode.shift'
		},
		lsp.CompletionItem{
			label: 'KeyCode.control'
			kind: .enum_member
			detail: 'pub abc.KeyCode.control abc.KeyCode'
			insert_text: 'KeyCode.control'
		},
	]
	'self_reference_var_in_struct_field.vv': [
		lsp.CompletionItem{
			label: 'cmd:'
			kind: .field
			insert_text: 'cmd: \$0'
			insert_text_format: .snippet
			detail: 'Command.cmd &Command'
		},
		lsp.CompletionItem{
			label: 'test'
			kind: .variable
			detail: 'test &Command'
			insert_text: 'test'
		},
	]
	'struct_init.vv':                        [
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
	'struct_init_string_field.vv':           [
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
	'type_decl.vv':                          [
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

fn sort_completion_item(a &lsp.CompletionItem, b &lsp.CompletionItem) int {
	if int(a.kind) < int(b.kind) {
		return 1
	} else if int(a.kind) > int(b.kind) {
		return -1
	} else if a.label < b.label {
		return 1
	} else if a.label > b.label {
		return -1
	}
	return 0
}

fn test_completion() {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'completion'
		client: new_test_client(ls)
	}

	mut writer := t.client.server.writer()
	test_files := t.initialize()?
	for file in test_files {
		test_name := file.file_name
		if github_job == 'v-apps-compile' && test_name in flaky_tests {
			eprintln('> skipping flaky `$test_name` on the `v-apps-compile` CI job')
			continue
		}
		err_msg := if test_name !in completion_results {
			'missing results'
		} else if test_name !in completion_inputs {
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

		// initiate completion request
		if actual := ls.completion(lsp.CompletionParams{
			...completion_inputs[test_name]
			text_document: doc_id
		}, mut writer)
		{
			// compare content
			mut expected := completion_results[test_name].clone()
			mut aactual := actual.clone()

			// sort results only if test case is flaky
			if test_name in flaky_tests {
				expected.sort_with_compare(sort_completion_item)
				aactual.sort_with_compare(sort_completion_item)
			}

			if _ := t.is_equal(expected, aactual) {
				t.ok(file)
			} else {
				t.fail(file, err.msg())
			}
		} else {
			t.fail(file, err.msg())
		}

		// Delete document
		t.close_document(doc_id) or {
			t.fail(file, err.msg())
			continue
		}
	}

	assert t.is_ok()
}
