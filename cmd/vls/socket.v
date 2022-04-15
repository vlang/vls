module main

import term
import net
import io

const base_ip = '127.0.0.1'

// Loopback address.

struct Socket {
mut:
	conn     &net.TcpConn       = &net.TcpConn(0)
	listener &net.TcpListener   = &net.TcpListener(0)
	reader   &io.BufferedReader = voidptr(0)
pub mut:
	port  int = 5007
	debug bool
}

pub fn (mut sck Socket) init() ? {
	// Open the connection.
	address := '$base_ip:$sck.port'
	sck.listener = net.listen_tcp(.ip, address) ?
	eprintln(term.yellow('Warning: TCP connection is used primarily for debugging purposes only \n\tand may have performance issues. Use it on your own risk.\n'))
	println('[vls] : Established connection at $address\n')
	sck.conn = sck.listener.accept() or {
		sck.listener.close() or {}
		return err
	}
	sck.reader = io.new_buffered_reader(reader: sck.conn, cap: 1024 * 1024)
	sck.conn.set_blocking(true) or {}
}

pub fn (mut sck Socket) send(output string) {
	$if !test {
		println('[vls] : ${term.red('Sent data')} : Content-Length: $output.len | $output\n')
	}

	if output.starts_with(content_length) {
		sck.conn.write_string(output) or { panic(err) }
	} else {
		sck.conn.write_string(make_lsp_payload(output)) or { panic(err) }
	}
}

[manualfree]
pub fn (mut sck Socket) receive() ?string {
	mut conlen := 0

	for {
		// read header line
		got_header := sck.reader.read_line() ?
		// $if !test {
		// 	println('[vls] : ${term.green('Received data')} : $got_header')
		// }

		if got_header.len == 0 {
			continue
		} else if got_header.starts_with(content_length) {
			conlen = got_header.all_after(content_length).int()
			// read blank line
			sck.reader.read_line() ?
			break
		}
	}

	mut rbody := []u8{len: conlen, init: 0}
	defer {
		unsafe { rbody.free() }
	}

	if conlen > 0 {
		mut read_data_len := 0
		for read_data_len != conlen {
			read_data_len = sck.reader.read(mut rbody) ?
		}
	}

	$if !test {
		println('[vls] : ${term.green('Received data')} : Content-Length: $rbody.len | $rbody.bytestr()\n')
	}
	return rbody.bytestr()
}
