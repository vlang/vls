module vls

import lsp

struct File {
mut:
	uri lsp.DocumentUri
	source  []byte
	version int = 1
}

[unsafe]
fn (file &File) free() {
	unsafe {
		file.source.free()
		file.version = 1
	}
}

fn (file &File) get_offset(line int, col int) int {
	return compute_offset(file.source, line, col)
}

fn (file &File) get_position(offset int) lsp.Position {
	return compute_position(file.source, offset)
}