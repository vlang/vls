// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// DocumentHighlightKind values (LSP §3.17): 1 = Text, 2 = Read, 3 = Write.
const doc_highlight_read = 2
const doc_highlight_write = 3

// classify_highlight_kind classifies an identifier occurrence ending at byte
// offset `end_byte` on `line` as a Write (assignment target) or a Read, based on
// the operator that immediately follows it. This is a syntactic heuristic
// (P2-03): `name :=` / `name =` / `name op=` are writes; comparisons and
// everything else are reads.
fn classify_highlight_kind(line string, end_byte int) int {
	mut i := end_byte
	for i < line.len && (line[i] == ` ` || line[i] == `\t`) {
		i++
	}
	if i >= line.len {
		return doc_highlight_read
	}
	rest := line[i..]
	if rest.starts_with(':=') {
		return doc_highlight_write
	}
	// Distinguish assignment `=` from comparison `==`/`=>`.
	if rest.starts_with('==') || rest.starts_with('=>') {
		return doc_highlight_read
	}
	if rest.starts_with('=') {
		return doc_highlight_write
	}
	// Compound assignment: += -= *= /= %= &= |= ^= (op followed by '=', not '==').
	if rest.len >= 2 && rest[1] == `=` && (rest.len < 3 || rest[2] != `=`)
		&& rest[0] in [`+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`] {
		return doc_highlight_write
	}
	return doc_highlight_read
}

// handle_document_highlight handles textDocument/documentHighlight.
// It finds all occurrences of the identifier under the cursor within the current
// document and returns them as a DocumentHighlight list.
fn (mut app App) handle_document_highlight(request Request) Response {
	params := json2.decode[DocumentHighlightParams](request.params) or {
		$if debug { log('Failed to decode DocumentHighlightParams: ${err}') }
		return Response{
			id:     request.id
			result: []DocumentHighlight{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	if content == '' {
		return Response{
			id:     request.id
			result: []DocumentHighlight{}
		}
	}
	lines := content.split_into_lines()
	if params.position.line < 0 || params.position.line >= lines.len {
		return Response{
			id:     request.id
			result: []DocumentHighlight{}
		}
	}
	line_text := lines[params.position.line]
	start, end := find_word_bounds_at_col(line_text, params.position.char, app.position_encoding)
	if start < 0 || end <= start {
		return Response{
			id:     request.id
			result: []DocumentHighlight{}
		}
	}
	symbol := substr_by_char_bounds(line_text, start, end, app.position_encoding)
	if symbol == '' {
		return Response{
			id:     request.id
			result: []DocumentHighlight{}
		}
	}
	anchor := app.resolve_symbol_anchor(uri, params.position.line, start)
	mut anchor_cache := map[string]?Location{}
	mut highlights := []DocumentHighlight{}
	for line_idx, line in lines {
		if !line.contains(symbol) {
			continue
		}
		n := line.len
		mut col := 0
		for col < n {
			c := line[col]
			// Skip line comments.
			if col + 1 < n && c == `/` && line[col + 1] == `/` {
				break
			}
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
			if is_ident_char(c) {
				start_byte := col
				col++
				for col < n && is_ident_char(line[col]) {
					col++
				}
				if line[start_byte..col] == symbol {
					start_char := byte_to_encoded_col(line, start_byte, app.position_encoding)
					end_char := byte_to_encoded_col(line, col, app.position_encoding)
					if a := anchor {
						if resolved := app.resolve_symbol_anchor_cached(uri, line_idx, start_char, mut
							anchor_cache)
						{
							if !same_anchor_location(resolved, a) {
								continue
							}
						} else {
							continue
						}
					}
					highlights << DocumentHighlight{
						range: LSPRange{
							start: Position{
								line: line_idx
								char: start_char
							}
							end:   Position{
								line: line_idx
								char: end_char
							}
						}
						kind:  classify_highlight_kind(line, col) // Read/Write (P2-03)
					}
				}
				continue
			}
			col++
		}
	}
	return Response{
		id:     request.id
		result: highlights
	}
}
