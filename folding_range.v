// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// handle_folding_range handles the textDocument/foldingRange LSP request,
// returning all collapsible regions for the document.
fn (mut app App) handle_folding_range(request Request) Response {
	params := json2.decode[FoldingRangeParams](request.params) or {
		$if debug { log('Failed to decode FoldingRangeParams: ${err}') }
		return Response{
			id:     request.id
			result: []FoldingRange{}
		}
	}
	uri := params.text_document.uri
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	if content == '' {
		return Response{
			id:     request.id
			result: []FoldingRange{}
		}
	}
	return Response{
		id:     request.id
		result: compute_folding_ranges(content)
	}
}

// compute_folding_ranges analyses V source and returns all foldable regions:
// brace-delimited blocks, consecutive import lines, and consecutive comment lines.
fn compute_folding_ranges(content string) []FoldingRange {
	lines := content.split_into_lines()
	mut ranges := []FoldingRange{}
	mut brace_stack := []int{}

	mut import_start := -1
	mut import_end := -1

	mut comment_start := -1
	mut comment_end := -1

	mut in_block_comment := false
	mut block_comment_start := -1

	for i, raw in lines {
		trimmed := raw.trim_space()

		// ── Inside a /* … */ block comment ──────────────────────────────
		if in_block_comment {
			if raw.contains('*/') {
				in_block_comment = false
				if i > block_comment_start {
					ranges << FoldingRange{
						start_line: block_comment_start
						end_line:   i
						kind:       'comment'
					}
				}
				block_comment_start = -1
			}
			continue
		}

		// ── Opening of a multi-line block comment ────────────────────────
		if trimmed.starts_with('/*') && !trimmed.contains('*/') {
			in_block_comment = true
			block_comment_start = i
			continue
		}

		// ── Import groups ─────────────────────────────────────────────────
		if trimmed.starts_with('import ') {
			if import_start < 0 {
				import_start = i
			}
			import_end = i
		} else {
			if import_start >= 0 && import_end > import_start {
				ranges << FoldingRange{
					start_line: import_start
					end_line:   import_end
					kind:       'imports'
				}
			}
			import_start = -1
			import_end = -1
		}

		// ── Line-comment blocks ───────────────────────────────────────────
		if trimmed.starts_with('//') {
			if comment_start < 0 {
				comment_start = i
			}
			comment_end = i
		} else {
			if comment_start >= 0 && comment_end > comment_start {
				ranges << FoldingRange{
					start_line: comment_start
					end_line:   comment_end
					kind:       'comment'
				}
			}
			comment_start = -1
			comment_end = -1
		}

		// ── Brace-delimited regions ───────────────────────────────────────
		delta := line_brace_delta(raw)
		if delta > 0 {
			for _ in 0 .. delta {
				brace_stack << i
			}
		} else if delta < 0 {
			for _ in 0 .. -delta {
				if brace_stack.len > 0 {
					start := brace_stack.pop()
					if i > start {
						ranges << FoldingRange{
							start_line: start
							end_line:   i
							kind:       'region'
						}
					}
				}
			}
		}
	}

	// Flush any trailing import or comment blocks.
	if import_start >= 0 && import_end > import_start {
		ranges << FoldingRange{
			start_line: import_start
			end_line:   import_end
			kind:       'imports'
		}
	}
	if comment_start >= 0 && comment_end > comment_start {
		ranges << FoldingRange{
			start_line: comment_start
			end_line:   comment_end
			kind:       'comment'
		}
	}

	return ranges
}

// line_brace_delta returns the net count of unmatched `{` (positive) or `}`
// (negative) on a single source line, skipping braces inside string literals
// and line/block comments.
fn line_brace_delta(line string) int {
	mut opens := 0
	n := line.len
	mut col := 0
	for col < n {
		c := line[col]
		// Skip string literals "…" and '…'.
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
		// Stop at a line comment.
		if col + 1 < n && c == `/` && line[col + 1] == `/` {
			break
		}
		// Stop at a block comment start (remainder is handled at line level).
		if col + 1 < n && c == `/` && line[col + 1] == `*` {
			break
		}
		if c == `{` {
			opens++
		} else if c == `}` {
			opens--
		}
		col++
	}
	return opens
}

// find_fn_body_end returns the line index of the closing `}` for the function
// whose declaration is at `fn_start_line`, using brace tracking.
// Falls back to the last line if no matching brace is found.
fn find_fn_body_end(lines []string, fn_start_line int) int {
	mut depth := 0
	for li in fn_start_line .. lines.len {
		depth += line_brace_delta(lines[li])
		if depth == 0 && li > fn_start_line {
			return li
		}
	}
	return lines.len - 1
}
