// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// handle_prepare_call_hierarchy handles textDocument/prepareCallHierarchy.
// It resolves the function or method at the given cursor position and returns
// a CallHierarchyItem that can be used for subsequent incoming/outgoing queries.
fn (mut app App) handle_prepare_call_hierarchy(request Request) Response {
	params := json2.decode[PrepareCallHierarchyParams](request.params) or {
		$if debug { log('Failed to decode PrepareCallHierarchyParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	lines := content.split_into_lines()
	if params.position.line < 0 || params.position.line >= lines.len {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	line_text := lines[params.position.line]
	start, end := find_word_bounds_at_col(line_text, params.position.char, app.position_encoding)
	if start < 0 || end <= start {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	word := substr_by_char_bounds(line_text, start, end, app.position_encoding)
	if word == '' {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	// Search the current file first, then the wider workspace.
	mut item := find_fn_in_content(word, content, uri, app.position_encoding)
	if item.name == '' {
		working_dir := os.dir(uri_to_path(uri))
		search_dirs := app.workspace_search_dirs(working_dir)
		item = app.find_fn_declaration(word, search_dirs, request.id)
	}
	if item.name == '' {
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	return Response{
		id:     request.id
		result: [item]
	}
}

// handle_call_hierarchy_incoming handles callHierarchy/incomingCalls.
// For each .v file reachable from the item's working directory it scans for
// calls to the queried function and groups them by the enclosing caller.
fn (mut app App) handle_call_hierarchy_incoming(request Request) Response {
	params := json2.decode[CallHierarchyIncomingCallsParams](request.params) or {
		$if debug { log('Failed to decode CallHierarchyIncomingCallsParams: ${err}') }
		return Response{
			id:     request.id
			result: []CallHierarchyIncomingCall{}
		}
	}
	fn_name := extract_simple_fn_name(params.item.name)
	if fn_name == '' {
		return Response{
			id:     request.id
			result: []CallHierarchyIncomingCall{}
		}
	}
	working_dir := os.dir(uri_to_path(params.item.uri))
	search_dirs := app.workspace_search_dirs(working_dir)
	mut results := []CallHierarchyIncomingCall{}
	mut processed := map[string]bool{}

	// Scan in-memory open files first.
	for uri, fc in app.open_files {
		if request.id in app.cancelled_requests {
			return Response{
				id:     request.id
				result: results
			}
		}
		if processed[uri] {
			continue
		}
		processed[uri] = true
		scan_for_callers(fn_name, uri, fc, app.position_encoding, mut results)
	}
	// Scan on-disk .v files in the working directory.
	for dir in search_dirs {
		if dir == '' || dir == '/' || !os.is_dir(dir) {
			continue
		}
		for f in os.walk_ext(dir, '.v') {
			if request.id in app.cancelled_requests {
				return Response{
					id:     request.id
					result: results
				}
			}
			if f.ends_with('_test.v') {
				continue
			}
			uri := path_to_uri(f)
			if processed[uri] {
				continue
			}
			processed[uri] = true
			fc := os.read_file(f) or { continue }
			scan_for_callers(fn_name, uri, fc, app.position_encoding, mut results)
		}
	}
	return Response{
		id:     request.id
		result: results
	}
}

// handle_call_hierarchy_outgoing handles callHierarchy/outgoingCalls.
// It identifies every function called within the body of the queried function.
fn (mut app App) handle_call_hierarchy_outgoing(request Request) Response {
	params := json2.decode[CallHierarchyOutgoingCallsParams](request.params) or {
		$if debug { log('Failed to decode CallHierarchyOutgoingCallsParams: ${err}') }
		return Response{
			id:     request.id
			result: []CallHierarchyOutgoingCall{}
		}
	}
	item := params.item
	uri := item.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	lines := content.split_into_lines()
	start_line := item.range.start.line
	end_line := find_fn_body_end(lines, start_line)

	// Collect all function-call names and their source ranges within the body.
	mut call_map := map[string][]LSPRange{}
	for li in start_line .. end_line + 1 {
		if li >= lines.len {
			break
		}
		find_fn_calls_in_line(lines[li], li, app.position_encoding, mut call_map)
	}

	working_dir := os.dir(uri_to_path(uri))
	search_dirs := app.workspace_search_dirs(working_dir)
	self_name := extract_simple_fn_name(item.name)
	mut results := []CallHierarchyOutgoingCall{}
	for called_name, call_ranges in call_map {
		if called_name in v_keywords {
			continue
		}
		if called_name == self_name {
			continue // skip direct recursion
		}
		callee := app.find_fn_declaration(called_name, search_dirs, request.id)
		if callee.name == '' {
			continue
		}
		results << CallHierarchyOutgoingCall{
			to:          callee
			from_ranges: call_ranges
		}
	}
	return Response{
		id:     request.id
		result: results
	}
}

// ── Helpers ──────────────────────────────────────────────────────────────────

// extract_simple_fn_name removes the optional receiver from a method name,
// e.g. "(mut App) foo" → "foo", "foo" → "foo".
fn extract_simple_fn_name(full_name string) string {
	trimmed := full_name.trim_space()
	if trimmed.starts_with('(') {
		close := trimmed.index(')') or { return '' }
		return trimmed[close + 1..].trim_space()
	}
	return trimmed
}

// find_fn_in_content searches `content` for a function/method whose simple
// (bare) name equals `fn_name` and returns a CallHierarchyItem on success.
fn find_fn_in_content(fn_name string, content string, uri string, enc PositionEncoding) CallHierarchyItem {
	syms :=
		encode_document_symbols(parse_document_symbols(content), content.split_into_lines(), enc)
	for sym in syms {
		if sym.kind != sym_kind_function && sym.kind != sym_kind_method {
			continue
		}
		if extract_simple_fn_name(sym.name) == fn_name {
			return CallHierarchyItem{
				name:            sym.name
				kind:            sym.kind
				uri:             uri
				range:           sym.range
				selection_range: sym.selection_range
			}
		}
	}
	return CallHierarchyItem{}
}

// find_fn_declaration searches open files and then on-disk files in
// `search_dirs` for a function/method named `fn_name`. Polls for cancellation
// between files so callers can return early when the request is cancelled.
fn (mut app App) find_fn_declaration(fn_name string, search_dirs []string, request_id int) CallHierarchyItem {
	// Answer from the persistent symbol index instead of re-scanning every file.
	app.ensure_dirs_indexed(search_dirs)
	if uri, sym := app.find_indexed_fn(fn_name) {
		return CallHierarchyItem{
			name:            sym.name
			kind:            sym.kind
			uri:             uri
			range:           sym.range
			selection_range: sym.selection_range
		}
	}
	return CallHierarchyItem{}
}

// scan_for_callers scans `file_content` for calls to `fn_name` and, for each
// call site, appends a CallHierarchyIncomingCall entry to `results` keyed by
// the enclosing function symbol (nearest preceding function declaration).
// String literals and line comments are skipped to avoid false positives.
fn scan_for_callers(fn_name string, file_uri string, file_content string, enc PositionEncoding, mut results []CallHierarchyIncomingCall) {
	file_lines := file_content.split_into_lines()
	syms := encode_document_symbols(parse_document_symbols(file_content), file_lines, enc)

	// For each function symbol, scan its body for calls to fn_name.
	for sym in syms {
		if sym.kind != sym_kind_function && sym.kind != sym_kind_method {
			continue
		}
		body_end := find_fn_body_end(file_lines, sym.range.start.line)
		mut call_ranges := []LSPRange{}
		for li in sym.range.start.line .. body_end + 1 {
			if li >= file_lines.len {
				break
			}
			line := file_lines[li]
			n := line.len
			mut col := 0
			for col < n {
				ch := line[col]
				// Skip line comments.
				if col + 1 < n && ch == `/` && line[col + 1] == `/` {
					break
				}
				// Skip string literals (single and double quoted).
				if ch == `"` || ch == `'` {
					quote := ch
					col++
					for col < n {
						if line[col] == `\\` {
							col += 2
							continue
						}
						if line[col] == quote {
							col++
							break
						}
						col++
					}
					continue
				}
				idx := line[col..].index('${fn_name}(') or { break }
				abs := col + idx
				// Require a word boundary before the name.
				if abs > 0 && is_ident_char(line[abs - 1]) {
					col = abs + 1
					continue
				}
				start_char := byte_to_encoded_col(line, abs, enc)
				end_char := byte_to_encoded_col(line, abs + fn_name.len, enc)
				call_ranges << LSPRange{
					start: Position{
						line: li
						char: start_char
					}
					end:   Position{
						line: li
						char: end_char
					}
				}
				col = abs + fn_name.len + 1
			}
		}
		if call_ranges.len > 0 {
			results << CallHierarchyIncomingCall{
				from:        CallHierarchyItem{
					name:            sym.name
					kind:            sym.kind
					uri:             file_uri
					range:           sym.range
					selection_range: sym.selection_range
				}
				from_ranges: call_ranges
			}
		}
	}
}

// find_fn_calls_in_line scans a single source line for `identifier(` patterns
// and adds them to `call_map` keyed by the unqualified callee name.
fn find_fn_calls_in_line(line string, line_idx int, enc PositionEncoding, mut call_map map[string][]LSPRange) {
	n := line.len
	mut col := 0
	for col < n {
		c := line[col]
		// Skip string literals.
		if c == `"` || c == `'` {
			quote := c
			col++
			for col < n {
				if line[col] == `\\` {
					col += 2
					continue
				}
				if line[col] == quote {
					col++
					break
				}
				col++
			}
			continue
		}
		// Skip line comments.
		if col + 1 < n && c == `/` && line[col + 1] == `/` {
			break
		}
		// Scan identifier (may be qualified: mod.fn or recv.method).
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_` {
			start := col
			for col < n {
				ch := line[col]
				if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
					|| (ch >= `0` && ch <= `9`) || ch == `_` || ch == `.` {
					col++
				} else {
					break
				}
			}
			if col < n && line[col] == `(` {
				word := line[start..col]
				parts := word.split('.')
				simple := parts.last()
				if simple.len > 0 && simple !in v_keywords {
					start_char := byte_to_encoded_col(line, start, enc)
					end_char := byte_to_encoded_col(line, col, enc)
					cr := LSPRange{
						start: Position{
							line: line_idx
							char: start_char
						}
						end:   Position{
							line: line_idx
							char: end_char
						}
					}
					if simple !in call_map {
						call_map[simple] = []LSPRange{}
					}
					call_map[simple] << cr
				}
			}
			continue
		}
		col++
	}
}
