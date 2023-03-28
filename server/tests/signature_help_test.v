import server
import test_utils
import jsonrpc.server_test_utils { new_test_client }
import lsp

const signature_help_inputs = {
	'empty_middle_arg.vv': lsp.SignatureHelpParams{
		context: lsp.SignatureHelpContext{
			trigger_kind: .invoked
		}
		position: lsp.Position{2, 7}
	}
	'empty_second_arg.vv': lsp.SignatureHelpParams{
		context: lsp.SignatureHelpContext{
			trigger_kind: .invoked
		}
		position: lsp.Position{6, 18}
	}
	'simple.vv':           lsp.SignatureHelpParams{
		context: lsp.SignatureHelpContext{
			trigger_kind: .trigger_character
			trigger_character: '('
		}
		position: lsp.Position{7, 8}
	}
	'with_content.vv':     lsp.SignatureHelpParams{
		context: lsp.SignatureHelpContext{
			trigger_kind: .invoked
		}
		position: lsp.Position{7, 16}
	}
	'with_content_b.vv':   lsp.SignatureHelpParams{
		context: lsp.SignatureHelpContext{
			trigger_kind: .invoked
		}
		position: lsp.Position{7, 11}
	}
}

const signature_help_results = {
	'empty_middle_arg.vv': lsp.SignatureHelp{
		signatures: [
			lsp.SignatureInformation{
				label: 'fn foo(a int, b f32, c i64)'
				parameters: [
					lsp.ParameterInformation{'a int'},
					lsp.ParameterInformation{'b f32'},
					lsp.ParameterInformation{'c i64'},
				]
			},
		]
		active_parameter: 1
	}
	'empty_second_arg.vv': lsp.SignatureHelp{
		signatures: [
			lsp.SignatureInformation{
				label: 'fn return_number(a int, b int) int'
				parameters: [
					lsp.ParameterInformation{'a int'},
					lsp.ParameterInformation{'b int'},
				]
			},
		]
		active_parameter: 1
	}
	'simple.vv':           lsp.SignatureHelp{
		signatures: [
			lsp.SignatureInformation{
				label: 'fn greet(name string) bool'
				parameters: [
					lsp.ParameterInformation{'name string'},
				]
			},
		]
		active_parameter: 0
	}
	'with_content.vv':     lsp.SignatureHelp{
		signatures: [
			lsp.SignatureInformation{
				label: 'fn greet(name string, age int) bool'
				parameters: [
					lsp.ParameterInformation{'name string'},
					lsp.ParameterInformation{'age int'},
				]
			},
		]
		active_parameter: 1
	}
	'with_content_b.vv':   lsp.SignatureHelp{
		signatures: [
			lsp.SignatureInformation{
				label: 'fn greet(name string, age int) bool'
				parameters: [
					lsp.ParameterInformation{'name string'},
					lsp.ParameterInformation{'age int'},
				]
			},
		]
		active_parameter: 0
	}
}

fn test_signature_help() {
	mut ls := server.new()
	mut t := &test_utils.Tester{
		test_files_dir: test_utils.get_test_files_path(@FILE)
		folder_name: 'signature_help'
		client: new_test_client(ls)
	}

	test_files := t.initialize()!
	for file in test_files {
		test_name := file.file_name
		err_msg := if test_name !in signature_help_results {
			'missing results'
		} else if test_name !in signature_help_inputs {
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

		// initiate signature_help request
		if actual := ls.signature_help(lsp.SignatureHelpParams{
			...signature_help_inputs[test_name]
			text_document: doc_id
		}, mut t.client.server.writer())
		{
			// compare content
			t.is_equal(signature_help_results[test_name], actual) or {
				t.fail(file, err.msg())
				continue
			}
			t.ok(file)
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
