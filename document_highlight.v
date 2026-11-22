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
	mut binding_suffix := line[end_byte..].clone()
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

// collect_document_highlight_candidates reuses the reference tokenizer so
// comments, literal text, and executable string interpolations are treated
// consistently by highlighting and rename.
fn collect_document_highlight_candidates(content string, lines []string, symbol string, enc PositionEncoding) []DocumentHighlightCandidate {
	occurrences := extract_identifier_occurrences(content, enc)
	positions := occurrences[symbol] or { return []DocumentHighlightCandidate{} }
	mut candidates := []DocumentHighlightCandidate{cap: positions.len}
	for position in positions {
		if position.line < 0 || position.line >= lines.len {
			continue
		}
		line := lines[position.line]
		candidates << DocumentHighlightCandidate{
			line_idx:   position.line
			start_byte: encoded_col_to_byte(line, position.start_char, enc)
			end_byte:   encoded_col_to_byte(line, position.end_char, enc)
		}
	}
	return candidates
}

// handle_document_highlight handles textDocument/documentHighlight.
// It finds all occurrences of the identifier under the cursor within the current
// document and returns them as a DocumentHighlight list.
fn (mut app App) handle_document_highlight(request Request) Response {
	params := json2.decode[DocumentHighlightParams](request.params) or {
		$if debug {
			log('Failed to decode DocumentHighlightParams: ${err}')
		}
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
	candidates := collect_document_highlight_candidates(content, lines, symbol, app.position_encoding)
	if candidates.len > document_highlight_semantic_max_candidates {
		return Response{
			id:     request.id
			result: []DocumentHighlight{}
		}
	}
	cursor_pos := Position{
		line: params.position.line
		char: start
	}
	// Prefer the index for the anchor: a top-level symbol resolves without
	// spawning the compiler. Locals and unresolvable symbols keep the single
	// compiler lookup for the anchor; candidates are then decided below.
	index_anchor := app.resolve_indexed_definition(uri, cursor_pos)
	mut anchor := index_anchor
	if anchor == none {
		anchor = app.resolve_symbol_anchor(uri, params.position.line, start)
	}
	had_index_anchor := index_anchor != none
	cursor_start_byte := encoded_col_to_byte(line_text, start, app.position_encoding)
	cursor_end_byte := encoded_col_to_byte(line_text, end, app.position_encoding)
	_, cursor_has_member, _ := member_qualifier_at_cursor(line_text, end, app.position_encoding)
	mut cursor_keys := map[string]int{}
	for b in app.local_scope_bindings(content, cursor_pos) {
		if b.name == symbol {
			cursor_keys[highlight_binding_key(b.name, b.line, b.column)] = b.line
		}
	}
	cursor_is_decl := source_occurrence_precedes_local_declaration(lines, params.position.line, cursor_end_byte)
		|| is_fn_parameter_highlight(line_text, cursor_start_byte, cursor_end_byte)
	mut anchor_cache := map[string]?Location{}
	if a := anchor {
		// The initial lookup already resolved the selected occurrence.
		anchor_cache[anchor_cache_key(uri, params.position.line, start)] = a
	}
	// Classify first: only the candidates whose scope the lexical fast path
	// cannot decide are worth a batched V3 query.
	mut fast_decisions := map[string]?bool{}
	mut ambiguous := []Location{cap: candidates.len}
	for candidate in candidates {
		line := lines[candidate.line_idx]
		start_char := byte_to_encoded_col(line, candidate.start_byte, app.position_encoding)
		end_char := byte_to_encoded_col(line, candidate.end_byte, app.position_encoding)
		if accept := app.highlight_candidate_fast(content, lines, symbol, params.position.line, cursor_start_byte, cursor_keys, cursor_has_member, cursor_is_decl, had_index_anchor, candidate.line_idx, start_char, end_char, line, candidate.start_byte, candidate.end_byte) {
			fast_decisions[anchor_cache_key(uri, candidate.line_idx, start_char)] = accept
		} else {
			ambiguous << Location{
				uri:   uri
				range: LSPRange{
					start: Position{
						line: candidate.line_idx
						char: start_char
					}
					end:   Position{
						line: candidate.line_idx
						char: start_char
					}
				}
			}
		}
	}
	if anchor != none {
		app.v3_prefetch_anchors(ambiguous, mut anchor_cache)
	}
	mut highlights := []DocumentHighlight{cap: candidates.len}
	for candidate in candidates {
		line := lines[candidate.line_idx]
		start_char := byte_to_encoded_col(line, candidate.start_byte, app.position_encoding)
		end_char := byte_to_encoded_col(line, candidate.end_byte, app.position_encoding)
		if decided := fast_decisions[anchor_cache_key(uri, candidate.line_idx, start_char)] {
			if !decided {
				continue
			}
		} else if a := anchor {
			if resolved := app.resolve_symbol_anchor_cached(uri, candidate.line_idx, start_char, mut anchor_cache) {
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

// highlight_binding_key identifies one local binding for highlight comparison.
fn highlight_binding_key(name string, line int, column int) string {
	return '${name}:${line}:${column}'
}

// binding_key_line_col splits a highlight_binding_key back into the
// declaration line and column it identifies. Parameter bindings record an
// unknown column (-1); visible_binding_matches treats that as a wildcard.
fn binding_key_line_col(key string) (int, int) {
	column := key.all_after_last(':').int()
	line := key.all_before_last(':').all_after_last(':').int()
	return line, column
}

// visible_binding_matches reports whether (line, column) identifies the
// innermost same-named binding in `keys`: present and textually last, since an
// inner scope shadows an outer one — including two declarations sharing one
// line. A stored column of -1 (parameters, whose headers record no column)
// matches any column on the same line, so parameter fast paths keep working.
fn visible_binding_matches(keys map[string]int, line int, column int) bool {
	mut best_line := -1
	mut best_column := -2
	for key, _ in keys {
		key_line, key_column := binding_key_line_col(key)
		if key_line > best_line || (key_line == best_line && key_column > best_column) {
			best_line = key_line
			best_column = key_column
		}
	}
	if best_line != line {
		return false
	}
	return best_column == column || best_column < 0 || column < 0
}

// highlight_candidate_is_top_level reports whether a lexical candidate can be
// accepted as the same top-level symbol without compiler verification. Every
// syntactic position that could hide a different same-spelled symbol (locals,
// members, parameters, generics, compile-time code) returns false so the
// caller keeps the precise compiler check for exactly those.
fn highlight_candidate_is_top_level(lines []string, line_text string, line_idx int, start_byte int, end_byte int) bool {
	if source_line_is_module_or_import_declaration(lines, line_idx) {
		return false
	}
	if is_for_binding_highlight(line_text, start_byte, end_byte) {
		return false
	}
	if source_occurrence_is_for_binding(lines, line_idx, start_byte, end_byte) {
		return false
	}
	if source_occurrence_precedes_local_declaration(lines, line_idx, end_byte) {
		return false
	}
	if source_occurrence_is_generic_parameter(lines, line_idx, start_byte, end_byte) {
		return false
	}
	if source_occurrence_has_type_suffix(lines, line_idx, end_byte) {
		return false
	}
	if is_fn_parameter_highlight(line_text, start_byte, end_byte) {
		return false
	}
	if source_occurrence_is_method_declaration(lines, line_idx, start_byte) {
		return false
	}
	if source_occurrence_has_dot_suffix(line_text, end_byte) {
		return false
	}
	trimmed := line_text.trim_space()
	if trimmed.starts_with('#') || trimmed.starts_with('$') {
		return false
	}
	return true
}

// highlight_candidate_fast decides one highlight candidate without spawning
// the compiler: true accepts it, false rejects it, none defers to the
// existing compiler verification. Identity is the set of visible same-named
// local bindings; equal sets of uses mean the same declaration is referenced.
// A side sitting on the binding's own declaration matches by (line, column)
// identity instead: a line alone cannot tell same-line shadowing declarations
// apart. Bare top-level uses additionally require an index anchor and a
// top-level-safe position.
fn (app &App) highlight_candidate_fast(content string, lines []string, symbol string, cursor_line int, cursor_start_byte int, cursor_keys map[string]int, cursor_member bool, cursor_is_decl bool, index_anchor bool, cand_line int, start_char int, end_char int, line_text string, start_byte int, end_byte int) ?bool {
	if symbol == 'it' || symbol == 'err' {
		return none
	}
	if cursor_member {
		return none
	}
	_, cand_member, _ := member_qualifier_at_cursor(line_text, end_char, app.position_encoding)
	if cand_member {
		return none
	}
	cand_pos := Position{
		line: cand_line
		char: start_char
	}
	mut cand_keys := map[string]int{}
	for b in app.local_scope_bindings(content, cand_pos) {
		if b.name == symbol {
			cand_keys[highlight_binding_key(b.name, b.line, b.column)] = b.line
		}
	}
	cand_is_decl := source_occurrence_precedes_local_declaration(lines, cand_line, end_byte)
		|| is_fn_parameter_highlight(line_text, start_byte, end_byte)
	// A declaration truncates its own visible set, so the set-equality check
	// below only decides uses: equal sets of uses reference the same binding.
	if !cand_is_decl && cand_keys.len == cursor_keys.len {
		mut same := true
		for key, _ in cursor_keys {
			if key !in cand_keys {
				same = false
				break
			}
		}
		if same {
			if cursor_keys.len == 0 {
				if index_anchor
					&& highlight_candidate_is_top_level(lines, line_text, cand_line, start_byte, end_byte) {
					return true
				}
				return none
			}
			return true
		}
	}
	if cand_is_decl {
		if cursor_is_decl {
			// Two declarations are one binding only for the same occurrence.
			if cand_line == cursor_line && start_byte == cursor_start_byte {
				return true
			}
			return false
		}
		if visible_binding_matches(cursor_keys, cand_line, start_byte) {
			return true
		}
		for key, _ in cursor_keys {
			key_line, _ := binding_key_line_col(key)
			if key_line == cand_line {
				// Same line but a different (or shadowed) declaration: the
				// line alone cannot tell them apart.
				return false
			}
		}
	}
	if cursor_is_decl {
		if visible_binding_matches(cand_keys, cursor_line, cursor_start_byte) {
			return true
		}
		for key, _ in cand_keys {
			key_line, _ := binding_key_line_col(key)
			if key_line == cursor_line {
				// Same line but a different (or shadowing) use: the line
				// alone cannot tell them apart.
				return false
			}
		}
	}
	if cand_keys.len == 0 && cursor_keys.len == 0 {
		return none
	}
	return false
}
