import vls
import vls.testing

fn init() vls.Vls {
	mut io := testing.Testio{}
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	mut ls := vls.new(io)
	ls.dispatch(payload)
	return ls
}

fn test_wrong_first_request() {
	mut io := testing.Testio{}
	payload := '{"jsonrpc":"2.0","id":1,"method":"shutdown","params":{}}'
	mut ls := vls.new(io)
	ls.dispatch(payload)
	status := ls.status()
	assert status == .off
	assert io.response ==
		'{"jsonrpc":"2.0","id":0,"error":{"code":-32002,"message":"Server not yet initialized.","data":""},"result":""}'
}

fn test_initialize_with_capabilities() {
	mut io := testing.Testio{}
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	mut ls := vls.new(io)
	ls.dispatch(payload)
	status := ls.status()
	assert status == .initialized
	assert io.response ==
		'{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1,"hoverProvider":false,"completionProvider":{"resolveProvider":false,"triggerCharacters":["=",".",":","{",",","("," "]},"signatureHelpProvider":{"triggerCharacters":[],"retriggerCharacters":[]},"definitionProvider":false,"typeDefinitionProvider":false,"implementationProvider":false,"referencesProvider":false,"documentHightlightProvider":false,"documentSymbolProvider":true,"workspaceSymbolProvider":true,"codeActionProvider":false,"codeLensProvider":{"resolveProvider":false},"documentFormattingProvider":true,"documentOnTypeFormattingProvider":{"moreTriggerCharacter":[]},"renameProvider":false,"documentLinkProvider":false,"colorProvider":false,"declarationProvider":false,"executeCommandProvider":"","experimental":{}}}}'
}

fn test_initialized() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialized","params":{}}'
	mut ls := init()
	ls.dispatch(payload)
	status := ls.status()
	assert status == .initialized
}

// fn test_shutdown() {
// 	payload := '{"jsonrpc":"2.0","method":"shutdown","params":{}}'
// 	mut ls := init()
// 	ls.dispatch(payload)
// 	status := ls.status()
// 	assert status == .shutdown
// }

fn test_set_features() {
	mut io := testing.Testio{}
	mut ls := vls.new(io)
	assert ls.features() == vls.default_features_list
	ls.set_features(['formatting'], false)
	assert ls.features() == [.diagnostics, .document_symbol, .workspace_symbol, .completion, .signature_help]
	ls.set_features(['formatting'], true)
	assert ls.features() == [.diagnostics, .document_symbol, .workspace_symbol, .completion, .formatting, .signature_help]
	ls.set_features(['logging'], true) or {
		assert err == 'feature "logging" not found'
		return
	}
}