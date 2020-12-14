module main

import vls
import strings

fn C.fgetc(stream byteptr) int

fn get_raw_input() string {
	eof := C.EOF
	mut buf := strings.new_builder(200)
	for {
		c := C.fgetc(C.stdin)
		chr := byte(c)
		if buf.len > 2 && (c == eof || chr in [`\r`, `\n`]) {
			break
		}
		buf.write_b(chr)
	}
	return buf.str()
}

fn on_stdio_receive(rec voidptr, data voidptr, ls voidptr) {
	resp := unsafe { charptr(data).vstring() }
	print(resp)
}

fn start_stdio(mut ls vls.Vls) {
	mut sub := ls.subscriber()
	sub.subscribe('response', on_stdio_receive)

	for {
		first_line := get_raw_input()
		if first_line.len < 1 || !first_line.starts_with(content_length) {
			continue
		}
		mut buf := strings.new_builder(1)
		mut conlen := first_line[content_length.len..].int()
		$if !windows { conlen++ }
		for conlen > 0 {
			c := C.fgetc(C.stdin)
			$if !windows {
				if c == 10 { continue }
			}
			buf.write_b(byte(c))
			conlen--
		}
		payload := buf.str()
		ls.execute(payload[1..])
		unsafe { buf.free() }
	}
}
