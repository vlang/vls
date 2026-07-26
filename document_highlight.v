// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// DocumentHighlightKind values (LSP §3.17): 1 = Text, 2 = Read, 3 = Write.
const doc_highlight_read = 2
const doc_highlight_write = 3

// Each semantic highlight candidate requires a serial compiler definition
// lookup. Above this bound, return no highlights rather than conflate symbols
// with the same spelling from different scopes.
const document_highlight_semantic_max_candidates = 48

struct DocumentHighlightCandidate {
	line_idx   int
	start_byte int
	end_byte   int
}

// highlight_has_word reports whether `text` contains `word` at identifier
// boundaries.
fn highlight_has_word(text string, word string) bool {
	if word == '' || text.len < word.len {
		return false
	}
	for i := 0; i + word.len <= text.len; i++ {
		if text[i..i + word.len] != word {
			continue
		}
		left_ok := i == 0 || !is_ident_char(text[i - 1])
		right_ok := i + word.len == text.len || !is_ident_char(text[i + word.len])
		if left_ok && right_ok {
			return true
		}
	}
	return false
}

// is_for_binding_highlight reports whether the occurrence is on the binding
// side of `for name in values` (including `for key, value in map`).
fn is_for_binding_highlight(line string, start_byte int, end_byte int) bool {
	prefix := line[..start_byte]
	mut for_byte := -1
	for i := 0; i + 3 <= prefix.len; i++ {
		if prefix[i..i + 3] != 'for' {
			continue
		}
		left_ok := i == 0 || !is_ident_char(prefix[i - 1])
		right_ok := i + 3 == prefix.len || !is_ident_char(prefix[i + 3])
		if left_ok && right_ok {
			for_byte = i
		}
	}
	if for_byte < 0 {
		return false
	}
	binding_prefix := prefix[for_byte + 3..]
	if binding_prefix.contains('{') || binding_prefix.contains(';')
		|| highlight_has_word(binding_prefix, 'in') {
		return false
	}
	mut binding_suffix := line[end_byte..]
	brace_byte := binding_suffix.index_any('{;')
	if brace_byte >= 0 {
		binding_suffix = binding_suffix[..brace_byte]
	}
	return highlight_has_word(binding_suffix, 'in')
}

// is_fn_parameter_highlight reports whether an occurrence is a receiver or
// parameter name in a function signature and is followed by its type.
fn is_fn_parameter_highlight(line string, start_byte int, end_byte int) bool {
	mut type_byte := end_byte
	for type_byte < line.len && (line[type_byte] == ` ` || line[type_byte] == `\t`) {
		type_byte++
	}
	if type_byte == end_byte || type_byte >= line.len {
		return false
	}
	type_start := line[type_byte]
	if !is_ident_char(type_start) && type_start !in [`[`, `?`, `&`, `.`] {
		return false
	}

	prefix := line[..start_byte]
	mut fn_byte := -1
	for i := 0; i + 2 <= prefix.len; i++ {
		if prefix[i..i + 2] != 'fn' {
			continue
		}
		left_ok := i == 0 || !is_ident_char(prefix[i - 1])
		right_ok := i + 2 == prefix.len || !is_ident_char(prefix[i + 2])
		if left_ok && right_ok {
			fn_byte = i
		}
	}
	if fn_byte < 0 {
		return false
	}
	mut paren_depth := 0
	for i := fn_byte + 2; i < prefix.len; i++ {
		if prefix[i] == `(` {
			paren_depth++
		} else if prefix[i] == `)` {
			paren_depth--
		}
	}
	return paren_depth > 0
}

// classify_highlight_kind classifies an identifier occurrence between byte
// offsets `start_byte` and `end_byte` on `line` as a Write or a Read. This is a
// syntactic heuristic (P2-03): declarations, assignments (including shifts),
// and `name++`/`name--` are writes; comparisons and other uses are reads.
fn classify_highlight_kind(line string, start_byte int, end_byte int) int {
	if is_for_binding_highlight(line, start_byte, end_byte)
		|| is_fn_parameter_highlight(line, start_byte, end_byte) {
		return doc_highlight_write
	}
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
	if rest.starts_with('++') || rest.starts_with('--') {
		return doc_highlight_write
	}
	if rest.starts_with('<<=') || rest.starts_with('>>=') {
		return doc_highlight_write
	}
	// Compound assignment: += -= *= /= %= &= |= ^= (op followed by '=', not '==').
	if rest.len >= 2 && rest[1] == `=` && (rest.len < 3 || rest[2] != `=`)
		&& rest[0] in [`+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`] {
		return doc_highlight_write
	}
	return doc_highlight_read
}

// collect_document_highlight_candidates finds exact identifier occurrences
// while excluding line comments and string literals.
fn collect_document_highlight_candidates(lines []string, symbol string) []DocumentHighlightCandidate {
	mut candidates := []DocumentHighlightCandidate{}
	for line_idx, line in lines {
		if !line.contains(symbol) {
			continue
		}
		n := line.len
		mut col := 0
		for col < n {
			c := line[col]
			if col + 1 < n && c == `/` && line[col + 1] == `/` {
				break
			}
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
					candidates << DocumentHighlightCandidate{
						line_idx:   line_idx
						start_byte: start_byte
						end_byte:   col
					}
				}
				continue
			}
			col++
		}
	}
	return candidates
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
	candidates := collect_document_highlight_candidates(lines, symbol)
	if candidates.len > document_highlight_semantic_max_candidates {
		return Response{
			id:     request.id
			result: []DocumentHighlight{}
		}
	}
	anchor := app.resolve_symbol_anchor(uri, params.position.line, start)
	mut anchor_cache := map[string]?Location{}
	if a := anchor {
		// The initial lookup already resolved the selected occurrence.
		anchor_cache[anchor_cache_key(uri, params.position.line, start)] = a
	}
	mut highlights := []DocumentHighlight{cap: candidates.len}
	for candidate in candidates {
		line := lines[candidate.line_idx]
		start_char := byte_to_encoded_col(line, candidate.start_byte, app.position_encoding)
		end_char := byte_to_encoded_col(line, candidate.end_byte, app.position_encoding)
		if a := anchor {
			if resolved := app.resolve_symbol_anchor_cached(uri, candidate.line_idx, start_char, mut
				anchor_cache)
			{
				if !same_anchor_location(resolved, a) {
					continue
				}
			} else {
				continue
			}
		}
		mut kind := classify_highlight_kind(line, candidate.start_byte, candidate.end_byte)
		if a := anchor {
			occurrence := Location{
				uri:   uri
				range: LSPRange{
					start: Position{
						line: candidate.line_idx
						char: start_char
					}
				}
			}
			if same_anchor_location(occurrence, a) {
				kind = doc_highlight_write
			}
		}
		highlights << DocumentHighlight{
			range: LSPRange{
				start: Position{
					line: candidate.line_idx
					char: start_char
				}
				end:   Position{
					line: candidate.line_idx
					char: end_char
				}
			}
			kind:  kind // Read/Write (P2-03)
		}
	}
	return Response{
		id:     request.id
		result: highlights
	}
}
