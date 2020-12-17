module vls

import lsp
import json
import jsonrpc

// publish_diagnostics sends errors, warnings and other diagnostics to the editor
fn (ls Vls) publish_diagnostics(uri lsp.DocumentUri, diagnostics []lsp.Diagnostic) {
	result := jsonrpc.NotificationMessage<lsp.PublishDiagnosticsParams>{
		method: 'textDocument/publishDiagnostics'
		params: lsp.PublishDiagnosticsParams{
			uri: uri
			diagnostics: diagnostics
		}
	}
	str := json.encode(result)
	ls.send(str)
}
