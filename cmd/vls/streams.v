module main

import term
import net
import os
import io

fn C._setmode(int, int)
fn C.fgetc(stream &C.FILE) int

// Stdin
fn new_stdio_stream() ?io.ReaderWriter {
	stream := &StdioStream{}
	$if windows {
		// 0x8000 = _O_BINARY from <fcntl.h>
		// windows replaces \n => \r\n, so \r\n will be replaced to \r\r\n
		// binary mode prevents this
		C._setmode(C._fileno(stream.stdin_file(), 0x8000))
	}
	return stream
}

struct StdioStream {
mut:
	stdin os.File = os.stdin()
	stdout os.File = os.stdout()
}

fn (mut stream StdioStream) stdin_file() &C.FILE {
	// TODO:
	// return &C.FILE(stream.stdin.cfile)
	return &C.FILE(C.stdin)
}

pub fn (mut stream StdioStream) write(buf []u8) ?int {
	defer { stream.stdout.flush() }
	return stream.stdout.write(buf)
}

pub fn (mut stream StdioStream) read(mut buf []u8) ?int {
	stdin_file := stream.stdin_file()
	initial_len := get_raw_input(stdin_file, mut buf) ?
	if buf.len < 1 || !buf.bytestr().starts_with(content_length) {
		return error('content length is missing')
	}
	mut conlen := buf[content_length.len..].bytestr().int()

	// just add \r\n\r\n
	for i := 0; i < 2; i++ {
		buf << `\r`
		buf << `\n`
	}

	for remaining := conlen; remaining != 0; {
		c := C.fgetc(stdin_file)
		$if !windows {
			if c == 10 || c == `\r` {
				continue
			}
		}
		buf << u8(c)
		remaining--
	}
	return initial_len + conlen
}

fn get_raw_input(file &C.FILE, mut buf []u8) ?int {
	eof := C.EOF
	mut len := 0
	for {
		c := C.fgetc(file)
		chr := u8(c)
		if buf.len > 2 && (c == eof || chr in [`\r`, `\n`]) {
			break
		}
		buf << chr
		len++
	}
	return len
}

// TCP Socket
const base_ip = '127.0.0.1'

// Loopback address.
fn new_socket_stream_server(port int, log bool) ?io.ReaderWriter {
	server_label := 'vls-server'

	// Open the connection.
	address := '$base_ip:$port'
	mut listener := net.listen_tcp(.ip, address) ?

	if log {
		eprintln(term.yellow('Warning: TCP connection is used primarily for debugging purposes only \n\tand may have performance issues. Use it on your own risk.\n'))
		println('[$server_label] : Established connection at $address\n')
	}

	mut conn := listener.accept() or {
		listener.close() or {}
		return err
	}

	mut reader := io.new_buffered_reader(reader: conn, cap: 1024 * 1024)
	conn.set_blocking(true) or {}

	mut stream := &SocketStream{
		log_label: server_label
		log: log
		port: port
		conn: conn
		reader: reader
	}

	return stream
}

fn new_socket_stream_client(port int) ?io.ReaderWriter {
	// Open the connection.
	address := '$base_ip:$port'
	mut conn := net.dial_tcp(address) ?
	mut reader := io.new_buffered_reader(reader: conn, cap: 1024 * 1024)
	conn.set_blocking(true) or {}

	mut stream := &SocketStream{
		log_label: 'vls-client'
		port: port
		conn: conn
		reader: reader
	}
	return stream
}

struct SocketStream {
	log_label string = 'vls'
	log       bool = true
mut:
	conn     &net.TcpConn       = &net.TcpConn(0)
	reader   &io.BufferedReader = voidptr(0)
pub mut:
	port  int = 5007
	debug bool
}

pub fn (mut sck SocketStream) write(buf []u8) ?int {
	// TODO: should be an interceptor
	$if !test {
		println('[$sck.log_label] : ${term.red('Sent data')} : $buf.bytestr()\n')
	}

	// if output.starts_with(content_length) {
		// sck.conn.write_string(output) or { panic(err) }
	// } else {
		// sck.conn.write_string(make_lsp_payload(output)) or { panic(err) }
	// }
	return sck.conn.write(buf)
}

const newlines = [u8(`\r`),`\n`]

[manualfree]
pub fn (mut sck SocketStream) read(mut buf []u8) ?int {
	mut conlen := 0
	mut header_len := 0

	for {
		// read header line
		got_header := sck.reader.read_line() ?
		buf << got_header.bytes()
		buf << newlines
		// $if !test {
		// 	println('[$sck.log_label] : ${term.green('Received data')} : $got_header')
		// }

		if got_header.len == 0 {
			continue
		} else if got_header.starts_with(content_length) {
			conlen = got_header.all_after(content_length).int()
			// read blank line
			empty := sck.reader.read_line() ?
			buf << empty.bytes()
			buf << newlines
			header_len = got_header.len + 4
			break
		}

		header_len = got_header.len + 2
	}

	if conlen > 0 {
		mut rbody := []u8{len: conlen}
		defer { unsafe { rbody.free() } }

		for read_data_len := 0; read_data_len != conlen; {
			read_data_len = sck.reader.read(mut rbody) ?
		}

		buf << rbody
	}

	$if !test {
		println('[$sck.log_label] : ${term.green('Received data')} : $buf.bytestr()\n')
	}
	return conlen + header_len
}
