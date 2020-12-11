module main

import vls

fn main() {
	mut ls := vls.Vls{
		send: fn (data string) {
			// print to stdout
			print('Content-Length: ${data.len}\r\n\r\n$data')
		}
		// logging: os.getenv('VLS_LOG') == '1' || '-log' in os.args
	}
	ls.start_loop()
}
