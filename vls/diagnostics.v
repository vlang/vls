module vls

import lsp
import json
import jsonrpc
import v.token

fn position_to_range(source string, pos token.Position) lsp.Range {
	before := source[..pos.pos]
	mut end_pos := pos.pos + pos.len
	part := if source.len > end_pos {
		source[pos.pos..end_pos]
	} else {
		// eof error
		''
	}
	start_char := before.all_after_last('\n').len
	after_last_nl := part.all_after_last('\n')
	end_line := pos.line_nr + part.count('\n')
	mut end_char := after_last_nl.len
	if pos.line_nr == end_line {
		end_char += start_char
	}
	return  lsp.Range{
		start: lsp.Position{
			line: pos.line_nr
			character: start_char
		}
		end: lsp.Position{
			line: end_line
			character: end_char
		}
	}
}

// publish_diagnostics sends errors, warnings and other diagnostics to the editor
fn (ls Vls) publish_diagnostics(uri string, diagnostics []lsp.Diagnostic) {
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
