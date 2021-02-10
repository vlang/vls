module vls

import v.token
import v.util
import lsp

// compute_offset returns a byte offset from the given position.
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

// get_column computes the column of the source based on the given initial position.
fn get_column(source []byte, init_pos int) int {
	mut p := init_pos
	if source.len > 0 {
		for ; p >= 0; p-- {
			if source[p] == `\r` || source[p] == `\n` {
				break
			}
		}
	}
	return p - 1
}

// position_to_lsp_pos converts the token.Position into lsp.Position.
pub fn position_to_lsp_pos(source []byte, pos token.Position) lsp.Position {
	p := util.imax(0, util.imin(source.len - 1, pos.pos))
	column := util.imax(0, pos.pos - get_column(source, p)) - 1
	return lsp.Position{
		line: pos.line_nr
		character: util.imax(1, column) - 1
	}
}

// position_to_lsp_pos converts the token.Position into lsp.Range.
fn position_to_lsp_range(source []byte, pos token.Position) lsp.Range {
	start_pos := position_to_lsp_pos(source, pos)
	return lsp.Range{
		start: start_pos
		end: lsp.Position{
			line: if pos.last_line > pos.line_nr {
				pos.last_line
			} else {
				start_pos.line
			}
			character: start_pos.character + pos.len
		}
	}
}
