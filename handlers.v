// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.

fn (mut app App) operation_at_pos(method Method, request Request) Response {
	line_nr := request.params.position.line
	col := request.params.position.char
	path := request.params.text_document.uri
	line_info := match method {
		.completion {
			'${line_nr}:${col}'
		}
		.signature_help {
			'${line_nr}:fn^${col}'
		}
		.definition {
			'${line_nr}:gd^${col}'
		}
		else {
			''
		}
	}
	result := app.run_v_line_info(method, path, line_info)
	log(result.str())
	return Response{
		id:     request.id
		result: result
	}
}

// Returns instant red wavy errors
fn (mut app App) on_did_change(request Request) ?Notification {
	log('on did change(len=${request.params.content_changes.len})')
	if request.params.content_changes.len == 0 || request.params.content_changes[0].text == '' {
		log('on_did_change() no params')
		return none
	}
	app.text = request.params.content_changes[0].text
	path := request.params.text_document.uri
	v_errors := app.run_v_check(path, app.text)
	log('run_v_check errors:${v_errors}')
	mut diagnostics := []LSPDiagnostic{}
	mut seen_positions := map[string]bool{}
	for v_err in v_errors {
		pos_key := '${v_err.line_nr}:${v_err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		diagnostics << v_error_to_lsp_diagnostic(v_err)
	}
	params := PublishDiagnosticsParams{
		uri:         request.params.text_document.uri
		diagnostics: diagnostics
	}
	notification := Notification{
		method: 'textDocument/publishDiagnostics'
		params: params
	}
	log('returning notification: ${notification}')
	return notification
}
