// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// Semantic token type indices — must match the order returned by semantic_token_types().
const sem_tok_keyword = 0
const sem_tok_comment = 1
const sem_tok_string = 2
const sem_tok_number = 3
const sem_tok_type = 4 // structs, enums, interfaces; uppercase-named identifiers
const sem_tok_function = 5
const sem_tok_method = 6
const sem_tok_property = 7
const sem_tok_variable = 8
const sem_tok_namespace = 9
const sem_mod_readonly = 1 << 1

// vfmt off
const digit_chars = [`0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`]!

const num_literal_chars = [
	`0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`,
	`.`, `_`, `x`, `X`, `o`, `O`,
	`a`, `b`, `c`, `d`, `e`, `f`,
	`A`, `B`, `C`, `D`, `E`, `F`
]!

const up_alpha_chars = [
	`A`, `B`, `C`, `D`, `E`, `F`, `G`, `H`, `I`, `J`, `K`, `L`, `M`,
	`N`, `O`, `P`, `Q`, `R`, `S`, `T`, `U`, `V`, `W`, `X`, `Y`, `Z`
]!

const identifier_start_chars = [
	`a`, `b`, `c`, `d`, `e`, `f`, `g`, `h`, `i`, `j`, `k`, `l`, `m`,
	`n`, `o`, `p`, `q`, `r`, `s`, `t`, `u`, `v`, `w`, `x`, `y`, `z`,
	`A`, `B`, `C`, `D`, `E`, `F`, `G`, `H`, `I`, `J`, `K`, `L`, `M`,
	`N`, `O`, `P`, `Q`, `R`, `S`, `T`, `U`, `V`, `W`, `X`, `Y`, `Z`,
	`_`
]!

const identifier_chars = [
	`a`, `b`, `c`, `d`, `e`, `f`, `g`, `h`, `i`, `j`, `k`, `l`, `m`,
	`n`, `o`, `p`, `q`, `r`, `s`, `t`, `u`, `v`, `w`, `x`, `y`, `z`,
	`A`, `B`, `C`, `D`, `E`, `F`, `G`, `H`, `I`, `J`, `K`, `L`, `M`,
	`N`, `O`, `P`, `Q`, `R`, `S`, `T`, `U`, `V`, `W`, `X`, `Y`, `Z`,
	`0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`,
	`_`,
]!

const v_builtin_types = [
	'any', 'bool', 'byteptr', 'charptr',
	'f32', 'f64',
	'i8', 'i16', 'int', 'i64', 'isize',
	'rune', 'string',
	'u8', 'u16', 'u32', 'u64', 'usize',
	'voidptr'
]!
// vfmt on

// semantic_token_types returns the ordered list of token-type names that forms
// the server's SemanticTokensLegend. Indices must match the sem_tok_* constants.
fn semantic_token_types() []string {
	return ['keyword', 'comment', 'string', 'number', 'type', 'function', 'method', 'property',
		'variable', 'namespace']
}

// semantic_token_modifiers returns the ordered list of modifier names.
fn semantic_token_modifiers() []string {
	return ['declaration', 'readonly']
}

// SemToken holds the absolute position and classification of one semantic token.
struct SemToken {
	line     int
	start    int
	length   int
	type_idx int
	mod_bits int
}

struct TokenizeState {
mut:
	in_block_comment bool
}

// tokenize_v_source returns all semantic tokens for the given V source text.
fn tokenize_v_source(content string) []SemToken {
	mut state := TokenizeState{}
	mut tokens := []SemToken{}
	lines := content.split_into_lines()
	mut import_aliases := map[string]bool{}
	for alias, _ in parse_import_aliases(content) {
		import_aliases[alias] = true
	}
	readonly_variables, line_scopes := collect_readonly_variables(lines)
	for line_idx, line in lines {
		tokenize_v_line(line, line_idx, line_scopes[line_idx], readonly_variables, import_aliases, mut
			state, mut tokens)
	}
	return tokens
}

// tokenize_v_line scans one source line and appends recognised tokens to `tokens`.
fn tokenize_v_line(line string, line_idx int, variable_scope int, readonly_variables map[string]bool, import_aliases map[string]bool, mut state TokenizeState, mut tokens []SemToken) {
	n := line.len
	mut col := 0

	// If we enter this line already inside a /* … */ block comment, advance until
	// the */ closing marker or end-of-line.
	if state.in_block_comment {
		start := 0
		for col < n {
			if col + 1 < n && line[col] == `*` && line[col + 1] == `/` {
				col += 2
				state.in_block_comment = false
				break
			}
			col++
		}
		if col > start {
			tokens << SemToken{
				line:     line_idx
				start:    start
				length:   col - start
				type_idx: sem_tok_comment
			}
		}
		if state.in_block_comment {
			return
		}
	}

	for col < n {
		c := line[col]

		// Skip whitespace.
		if c == ` ` || c == `\t` {
			col++
			continue
		}

		// Block comment: /* … */
		if col + 1 < n && c == `/` && line[col + 1] == `*` {
			start := col
			col += 2
			mut closed := false
			for col < n {
				if col + 1 < n && line[col] == `*` && line[col + 1] == `/` {
					col += 2
					closed = true
					break
				}
				col++
			}
			if !closed {
				state.in_block_comment = true
			}
			tokens << SemToken{
				line:     line_idx
				start:    start
				length:   col - start
				type_idx: sem_tok_comment
			}
			continue
		}

		// Line comment: // …
		if col + 1 < n && c == `/` && line[col + 1] == `/` {
			tokens << SemToken{
				line:     line_idx
				start:    col
				length:   n - col
				type_idx: sem_tok_comment
			}
			return
		}

		// String with prefix: c"…", r"…", c'…', r'…'
		if (c == `c` || c == `r`) && col + 1 < n && (line[col + 1] == `"` || line[col + 1] == `'`) {
			start := col
			col++ // skip prefix
			quote := line[col]
			col++ // skip opening quote
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
			tokens << SemToken{
				line:     line_idx
				start:    start
				length:   col - start
				type_idx: sem_tok_string
			}
			continue
		}

		// String literals: "…" or '…'
		if c == `"` || c == `'` {
			start := col
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
			tokens << SemToken{
				line:     line_idx
				start:    start
				length:   col - start
				type_idx: sem_tok_string
			}
			continue
		}

		// Number literal (integer or float).
		if c in digit_chars {
			start := col
			for col < n {
				ch := line[col]
				if ch in num_literal_chars {
					col++
				} else {
					break
				}
			}
			tokens << SemToken{
				line:     line_idx
				start:    start
				length:   col - start
				type_idx: sem_tok_number
			}
			continue
		}

		// Identifier, keyword, type, or builtin function name.
		if c in identifier_start_chars {
			start := col
			for col < n {
				ch := line[col]
				if ch in identifier_chars {
					col++
				} else {
					break
				}
			}
			word := line[start..col]
			tok_type := classify_v_identifier_at(line, start, col, word, import_aliases)
			if tok_type >= 0 {
				tokens << SemToken{
					line:     line_idx
					start:    start
					length:   col - start
					type_idx: tok_type
					mod_bits: if tok_type == sem_tok_variable
						&& (variable_binding_key(variable_scope, word) in readonly_variables
						|| variable_binding_key(0, word) in readonly_variables) {
						sem_mod_readonly
					} else {
						0
					}
				}
			}
			continue
		}

		col++
	}
}

fn collect_readonly_variables(lines []string) (map[string]bool, []int) {
	mut readonly := map[string]bool{}
	mut mutable := map[string]bool{}
	mut line_scopes := []int{cap: lines.len}
	mut in_const_block := false
	mut variable_scope := 0
	mut next_scope := 1
	mut brace_depth := 0
	mut function_base_depth := 0
	mut function_body_started := false
	for raw_line in lines {
		line := raw_line.all_before('//').trim_space()
		stripped := if line.starts_with('pub ') { line[4..] } else { line }
		if stripped.starts_with('fn ') {
			variable_scope = next_scope
			next_scope++
			function_base_depth = brace_depth
			function_body_started = false
		}
		line_scopes << variable_scope
		if line == '' {
			continue
		}
		if line == 'const (' {
			in_const_block = true
			continue
		}
		if in_const_block {
			if line == ')' {
				in_const_block = false
				continue
			}
			if eq := line.index('=') {
				mark_variable_binding(line[..eq].trim_space(), false, variable_scope, mut readonly, mut
					mutable)
			}
			continue
		}
		if line.starts_with('const ') {
			if eq := line.index('=') {
				mark_variable_binding(line[6..eq].trim_space(), false, variable_scope, mut
					readonly, mut mutable)
			}
		}
		if assign := line.index(' := ') {
			lhs := line[..assign].trim_space()
			is_mut := lhs.starts_with('mut ')
			names := if is_mut { lhs[4..] } else { lhs }
			for name in names.split(',') {
				fields := name.fields()
				if fields.len > 0 {
					mark_variable_binding(fields.last(), is_mut, variable_scope, mut readonly, mut
						mutable)
				}
			}
		}
		collect_fn_parameter_bindings(line, variable_scope, mut readonly, mut mutable)
		if variable_scope != 0 {
			if line.contains('{') {
				function_body_started = true
			}
			brace_depth += line.count('{') - line.count('}')
			if function_body_started && brace_depth <= function_base_depth {
				variable_scope = 0
				function_body_started = false
			}
		} else {
			brace_depth += line.count('{') - line.count('}')
		}
	}
	for key, _ in mutable {
		readonly.delete(key)
	}
	return readonly, line_scopes
}

fn collect_fn_parameter_bindings(line string, variable_scope int, mut readonly map[string]bool, mut mutable map[string]bool) {
	stripped := if line.starts_with('pub fn ') {
		line[7..]
	} else if line.starts_with('fn ') {
		line[3..]
	} else {
		return
	}
	mut search_start := 0
	for search_start < stripped.len {
		open_offset := stripped[search_start..].index('(') or { return }
		open := search_start + open_offset
		close_offset := stripped[open + 1..].index(')') or { return }
		close := open + 1 + close_offset
		for raw_parameter in stripped[open + 1..close].split(',') {
			parts := raw_parameter.trim_space().fields()
			if parts.len < 2 {
				continue
			}
			is_mut := parts[0] == 'mut'
			name_idx := if is_mut { 1 } else { 0 }
			if name_idx < parts.len - 1 {
				mark_variable_binding(parts[name_idx], is_mut, variable_scope, mut readonly, mut
					mutable)
			}
		}
		search_start = close + 1
	}
}

fn variable_binding_key(variable_scope int, name string) string {
	return '${variable_scope}:${name}'
}

fn mark_variable_binding(name string, is_mut bool, variable_scope int, mut readonly map[string]bool, mut mutable map[string]bool) {
	if name == '' || name == '_' {
		return
	}
	key := variable_binding_key(variable_scope, name)
	if is_mut {
		mutable[key] = true
	} else {
		readonly[key] = true
	}
}

fn classify_v_identifier_at(line string, start int, end int, word string, import_aliases map[string]bool) int {
	prefix := line[..start].trim_space()
	if prefix == 'module' || prefix == 'import' || prefix.starts_with('import ') {
		return sem_tok_namespace
	}
	if word in import_aliases {
		return sem_tok_namespace
	}
	base_type := classify_v_identifier(word)
	if base_type >= 0 {
		return base_type
	}
	mut prev := start - 1
	for prev >= 0 && (line[prev] == ` ` || line[prev] == `\t`) {
		prev--
	}
	mut next := end
	for next < line.len && (line[next] == ` ` || line[next] == `\t`) {
		next++
	}
	if next < line.len && line[next] == `(` {
		if prev >= 0 && line[prev] == `.` {
			receiver := identifier_before_dot(line, prev)
			if receiver in import_aliases {
				return sem_tok_function
			}
			return sem_tok_method
		}
		if is_method_declaration_identifier(line, start) {
			return sem_tok_method
		}
		return sem_tok_function
	}
	if prev >= 0 && line[prev] == `.` {
		return sem_tok_property
	}
	return sem_tok_variable
}

fn is_method_declaration_identifier(line string, start int) bool {
	fn_offset := line.index('fn (') or { return false }
	receiver_open := fn_offset + 3
	receiver_close_offset := line[receiver_open + 1..].index(')') or { return false }
	receiver_close := receiver_open + 1 + receiver_close_offset
	mut name_start := receiver_close + 1
	for name_start < line.len && (line[name_start] == ` ` || line[name_start] == `\t`) {
		name_start++
	}
	return start == name_start
}

fn identifier_before_dot(line string, dot int) string {
	if dot <= 0 || dot > line.len || line[dot] != `.` {
		return ''
	}
	mut start := dot
	for start > 0 && is_ident_char(line[start - 1]) {
		start--
	}
	return line[start..dot]
}

// classify_v_identifier returns the semantic token type index for an identifier,
// or -1 when no special highlighting is needed.
fn classify_v_identifier(word string) int {
	if word in v_keywords {
		return sem_tok_keyword
	}
	if word in v_builtins {
		return sem_tok_function
	}
	if word in v_builtin_types {
		return sem_tok_type
	}
	// V naming convention: types start with an uppercase letter.
	if word != '' && word[0] in up_alpha_chars {
		return sem_tok_type
	}
	return -1
}

// convert_tokens_to_encoding rewrites each token's byte-based `start`/`length`
// into the client's negotiated position encoding, so semantic-token positions
// are consistent with the advertised encoding for non-ASCII lines (P2-01).
fn convert_tokens_to_encoding(tokens []SemToken, lines []string, enc PositionEncoding) []SemToken {
	if enc == .utf8 {
		// The tokenizer already works in byte offsets.
		return tokens
	}
	mut out := []SemToken{cap: tokens.len}
	for tok in tokens {
		if tok.line < 0 || tok.line >= lines.len {
			out << tok
			continue
		}
		line := lines[tok.line]
		enc_start := byte_to_encoded_col(line, tok.start, enc)
		enc_end := byte_to_encoded_col(line, tok.start + tok.length, enc)
		out << SemToken{
			...tok
			start:  enc_start
			length: enc_end - enc_start
		}
	}
	return out
}

// encode_semantic_tokens converts absolute-position SemTokens into the
// delta-encoded integer array required by the LSP SemanticTokens protocol.
// Tokens must already be ordered by (line, start) ascending.
fn encode_semantic_tokens(raw_tokens []SemToken) []int {
	mut result := []int{}
	mut prev_line := 0
	mut prev_char := 0
	for tok in raw_tokens {
		delta_line := tok.line - prev_line
		delta_char := if tok.line == prev_line { tok.start - prev_char } else { tok.start }
		result << delta_line
		result << delta_char
		result << tok.length
		result << tok.type_idx
		result << tok.mod_bits
		prev_line = tok.line
		prev_char = tok.start
	}
	return result
}

// handle_semantic_tokens handles the textDocument/semanticTokens/full LSP request,
// returning semantic highlighting data for the entire document.
fn (mut app App) handle_semantic_tokens(request Request) Response {
	params := json2.decode[SemanticTokensParams](request.params) or {
		$if debug { log('Failed to decode SemanticTokensParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	if content == '' {
		// An empty document has an empty token set, not a null result (P2-01).
		return Response{
			id:     request.id
			result: SemanticTokens{
				data: []
			}
		}
	}
	lines := content.split_into_lines()
	raw_tokens := convert_tokens_to_encoding(tokenize_v_source(content), lines,
		app.position_encoding)
	encoded := encode_semantic_tokens(raw_tokens)
	return Response{
		id:     request.id
		result: SemanticTokens{
			data: encoded
		}
	}
}

// handle_semantic_tokens_range handles textDocument/semanticTokens/range.
// It tokenizes the full document but only encodes tokens within the requested range,
// which reduces payload size for large files.
fn (mut app App) handle_semantic_tokens_range(request Request) Response {
	params := json2.decode[SemanticTokensRangeParams](request.params) or {
		$if debug { log('Failed to decode SemanticTokensRangeParams: ${err}') }
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	if content == '' {
		return Response{
			id:     request.id
			result: SemanticTokens{
				data: []
			}
		}
	}
	lines := content.split_into_lines()
	raw_tokens := convert_tokens_to_encoding(tokenize_v_source(content), lines,
		app.position_encoding)
	start_line := params.range.start.line
	start_char := params.range.start.char
	end_line := params.range.end.line
	end_char := params.range.end.char
	// semanticTokens/range must return only tokens inside the requested range, so
	// bound by character on the boundary lines too — not just by line. A token at
	// (line, start) is kept when its start position is >= the range start and <
	// the range end in (line, char) order; this excludes tokens before the start
	// character on the first line and at/after the end character on the last line.
	range_tokens := raw_tokens.filter((it.line > start_line
		|| (it.line == start_line && it.start >= start_char)) && (it.line < end_line
		|| (it.line == end_line && it.start < end_char)))
	encoded := encode_semantic_tokens(range_tokens)
	return Response{
		id:     request.id
		result: SemanticTokens{
			data: encoded
		}
	}
}
