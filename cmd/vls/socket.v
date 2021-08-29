module main

import term
import net
import io

const base_ip = '127.0.0.1'

// Loopback address.

struct Socket {
mut:
	conn     &net.TcpConn     = &net.TcpConn(0)
	listener &net.TcpListener = &net.TcpListener(0)
pub mut:
	port  string = '5007'
	debug bool
}

pub fn (mut io Socket) init() ? {
	// Open the connection.
	address := '${base_ip}:${io.port}'
	io.listener = net.listen_tcp(.ip, address) ?
	eprintln(term.yellow('warning: ') + 'TCP connection is used primarily for debugging purposes only and may have performance issues. Use it on your own risk.')
	println('Established connection at ${address}')
	io.conn = io.listener.accept() or {
		io.listener.close() or {}
		return err
	}
}

pub fn (mut io Socket) send(output string) {
	io.conn.write_string('Content-Length: $output.len\r\n\r\n$output') or { panic(err) }
}

[manualfree]
pub fn (mut sck Socket) receive() ?string {
	mut reader := io.new_buffered_reader(reader: sck.conn)
	mut conlen := 0
	// mut raw_headers := []string{}

	for {
		got_header := reader.read_line() ?
		$if !test {
			println('[vls] : Received header : $got_header')
		}

		if got_header.len == 0 {
			break
		} else if got_header.starts_with(content_length) {
			conlen = got_header.all_after(content_length).int()
			break
		}
		// raw_headers << header_line
	}

	mut rbody := []byte{len: conlen, init: 0}
	defer {
		unsafe { rbody.free() }
	}

	if conlen > 0 {
		mut read_data_len := 0
		for read_data_len != conlen {
			read_data_len = reader.read(mut rbody) ?
		}
	}

	return rbody.bytestr()
}
