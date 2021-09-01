module server

import jsonrpc
import lsp

// show_diagnostics converts the file ast's errors and warnings and publishes them to the editor
fn (mut ls Vls) show_diagnostics(uri lsp.DocumentUri) {
	// TODO: make reports as a map, do not clear it
	// use
	mut diagnostics := []lsp.Diagnostic{}
	fs_path := uri.path()

	for msg in ls.store.messages {
		if msg.file_path != fs_path {
			continue
		}

		kind := match msg.kind {
			.error { lsp.DiagnosticSeverity.error }
			.warning { lsp.DiagnosticSeverity.warning }
			.notice { lsp.DiagnosticSeverity.information }
		}

		diagnostics << lsp.Diagnostic{
			range: tsrange_to_lsp_range(msg.range)
			severity: kind
			message: msg.content
		}
	}

	ls.publish_diagnostics(uri, diagnostics)
}

// publish_diagnostics sends errors, warnings and other diagnostics to the editor
[manualfree]
fn (mut ls Vls) publish_diagnostics(uri lsp.DocumentUri, diagnostics []lsp.Diagnostic) {
	if Feature.diagnostics !in ls.enabled_features {
		return
	}

	ls.notify(jsonrpc.NotificationMessage<lsp.PublishDiagnosticsParams>{
		method: 'textDocument/publishDiagnostics'
		params: lsp.PublishDiagnosticsParams{
			uri: uri
			diagnostics: diagnostics
		}
	})
	unsafe { diagnostics.free() }
}
