import vls
import vls.testing
import lsp
import json
import jsonrpc
import os

const (
	root_path_uri = lsp.document_uri_from_path(os.resource_abs_path('files'))
)

fn test_document_symbol() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"root_path":"$root_path_uri"}}'
	ls.execute(payload)
	assert ls.status() == .initialized

	document_path := os.join_path(root_path_uri.path(), 'symbol_test_sample.v')
	println(document_path)

	document_src := os.read_file(document_path) or { '' }
	document_uri := lsp.document_uri_from_path(document_path)
	assert document_src.len > 0

	// open first the file
	ls.execute(json.encode(jsonrpc.TestRequest<lsp.DidOpenTextDocumentParams>{
		id: 2
		method: 'textDocument/didOpen'
		params: lsp.DidOpenTextDocumentParams{
			text_document: lsp.TextDocumentItem{
				uri: document_uri
				language_id: "v"
				version: 1
				text: document_src
			}
		}
	}))

	// execute document symbol feature
	ls.execute(json.encode(jsonrpc.TestRequest<lsp.DocumentSymbolParams>{
		id: 3
		method: 'textDocument/documentSymbol'
		params: lsp.DocumentSymbolParams{
			text_document: lsp.TextDocumentIdentifier{
				uri: document_uri
			}
		}
	}))

// TODO: positioning
	expected := json.encode(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: 3
		result: [
			lsp.SymbolInformation{
				name: 'Baz'
				kind: .type_parameter
			}
			lsp.SymbolInformation{
				name: 'Bar'
				kind: .type_parameter
			}
			lsp.SymbolInformation{
				name: 'num'
				kind: .constant
			}
			lsp.SymbolInformation{
				name: 'Speaker'
				kind: .interface_
			}
			lsp.SymbolInformation{
				name: 'Color'
				kind: .enum_
			}
			lsp.SymbolInformation{
				name: 'Foo'
				kind: .struct_
			}
			lsp.SymbolInformation{
				name: 'Foo.speak'
				kind: .method
			}
			lsp.SymbolInformation{
				name: 'main'
				kind: .function
			}
		]
	})

	println(io.response)

	assert io.response == expected
}