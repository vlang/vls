module main

import vls

fn main() {
	mut ls := vls.new(Stdio{})
	ls.start_loop()
}
