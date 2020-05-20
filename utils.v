module main

fn C.fgetc(stream byteptr) int
fn C._setmode(mode int) int

fn get_raw_input() string {
	eof := C.EOF
    mut c := -2
	mut buf := ''
	mut newlines := 0

	for {
		c = C.fgetc(C.stdin)
		chr := byte(c)
		if c == eof || newlines >= 2 {
			break
		}
		buf += chr.str()
		if chr in [`\r`, `\n`] {
			newlines++
		}
	}

	return buf
}