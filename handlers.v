// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os

fn (mut app App) operation_at_pos(method Method, request Request) Response {
	line_nr := request.params.position.line + 1
	col := request.params.position.char
	path := request.params.text_document.uri
	line_info := match method {
		.completion, .hover {
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

fn (mut app App) on_did_open(request Request) {
	uri := request.params.text_document.uri
	log('on_did_open: ${uri}')
	real_path := uri_to_path(uri)
	content := os.read_file(real_path) or {
		log('Failed to read file ${real_path}: ${err}')
		return
	}
	app.open_files[uri] = content
	app.text = content
	log('STORED CONTENT for uri=${uri}, FILE COUNT: ${app.open_files.len}')
}

// Returns instant red wavy errors
fn (mut app App) on_did_change(request Request) ?Notification {
	log('on did change(len=${request.params.content_changes.len})')
	if request.params.content_changes.len == 0 || request.params.content_changes[0].text == '' {
		log('on_did_change() no params')
		return none
	}
	uri := request.params.text_document.uri
	content := request.params.content_changes[0].text
	app.text = content
	app.open_files[uri] = content // Update tracked file
	path := uri
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

fn (mut app App) find_references(request Request) Response {
	path := request.params.text_document.uri
	real_path := uri_to_path(path)
	line := request.params.position.line
	col := request.params.position.char

	// Get symbol name at cursor
	symbol := app.get_word_at_position(real_path, line, col)
	if symbol == '' {
		return Response{
			id:     request.id
			result: []Location{}
		}
	}

	// Search all .v files in working directory
	working_dir := os.dir(real_path)
	locations := app.search_symbol_in_project(working_dir, symbol)

	return Response{
		id:     request.id
		result: locations
	}
}

fn (mut app App) handle_rename(request Request) Response {
	path := request.params.text_document.uri
	real_path := uri_to_path(path)
	line := request.params.position.line
	col := request.params.position.char
	new_name := request.params.new_name

	// Get symbol name at cursor
	symbol := app.get_word_at_position(real_path, line, col)
	if symbol == '' {
		return Response{
			id:     request.id
			result: WorkspaceEdit{}
		}
	}

	// Find all references
	working_dir := os.dir(real_path)
	locations := app.search_symbol_in_project(working_dir, symbol)

	// Build WorkspaceEdit
	mut changes := map[string][]TextEdit{}
	for loc in locations {
		edit := TextEdit{
			range:    LSPRange{
				start: loc.range.start
				end:   Position{
					line: loc.range.start.line
					char: loc.range.start.char + symbol.len
				}
			}
			new_text: new_name
		}
		if loc.uri in changes {
			changes[loc.uri] << edit
		} else {
			changes[loc.uri] = [edit]
		}
	}

	return Response{
		id:     request.id
		result: WorkspaceEdit{
			changes: changes
		}
	}
}

fn (app &App) get_word_at_position(file_path string, line int, col int) string {
	content := app.open_files[path_to_uri(file_path)] or {
		os.read_file(file_path) or { return '' }
	}
	lines := content.split_into_lines()
	if line >= lines.len {
		return ''
	}

	text := lines[line]
	if col >= text.len {
		return ''
	}

	// Find word boundaries (V identifiers: letters, digits, underscores)
	mut start := col
	mut end := col
	for start > 0 && is_ident_char(text[start - 1]) {
		start--
	}
	for end < text.len && is_ident_char(text[end]) {
		end++
	}

	if start == end {
		return ''
	}
	return text[start..end]
}

fn is_ident_char(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_`
}

fn (mut app App) search_symbol_in_project(working_dir string, symbol string) []Location {
	mut locations := []Location{}
	v_files := os.walk_ext(working_dir, '.v')

	for v_file in v_files {
		content := app.open_files[path_to_uri(v_file)] or { os.read_file(v_file) or { continue } }
		lines := content.split_into_lines()

		for line_idx, line_text in lines {
			mut col := 0
			for col < line_text.len {
				idx := line_text[col..].index(symbol) or { break }
				pos := col + idx

				// Check it's a whole word (not part of larger identifier)
				before_ok := pos == 0 || !is_ident_char(line_text[pos - 1])
				after_ok := pos + symbol.len >= line_text.len
					|| !is_ident_char(line_text[pos + symbol.len])

				if before_ok && after_ok {
					locations << Location{
						uri:   path_to_uri(v_file)
						range: LSPRange{
							start: Position{
								line: line_idx
								char: pos
							}
							end:   Position{
								line: line_idx
								char: pos + symbol.len
							}
						}
					}
				}
				col = pos + 1
			}
		}
	}
	return locations
}
