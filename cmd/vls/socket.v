module main

import net

const base_ip = '127.0.0.1' // Loopback address.

struct Socket {
mut:
	conn &net.TcpConn
pub mut:
	port  string
	debug bool
}

pub fn (mut io Socket) initialize() {
	// Open the connection.
	io.conn = net.dial_tcp('${base_ip}:${io.port}') or {
		println(err)
		exit(1)
	}
	// TODO: People say there is a handshake, but which? what is that about?
}

pub fn (mut io Socket) send(output string) {
	io.conn.write_string(output) or {
		println(err)
		exit(1)
	}
}

[manualfree]
pub fn (mut io Socket) receive() ?string {
	mut data := []byte{}
	data_len := io.conn.read(mut data) ?
	return string(data[0..data_len])
}

pub fn (mut io Socket) close() {
	io.conn.close() or {
		println(err)
		exit(1)
	}
}
