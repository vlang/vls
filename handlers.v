// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.

// `user. ...` fields and methods
fn (mut app App) completion(request Request) Response {
	log('completion')
	log('request=${request}')
	// app.text = request.params.content_changes[0].text
	path := request.params.text_document.uri
	line_nr := request.params.position.line + 1
	col := request.params.position.char
	var_ac := app.run_v_line_info(path, line_nr, col)
	log('var_ac=${var_ac}')
	mut details := []Detail{cap: 3}
	for field in var_ac.fields {
		if !field.contains(':') {
			continue
		}
		vals := field.split(':')
		field_name := vals[0]
		typ := vals[1]
		details << Detail{
			detail:        typ        // app.type_to_str(field.typ)
			kind:          .field     // Field
			label:         field_name // field.name
			documentation: 'MY DOCS'  // TODO fetch docs
		}
	}
	for method in var_ac.methods {
		if !method.contains(':') {
			continue
		}
		vals := method.split(':')
		method_name := vals[0]
		typ := vals[1]
		details << Detail{
			detail:        typ // app.type_to_str(field.typ)
			kind:          .method
			label:         method_name
			documentation: 'MY DOCS'
		}
	}
	resp := Response{
		id:     request.id
		result: details
	}
	return resp
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

// Autocomplete for `os.create(...`
// Function parameters, with currently typed parameter being highlighted
fn (mut app App) signature_help(request Request) Response {
	// For signature help, the file must be up-to-date.
	path := request.params.text_document.uri
	lines := app.text.split('\n')
	line_nr := request.params.position.line
	// char_pos := request.params.position.char
	if line_nr >= lines.len {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	line_text := lines[line_nr]
	log('SIG LINE TEXT=${line_text}')
	mut active_parameter := 0
	fn_sig := app.run_v_fn_sig(path, line_nr, line_text)
	mut param_infos := []ParameterInformation{}
	for _, param in fn_sig.params {
		param_infos << ParameterInformation{
			label: param
			//				label: '${param.name} ${app.type_to_str(param.typ)}'
		}
	}
	signature_info := SignatureInformation{
		// label:      'method(param1 param1.typ, param2 param2.typ)'// app.fn_to_str(method)
		label:      '${fn_sig.name}(${fn_sig.params.join(',')})'
		parameters: param_infos
	}
	signature_help := SignatureHelp{
		signatures:       [signature_info]
		active_signature: 0
		active_parameter: active_parameter
	}
	return Response{
		id:     request.id
		result: signature_help
	}
}

// Finds the word/expression at a given cursor position in the document.
fn (app &App) get_expression_at_cursor(line_nr int, col int) string {
	log('get_expression_at_cursor line_nr=${line_nr} col=${col}')
	lines := app.text.split('\n')
	if line_nr < 0 || line_nr >= lines.len {
		return ''
	}
	line := lines[line_nr].trim_space()
	log('EXPR LINE="${line}"')
	if col < 0 || col > line.len {
		return ''
	}
	mut start := col
	mut end := col
	// Find the start of the expression (scan backwards)
	// Stop before the start of the line or if the character is not part of an identifier.
	for start > 0 {
		c := line[start - 1]
		if c.is_letter() || c.is_digit() || c == `_` || c == `.` {
			start--
		} else {
			break
		}
	}
	// Find the end of the expression (scan forwards)
	// Stop at the end of the line or if the character is not part of an identifier.
	for end < line.len {
		c := line[end]
		if c.is_letter() || c.is_digit() || c == `_` || c == `.` {
			end++
		} else {
			break
		}
	}
	if start >= end {
		return ''
	}
	return line[start..end]
}

fn (mut app App) go_to_definition(request Request) Response {
	log('go_to_definition')
	path := request.params.text_document.uri
	// LSP line is 0-based, V compiler is 1-based
	line_nr_0based := request.params.position.line
	line_nr_1based := line_nr_0based + 1
	col := request.params.position.char
	// Get the expression under the cursor.
	expression := app.get_expression_at_cursor(line_nr_0based, col)
	log('found expression for definition: "${expression}"')
	if expression == '' {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	// Call the new interop function that uses the `gd^` prefix.
	location := app.run_v_go_to_definition(path, line_nr_1based, expression)
	log('location for definition=${location}')
	// Check if the V compiler provided a definition location
	if location.uri == '' {
		log('no definition info found from V compiler')
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	resp := Response{
		id:     request.id
		result: location
	}
	log('sending definition response: ${resp}')
	return resp
}
