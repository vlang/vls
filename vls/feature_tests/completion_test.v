import vls
import vls.testing
import json
import lsp
import os

// NOTE: skip module_symbols_selector for now, see note in text_synchronization.v#parse_imports 

const completion_contexts = {
	'assign.vv':              lsp.CompletionContext{.trigger_character, ' '}
	'blank.vv':               lsp.CompletionContext{.invoked, ''}
	'call_args.vv':						lsp.CompletionContext{.invoked, ''}
	'enum_val_in_struct.vv':	lsp.CompletionContext{.trigger_character, ' '}
	'import.vv':              lsp.CompletionContext{.trigger_character, ' '}
	'incomplete_module.vv':   lsp.CompletionContext{.invoked, ''}
	'incomplete_selector.vv': lsp.CompletionContext{.trigger_character, '.'}
	'local_results.vv':       lsp.CompletionContext{.invoked, ''}
	'module_symbols_selector.vv': lsp.CompletionContext{.trigger_character, '.'}
	'struct_init.vv':         lsp.CompletionContext{.trigger_character, '{'}
}

const completion_positions = {
	'assign.vv':              lsp.Position{6, 7}
	'blank.vv':               lsp.Position{0, 0}
	'call_args.vv':						lsp.Position{10, 14}
	'enum_val_in_struct.vv':	lsp.Position{14, 20}
	'import.vv':              lsp.Position{2, 7}
	'incomplete_module.vv':   lsp.Position{0, 7}
	'incomplete_selector.vv': lsp.Position{12, 6}
	'local_results.vv':       lsp.Position{5, 2}
	'module_symbols_selector.vv': lsp.Position{5, 6}
	'struct_init.vv':         lsp.Position{8, 16}
}

const completion_results = {
	'assign.vv':              [
		lsp.CompletionItem{
			label: 'two'
			kind: .variable
			insert_text: 'two'
		},
		lsp.CompletionItem{
			label: 'zero'
			kind: .variable
			insert_text: 'zero'
		},
	]
	'blank.vv':               [
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
	'call_args.vv':						[
		lsp.CompletionItem{
			label: 'sample_num'
			kind: .variable
			insert_text: 'sample_num'
		},
		lsp.CompletionItem{
			label: 'sample_num2'
			kind: .variable
			insert_text: 'sample_num2'
		},
	]
	'enum_val_in_struct.vv':						[
		lsp.CompletionItem{
			label: '.golden_retriever'
			kind: .enum_member
			insert_text: '.golden_retriever'
		},
		lsp.CompletionItem{
			label: '.beagle'
			kind: .enum_member
			insert_text: '.beagle'
		},
		lsp.CompletionItem{
			label: '.chihuahua'
			kind: .enum_member
			insert_text: '.chihuahua'
		},
		lsp.CompletionItem{
			label: '.dalmatian'
			kind: .enum_member
			insert_text: '.dalmatian'
		},
	]
	'import.vv':              [
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
	'incomplete_module.vv':   [
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
	'incomplete_selector.vv': [
		lsp.CompletionItem{
			label: 'name'
			kind: .field
			insert_text: 'name'
		},
		lsp.CompletionItem{
			label: 'lol'
			kind: .method
			insert_text: 'lol()'
			insert_text_format: .snippet
		},
	]
	'local_results.vv':       [
		lsp.CompletionItem{
			label: 'foo'
			kind: .variable
			insert_text: 'foo'
		},
		lsp.CompletionItem{
			label: 'bar'
			kind: .variable
			insert_text: 'bar'
		},
	]
	'module_symbols_selector.vv': [
		lsp.CompletionItem{
			label: 'Point'
			kind: .struct_
			insert_text: 'Point{}'
		},
		lsp.CompletionItem{
			label: 'this_is_a_function'
			kind: .function
			insert_text: 'this_is_a_function()'
			insert_text_format: .snippet
		},
	]
	'struct_init.vv':         [
		lsp.CompletionItem{
			label: 'name:'
			kind: .field
			insert_text_format: .snippet
			insert_text: 'name: \$0'
		},
		lsp.CompletionItem{
			label: 'age:'
			kind: .field
			insert_text_format: .snippet
			insert_text: 'age: \$0'
		},
	]
}

fn test_completion() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path(os.dir(@FILE), 'test_files', 'completion'))
	}))

	test_files := testing.load_test_file_paths('completion') or {
		assert false
		return
	}
	
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		test_name := os.base(test_file_path)
		mut err_msg := ''
		if test_name !in completion_results {
			err_msg = 'missing results for $test_name'
		} else if test_name !in completion_contexts{
			err_msg = 'missing context data for $test_name'
		} else if test_name !in completion_positions {
			err_msg = 'missing position data for $test_name'
		}
		if err_msg.len > 0 {
			io.bench.fail()
			eprintln(io.bench.step_message_fail(err_msg))
			assert false
		}
		content := os.read_file(test_file_path) or {
			io.bench.fail()
			eprintln(io.bench.step_message_fail('file $test_file_path is missing'))
			assert false
			return
		}
		// open document
		req, doc_id := io.open_document(test_file_path, content)
		ls.dispatch(req)
		// initiate completion request
		ls.dispatch(io.request_with_params('textDocument/completion', lsp.CompletionParams{
			text_document: doc_id
			position: completion_positions[test_name]
			context: completion_contexts[test_name]
		}))
		// compare content
		eprintln(io.bench.step_message('Testing $test_file_path'))
		assert io.result() == json.encode(completion_results[test_name])
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
		// Delete document
		ls.dispatch(io.close_document(doc_id))
	}
	io.bench.stop()
}
