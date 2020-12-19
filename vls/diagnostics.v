module vls

import lsp
import json
import jsonrpc
import v.token
import v.util

// get_column computes the column of the source based on the given initial position
fn get_column(source string, init_pos int) int {
	mut p := init_pos
	if source.len > 0 {
		for ; p >= 0; p-- {
			if source[p] == `\r` || source[p] == `\n` {
				break
			}
		}
	}
	return p - 1
}

// position_to_lsp_pos converts the token.Position into lsp.Position
pub fn position_to_lsp_pos(source string, pos token.Position) lsp.Position {
	p := util.imax(0, util.imin(source.len - 1, pos.pos))
	column := util.imax(0, pos.pos - get_column(source, p)) - 1
	return lsp.Position{
		line: pos.line_nr
		character: util.imax(1, column) - 1
	}
}

// position_to_lsp_pos converts the token.Position into lsp.Range
fn position_to_lsp_range(source string, pos token.Position) lsp.Range {
	start_pos := position_to_lsp_pos(source, pos)
	return lsp.Range{
		start: start_pos
		end: {
			start_pos |
			character: start_pos.character + pos.len
		}
	}
}

// show_diagnostics converts the file ast's errors and warnings and publishes them to the editor
fn (ls Vls) show_diagnostics(source string, uri lsp.DocumentUri) {
	mut diagnostics := []lsp.Diagnostic{}
	file := ls.files[uri.str()]
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
	unsafe {
		diagnostics.free()
	}
}
