module vls

import math.mathutil as mu
import v.token
import lsp

pub fn is_within_pos(offset int, pos token.Position) bool {
	return offset >= pos.pos && offset <= pos.pos + pos.len
}

// compute_offset returns a byte offset from the given position
pub fn compute_offset(src []byte, line int, col int) int {
	mut offset := 0
	mut src_line := 0
	mut src_col := 0
	for i := 0; i < src.len; i++ {
		byt := src[i]
		is_lf := byt == `\n`
		is_crlf := i != src.len - 1 && unsafe { byt == `\r` && src[i + 1] == `\n` }
		is_eol := is_lf || is_crlf
		if src_line == line && src_col == col {
			return offset
		}
		if is_eol {
			if src_line == line && col > src_col {
				return -1
			}
			src_line++
			src_col = 0
			if is_crlf {
				offset += 2
				i++
			} else {
				offset++
			}
			continue
		}
		src_col++
		offset++
	}
	return offset
}

pub fn compute_position(src []byte, target_offset int) lsp.Position {
	mut offset := 0
	mut src_line := 0
	mut src_col := 0
	for i := 0; i < src.len; i++ {
		byt := src[i]
		is_lf := byt == `\n`
		is_crlf := i != src.len - 1 && unsafe { byt == `\r` && src[i + 1] == `\n` }
		is_eol := is_lf || is_crlf
		if offset == target_offset {
			break
		}
		if is_eol {
			src_line++
			src_col = 0
			if is_crlf {
				offset += 2
				i++
			} else {
				offset++
			}
			continue
		}
		src_col++
		offset++
	}
	if target_offset > offset {
		remaining_offset := target_offset - offset
		return lsp.Position{src_line, src_col + remaining_offset}
	}
	
	return lsp.Position{src_line, src_col}
}

// position_to_lsp_pos converts the token.Position into lsp.Position
pub fn position_to_lsp_pos(pos token.Position) lsp.Position {
	return lsp.Position{
		line: pos.line_nr
		character: pos.col
	}
}

// position_to_lsp_pos converts the token.Position into lsp.Range
fn position_to_lsp_range(pos token.Position) lsp.Range {
	start_pos := position_to_lsp_pos(pos)
	return lsp.Range{
		start: start_pos
		end: lsp.Position{
			line: mu.max(pos.last_line, start_pos.line)
			character: start_pos.character + pos.len
		}
	}
}
