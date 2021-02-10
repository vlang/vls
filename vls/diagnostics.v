module vls

import lsp
import jsonrpc

// show_diagnostics converts the file ast's errors and warnings and publishes them to the editor.
fn (ls Vls) show_diagnostics(uri lsp.DocumentUri) {
	file := ls.files[uri.str()]
	source := ls.sources[uri.str()]
	mut diagnostics := []lsp.Diagnostic{}
	for _, error in file.errors {
		diagnostics << lsp.Diagnostic{
			range: position_to_lsp_range(source, error.pos)
			severity: .error
			message: error.message
		}
	}
	for _, warning in file.warnings {
		diagnostics << lsp.Diagnostic{
			range: position_to_lsp_range(source, warning.pos)
			severity: .warning
			message: warning.message
		}
	}
	ls.publish_diagnostics(uri, diagnostics)
}

// publish_diagnostics sends errors, warnings and other diagnostics to the editor.
fn (ls Vls) publish_diagnostics(uri lsp.DocumentUri, diagnostics []lsp.Diagnostic) {
	if Feature.diagnostics !in ls.enabled_features {
		return
	}
	result := jsonrpc.NotificationMessage<lsp.PublishDiagnosticsParams>{
		method: 'textDocument/publishDiagnostics'
		params: lsp.PublishDiagnosticsParams{
			uri: uri
			diagnostics: diagnostics
		}
	}
	ls.send(result)
	unsafe { diagnostics.free() }
}
