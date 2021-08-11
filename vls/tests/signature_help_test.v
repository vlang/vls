import vls
import vls.testing
import json
import lsp
import os

const signature_help_inputs = {
	'simple.vv': lsp.SignatureHelpParams{
		context: lsp.SignatureHelpContext{
			trigger_kind: .trigger_character
			trigger_character: '('
		}
		position: lsp.Position{7, 8}
	}
}

const signature_help_results = {
	'simple.vv': lsp.SignatureHelp{
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
}

fn test_signature_help() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	ls.dispatch(io.request_with_params('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path(os.dir(@FILE), 'test_files',
			'signature_help'))
	}))
	test_files := testing.load_test_file_paths('signature_help') or {
		io.bench.fail()
		eprintln(io.bench.step_message_fail(err.msg))
		assert false
		return
	}
	io.bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		io.bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in signature_help_results {
			'missing results for $test_name'
		} else if test_name !in signature_help_inputs {
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
		// initiate signature_help request
		ls.dispatch(io.request_with_params('textDocument/signatureHelp', lsp.SignatureHelpParams{
			...signature_help_inputs[test_name]
			text_document: doc_id
		}))
		// compare content
		println(io.bench.step_message('Testing $test_file_path'))
		assert io.result() == json.encode(signature_help_results[test_name])
		// Delete document
		ls.dispatch(io.close_document(doc_id))
		io.bench.ok()
		println(io.bench.step_message_ok(test_name))
	}
	assert io.bench.nfail == 0
	io.bench.stop()
}
