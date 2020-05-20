module main

import jsonrpc
import net

fn send_error_tcp(err_code int, conn net.Socket) {
	mut eres := Response{}
	eres.send_error(err_code)
	send_tcp_resp(&eres, conn)
}

fn handle_tcp(srv jsonrpc.Server, con net.Socket) {
	s := con.read_line()
	defer {	con.close() or { } }

	res := srv.exec(s) or {
		err_code := err.int()
		send_error_tcp(err_code, conn)
		return
	}

	con.send_string(res.gen_resp_text()) or { }
}

pub fn main() {
    port_num := 8000
	server := net.listen(port_num) or { panic('Failed to listen to port ${port_num}') }
	println('JSON-RPC Server has started on port ${port_num}')
    mut srv := jsonrpc.new()

    srv.register('greet', fn (ctx mut Context) string {
        name := jsonrpc.as_string(ctx.req.params)
        return 'Hello, $name'
    })

	for {
		conn := server.accept() or {
			send_error_tcp(SERVER_ERROR_START, conn)
			server.close() or { }
			panic(err)
		}

		go handle_tcp(conn)
	}
}