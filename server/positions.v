module server

// commenting it here so that it recognizes that
// TSPoint and TSRange is used from the "tree_sitter" module
// import tree_sitter
import lsp

// compute_offset returns a byte offset from the given position
pub fn compute_offset(src []rune, line int, col int) int {
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

pub fn compute_position(src []rune, target_offset int) lsp.Position {
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
pub fn tspoint_to_lsp_pos(point C.TSPoint) lsp.Position {
	return lsp.Position{
		line: int(point.row)
		character: int(point.column)
	}
}

// position_to_lsp_pos converts the token.Position into lsp.Range
fn tsrange_to_lsp_range(range C.TSRange) lsp.Range {
	start_pos := tspoint_to_lsp_pos(range.start_point)
	end_pos := tspoint_to_lsp_pos(range.end_point)

	return lsp.Range{
		start: start_pos
		end: end_pos
	}
}

fn lsp_pos_to_tspoint(pos lsp.Position) C.TSPoint {
	return C.TSPoint{
		row: u32(pos.line)
		column: u32(pos.character)
	}
}
