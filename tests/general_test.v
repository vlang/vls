import vls

fn test_wrong_first_request() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"shutdown","params":{}}'
	mut ls := vls.Vls{}
	res := ls.execute(payload)
	assert res == '{"jsonrpc":"2.0","id":0,"error":{"code":-32002,"message":"Server not yet initialized.","data":""},"result":""}'
	status := ls.status
	assert status == .off
}

fn test_initialize_with_capabilities() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	mut ls := vls.Vls{}
	res := ls.execute(payload)
	assert res == '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1,"hoverProvider":false,"completionProvider":{"resolveProvider":false,"triggerCharacters":[]},"signatureHelpProvider":{"triggerCharacters":[],"retriggerCharacters":[]},"definitionProvider":false,"typeDefinitionProvider":false,"implementationProvider":false,"referencesProvider":false,"documentHightlightProvider":false,"documentSymbolProvider":true,"workspaceSymbolProvider":true,"codeActionProvider":false,"codeLensProvider":{"resolveProvider":false},"documentFormattingProvider":false,"documentOnTypeFormattingProvider":{"moreTriggerCharacter":[]},"renameProvider":false,"documentLinkProvider":false,"colorProvider":false,"declarationProvider":false,"executeCommandProvider":"","experimental":{}}}}'
	status := ls.status
	assert status == .initialized
}

fn test_initialized() {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialized","params":{}}'
	mut ls := init()
	ls.execute(payload)
	status := ls.status
	assert status == .initialized
}

fn test_shutdown() {
	payload := '{"jsonrpc":"2.0","method":"shutdown","params":{}}'
	mut ls := init()
	ls.execute(payload)
	status := ls.status
	assert status == .shutdown
}

fn init() vls.Vls {
	payload := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	mut ls := vls.Vls{}
	ls.execute(payload)
	return ls
}
