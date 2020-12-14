module main

import vls

const (
	content_length = 'Content-Length: '
)

fn main() {
	mut ls := vls.Vls{
		// logging: os.getenv('VLS_LOG') == '1' || '-log' in os.args
	}

	start_stdio(mut ls)
}
