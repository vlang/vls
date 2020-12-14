module main

import vls

struct Stdio {}

fn (io Stdio) send(output string) {
	print('Content-Length: ${data.len}\r\n\r\n$data')
}


fn main() {
	mut ls := vls.new(Stdio{})
	ls.start_loop()
}
