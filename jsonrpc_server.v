module main

import (
	net
	json
	log
	http
)

// type RpcId = string | int

pub const (
    PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32693    
    SERVER_ERROR_START = -32099
    SERVER_ERROR_END = -32600
    SERVER_NOT_INITIALIZED = -32002
    UNKNOWN_ERROR = -32001
)

const (
    JRPC_VERSION = '2.0'
)

struct ServerContext {
pub mut:
	res RpcResponse
	req RpcRequest
	raw RpcRawRequest
	lsp Lsp
}

type HandlerFunc fn(ctx mut ServerContext) string

struct RpcRawRequest {
mut:
    jsonrpc string
    id int
    method string
	headers map[string]string [skip]
    params string [raw]
}

struct RpcRequest {
pub:
    jsonrpc string
    id int
    method string
mut:
    params string
}

struct RpcResponse {
    jsonrpc string
mut:
    id int
    error ResponseError [json:error]
    result string 
}

struct ResponseError {
mut:
    code int
    message string
    data string
}

struct Server {
mut:
	port int
	queues []Queue
}

struct Queue {
	id int
	handler fn (ServerContext) string
	ctx ServerContext
mut:
	is_cancelled bool
}

fn (res mut RpcResponse) send_error(err_code int) {
	mut error := ResponseError{ code: err_code, data: '' }
	error.message = err_message(err_code)
	res.error = error
}

fn err_message(err_code int) string {
	msg := match err_code {
		PARSE_ERROR { 'Invalid JSON' }
		INVALID_PARAMS { 'Invalid params.' }
		INVALID_REQUEST { 'Invalid request.' }
		METHOD_NOT_FOUND { 'Method not found.' }
		SERVER_ERROR_END { 'Error while stopping the server.' }
		SERVER_NOT_INITIALIZED { 'Server not yet initialized.' }
		SERVER_ERROR_START { 'Error while starting the server.' }
		else { 'Unknown error.' }
	}

	return msg
}

fn find_between(s string, start string, end string) string {
	start_pos := s.index(start) or { return '' }
	if start_pos == -1 {
		return ''
	}

	val := s[start_pos + start.len..]
	end_pos := val.last_index(end) or { return '' }
	if end_pos == -1 {
		return val
	}
	return val[..end_pos]
}

// pub fn (id RpcId) str() string {
// 	match id {
// 		string {
// 			return '"${it}"'
// 		}
// 		int {
// 			return it
// 		}
// 		else {
// 			return ''
// 		}
// 	}
// }

fn (res RpcResponse) json() string {
	mut res_json_arr := []string

	res_json_arr << '"jsonrpc":"${res.jsonrpc}"'
	
	if res.id != 0 {
		res_json_arr << '"id":${res.id}'
	}

	if res.error.message.len != 0 {
		res_json_arr << '"error": {"code":${res.error.code},"message":"${res.error.message}","data":"${res.error.data}"}'
	} else {
		if res.result.starts_with('{') && res.result.ends_with('}') {
			res_json_arr << '"result":${res.result}'
		} else {
			res_json_arr << '"result":"${res.result}"'
		}

	}

	return '{' + res_json_arr.join(',') + '}'
}

pub fn (err ResponseError) str() string {
	return json.encode(err)
}

fn (res &RpcResponse) send(conn net.Socket) {
	res_json := res.json()

	conn.write('Content-Length: ${res_json.len}\r') or { return }
	conn.write('') or { return }
	conn.write(res_json) or { return }
}

fn process_raw_request(json_str string, raw_contents string) RpcRawRequest {
	mut raw_req := RpcRawRequest{}
	raw_req.headers = http.parse_headers(raw_contents.split_into_lines())

	if json_str == '{}' {
		return raw_req
	} else {
		from_json := json.decode(RpcRawRequest, json_str) or { return raw_req }
		raw_req.jsonrpc = from_json.jsonrpc
		raw_req.id = from_json.id
		raw_req.method = from_json.method
		raw_req.params = from_json.params
	}
	return raw_req
}

fn (server mut Server) start_and_listen(func fn (nut ServerContext) string, port_num int) {
	server.port = port_num
	listener := net.listen(server.port) or {panic('Failed to listen to port ${server.port}')}
	mut logg := log.Log{ level: .info, output_label: 'JSON-RPC', output_to_file: false }
	mut is_running := false
	inst := Lsp{ file: '', computed: Computed{}, init: InitializeParams{} }

	logg.info('JSON-RPC Server has started on port ${server.port}')
	for {
		mut res := RpcResponse{ jsonrpc: JRPC_VERSION }
		conn := listener.accept() or {
			logg.set_level(1)
			logg.error(err_message(SERVER_ERROR_START))
			res.send_error(SERVER_ERROR_START)
			return
		}
		s := read_request_lines(conn)
		content := s[s.len-1]
		raw_req := process_raw_request(content, s.join('\r\n'))
		req := RpcRequest{JRPC_VERSION, raw_req.id, raw_req.method, raw_req.params}

		if s.len == 0 {
			logg.set_level(2)
			logg.error(err_message(INTERNAL_ERROR))
			res.send_error(INTERNAL_ERROR)
		}

		if content == '{}' || content == '' || s.len == 0 {
			logg.set_level(2)
			logg.error(err_message(INVALID_REQUEST))
			res.send_error(INVALID_REQUEST)
		}

		res.id = req.id
		ctx := ServerContext{res: res, req: req, raw: raw_req, lsp: inst}
		if req.method == '$/cancelRequest' {
			cancel_params := json.decode(CancelParams, req.params) or {
				return
			}

			server.cancel_request(cancel_params.id)
		} else {
			server.queues << Queue{ id: req.id, handler: func, ctx: ctx }
		}

		if !is_running {
			is_running = true
			process_queue(server.queues, conn, mut is_running, mut logg)
		}
	}
}

fn (server mut Server) cancel_request(id int) {
	idx := server.queues.index(id)
	server.queues[idx].is_cancelled = true
}

fn (qa []Queue) index(id int) int {
	for i, q in qa {
		if q.id == id { return i }
	}

	return -1
}

fn process_queue(queues []Queue, conn net.Socket, is_running mut bool, logg mut log.Log) {
	for i, q in queues {
		if q.is_cancelled { continue }

		mut ctx := q.ctx
		req := ctx.req
		raw_req := ctx.raw
		ctx.res.result = q.handler(ctx)
		ctx.res.send(conn)
		logg.set_level(4)
		logg.info('[ID: ${req.id}][${req.method}] ${raw_req.params}')

		if (i == queues.len-1) {
			is_running = false
		}

		conn.close() or { return }
	}
}

fn read_request_lines(sock &net.Socket) []string {
	mut lines := []string
	mut buf := [1024]byte

	for {
		mut res := ''
		mut line := ''
		mut len := 0
		for {
			n := C.recv(sock.sockfd, buf, 1024-1, net.MSG_PEEK)
			if n == -1 { return lines }
			if n == 0 {	return lines }
			buf[n] = `\0`
			mut eol_idx := -1
			for i := 0; i < n; i++ {
				if int(buf[i]) == 10 {
					eol_idx = i
					buf[i+1] = `\0`
					break
				}
			}
			line = tos_clone(buf)
			if eol_idx > 0 {
				C.recv(sock.sockfd, buf, eol_idx+1, 0)
				res += line
				break
			}
			C.recv(sock.sockfd, buf, n, 0)
			res += line
			len = n
			break
		}
		trimmed_line := res.trim_right('\r\n')
		if trimmed_line.len != 0 { lines << trimmed_line }
		if res.len == len { break }
	}

	return lines
}

pub fn new_jsonrpc_server() Server {
	return Server{ port: 8046, queues: [] }
}
