module main

import vls

fn C._setmode(int, int)

fn main() {
	$if windows {
		// 0x8000 = _O_BINARY from <fcntl.h>
		// windows replaces \n => \r\n, so \r\n will be replaced to \r\r\n
		// binary mode prevents this
		C._setmode(C._fileno(C.stdout), 0x8000)
	}
	mut ls := vls.new(Stdio{})
	ls.start_loop()
}
