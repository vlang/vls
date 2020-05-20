module jsonrpc

import json
import net.http
import strings

pub const (
	JRPC_VERSION = '2.0'
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

type ProcFunc = fn (mut ctx Context) string

pub struct Context {
pub mut:
	res Response
	req Request
}

struct Request {
pub mut:
    jsonrpc string = JRPC_VERSION
    id int
    method string
    params string [raw]
}

pub struct Response {
pub:
    jsonrpc string = JRPC_VERSION
pub mut:
    id int
    error ResponseError
    result string
}

pub struct ResponseError {
mut:
    code int
    message string
    data string
}

pub struct Server {
mut:
	procs map[string]ProcFunc = map[string]ProcFunc
}

pub fn (mut res Response) send_error(err_code int) {
	res.error = ResponseError{ 
		code: err_code, 
		data: '', 
		message: err_message(err_code) 
	}
}

pub fn err_message(err_code int) string {
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

pub fn (res Response) gen_json() string {
	mut js := strings.new_builder(5000)
	js.write('{"jsonrpc":"${res.jsonrpc}"')
	js.write(',"id":${res.id}')
	if res.error.message.len != 0 {
		js.write(',"result":null')
		js.write(',"error":${res.error.gen_json()}')
	} else {
		js.write(',"result":${serialize_str_data(res.result)}')
	}
	js.write('}')
	return js.str()
}

pub fn serialize_str_data(data string) string {
	if data.len < 3 && data.len >= 1 {
		return '"$data"'
	}

	if data.len == 0 {
		return 'null'
	}

	typ := data[0..3]
	non_str_types := ['int:', 'obj:', 'arr:', 'bol:', 'nul:']
	is_non_str := typ != 'str:' && typ in non_str_types

	if is_non_str || data[0].is_digit() || data[0] in [`[`, `{`] {
		if typ in non_str_types {
			return data[4..]
		} else {
			return data
		}
	} else {
		if typ == 'str:' {
			return data[4..]
		} else {
			return '"$data"'
		}
	}
}

pub fn (err &ResponseError) gen_json() string {
	g := strings.new_builder(2000)
	data := serialize_str_data(err.data)
	encoded := if data[0] == `"` && data[data.len-1] == `"` { data[1..data.len-1] } else { data }
	g.write('{"code":${err.code},"message":"${err.message}","data":')
	g.write(encoded)
	g.write('}')

	return g.str()
}

pub fn (res &Response) gen_resp_text() string {
	js := res.gen_json()
	return 'Content-Length: ${js.len}\r\n\r\n${js}'
}

pub fn process_request(js_str string) Request {
	if js_str == '{}' { return Request{ params: '' } }
	req := json.decode(Request, js_str) or { return Request{} }
	return req
}

// pub fn (srv Server) exec(incoming string) ?Response {
// 	vals := incoming.split_into_lines()
// 	content := vals[vals.len-1]

// 	if incoming.len == 0 {
// 		internal_err := INTERNAL_ERROR
// 		return error(internal_err.str())
// 	}

// 	if content in ['{}', ''] || vals.len < 2 {
// 		invalid_req := INVALID_REQUEST
// 		return error(invalid_req.str())
// 	}

// 	mut req := process_request(content, incoming)
// 	req.headers = http.parse_headers(incoming.split_into_lines())
// 	mut res := Response{ id: req.id }
// 	ctx := Context{res, req}

// 	if req.method in srv.procs.keys() {
// 		proc := srv.procs[req.method]
// 		res.result = proc(ctx)
// 	} else {
// 		method_nf := METHOD_NOT_FOUND
// 		return error(method_nf.str())
// 	}

// 	return res
// }

pub fn (mut srv Server) register(name string, func ProcFunc) {
	srv.procs[name] = func
}

pub fn new() Server {
	return Server{ procs: map[string]ProcFunc }
}

pub fn as_array(p string) []string {
	return p.find_between('[',']').split(',')
}

pub fn as_string(p string) string {
	return p.find_between('"', '"')
}