import vls

fn test_wrong_first_request() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"shutdown","params":{}}'
	mut ls := vls.Vls{ test_mode: true }
	ls.execute(payload)
	assert ls.response == '{"jsonrpc":"2.0","id":0,"error":{"code":-32002,"message":"Server not yet initialized.","data":""},"result":""}'
	assert ls.status() == .off
}

fn test_initialize_with_capabilities() {
	mut ls := init()
	assert ls.response == '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1,"hoverProvider":false,"completionProvider":{"resolveProvider":false,"triggerCharacters":[]},"signatureHelpProvider":{"triggerCharacters":[],"retriggerCharacters":[]},"definitionProvider":false,"typeDefinitionProvider":false,"implementationProvider":false,"referencesProvider":false,"documentHightlightProvider":false,"documentSymbolProvider":true,"workspaceSymbolProvider":true,"codeActionProvider":false,"codeLensProvider":{"resolveProvider":false},"documentFormattingProvider":false,"documentOnTypeFormattingProvider":{"moreTriggerCharacter":[]},"renameProvider":false,"documentLinkProvider":false,"colorProvider":false,"declarationProvider":false,"executeCommandProvider":"","experimental":{}}}}'
	assert ls.status() == .initialized
}

fn test_initialized() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialized","params":{}}'
	mut ls := init()
	ls.execute(payload)
	assert ls.status() == .initialized
}

fn test_shutdown() {
	payload := '{"jsonrpc":"2.0","method":"shutdown","params":{}}'
	mut ls := init()
	ls.execute(payload)
	assert ls.status() == .shutdown
}

fn init() vls.Vls {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	mut ls := vls.Vls{ test_mode: true }
	ls.execute(payload)
	return ls
}
