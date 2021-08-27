module server

import lsp

struct File {
mut:
	uri     lsp.DocumentUri
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

fn (file_map map[string]File) count(dir string) int {
	mut file_count := 0
	for k, _ in file_map {
		if k.starts_with(dir) {
			file_count++
		}
	}
	return file_count
}
