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
// vfmt on

// semantic_token_types returns the ordered list of token-type names that forms
// the server's SemanticTokensLegend. Indices must match the sem_tok_* constants.
fn semantic_token_types() []string {
	return ['keyword', 'comment', 'string', 'number', 'type', 'function']
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
	for line_idx, line in lines {
		tokenize_v_line(line, line_idx, mut state, mut tokens)
	}
	return tokens
}

// tokenize_v_line scans one source line and appends recognised tokens to `tokens`.
fn tokenize_v_line(line string, line_idx int, mut state TokenizeState, mut tokens []SemToken) {
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
			tok_type := classify_v_identifier(word)
			if tok_type >= 0 {
				tokens << SemToken{
					line:     line_idx
					start:    start
					length:   col - start
					type_idx: tok_type
				}
			}
			continue
		}

		col++
	}
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
	// V naming convention: types start with an uppercase letter.
	if word != '' && word[0] in up_alpha_chars {
		return sem_tok_type
	}
	return -1
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
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	raw_tokens := tokenize_v_source(content)
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
			result: 'null'
		}
	}
	raw_tokens := tokenize_v_source(content)
	start_line := params.range.start.line
	end_line := params.range.end.line
	range_tokens := raw_tokens.filter(it.line >= start_line && it.line <= end_line)
	encoded := encode_semantic_tokens(range_tokens)
	return Response{
		id:     request.id
		result: SemanticTokens{
			data: encoded
		}
	}
}
