module main

import vls

struct Stdio {}

fn (io Stdio) send(output string) {
	print('Content-Length: ${data.len}\r\n\r\n$data')
}


fn main() {
	mut ls := vls.Vls{
		output: Stdio{}
	}
	ls.start_loop()
}
