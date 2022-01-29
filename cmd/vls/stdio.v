module main

import strings

fn C._setmode(int, int)
fn C.fgetc(stream &C.FILE) int

struct Stdio {
pub mut:
	debug bool
}

pub fn (_ Stdio) init() ? {
	$if windows {
		// 0x8000 = _O_BINARY from <fcntl.h>
		// windows replaces \n => \r\n, so \r\n will be replaced to \r\r\n
		// binary mode prevents this
		C._setmode(C._fileno(C.stdout), 0x8000)
	}
}

pub fn (_ Stdio) send(output string) {
	if output.starts_with(content_length) {
		print(output)
	} else {
		print(make_lsp_payload(output))
	}
}

[manualfree]
pub fn (_ Stdio) receive() ?string {
	first_line := get_raw_input()
	if first_line.len < 1 || !first_line.starts_with(content_length) {
		return error('content length is missing')
	}
	mut conlen := first_line[content_length.len..].int()
	mut buf := strings.new_builder(conlen)
	for conlen >= 0 {
		c := C.fgetc(&C.FILE(C.stdin))
		$if !windows {
			if c == 10 {
				continue
			}
		}
		buf.write_byte(byte(c))
		conlen--
	}
	payload := buf.str()
	unsafe { buf.free() }
	return payload[1..]
}

fn get_raw_input() string {
	eof := C.EOF
	mut buf := strings.new_builder(200)
	for {
		c := C.fgetc(&C.FILE(C.stdin))
		chr := byte(c)
		if buf.len > 2 && (c == eof || chr in [`\r`, `\n`]) {
			break
		}
		buf.write_byte(chr)
	}
	return buf.str()
}

pub fn (_ Stdio) close() {
	return
}
