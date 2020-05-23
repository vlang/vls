module main

import jsonrpc
import lsp
import net.http
import net
import json
import os
import log

enum ConnectionType {
    tcp
    stdio
}

// TODO
struct Vls {
mut:
    connection_type ConnectionType = .stdio
    logger log.Log
    socket net.Socket
}

fn (mut s Vls) exec(incoming string) ?string {
    // s.logger.info(incoming)
    vals := incoming.split_into_lines()
	content := if vals.len != 0 { vals[vals.len-1] } else { incoming }

	if incoming.len == 0 {
        s.logger.error('INTERNAL ERROR')
		return error('${jsonrpc.INTERNAL_ERROR}')
	}

    if vals.len < 3 {
        return gen_resp_text('{"jsonrpc":"2.0","method":"window/showMessage","params":{"type":3,"message":"This is VLS speaking: It works!"}}')
    }

	if content == '{}' {
        s.logger.error('INVALID REQUEST')
		return error('${jsonrpc.INVALID_REQUEST};Content ${incoming.len} is invalid.')
	}

    // TODO: vls crashes when the rpc params is empty/void
    mut req := jsonrpc.process_request(content)
    mut res := jsonrpc.Response{ id: req.id, result: '' }
    mut ctx := jsonrpc.Context{ res, req }

    match req.method {
        'initialize' { 
            init_result := s.initialize(mut ctx) or { 
                return error(err)
            }

            res.result = init_result
        }
        'initialized' { res.result  = s.initialized() }
        'shutdown' { res.result = s.shutdown() }
        'exit' { s.exit() }
        else { return error('${jsonrpc.METHOD_NOT_FOUND}') }
    }

    return res.gen_resp_text()
}

fn (s Vls) error(err string) {
    // error message has two parts and is separated by a comma
    // first part is the status code
    // second is the error data
    err_resp := err.split(';')
    err_code := err_resp[0].int()
    err_data := if err_resp.len > 1 { err_resp[1..].join(';') } else { '' }
    mut eres := jsonrpc.Response{}
    eres.error = jsonrpc.ResponseError{ 
		code: err_code,
        // data: jsonrpc.serialize_str_data(err_data)
		message: jsonrpc.err_message(err_code)
	}
    os.write_file('./vls.log', err_data)
    s.send(eres.gen_resp_text())
}

fn (s Vls) send(content string) {
    data := gen_resp_text(content)    

    if s.connection_type == .tcp {
        s.socket.write(data) or { return }
        s.socket.close() or { return }
    } else {
        print(data)
    }
}

fn gen_resp_text(jsstring string) string {
    return 'Content-Length: ${jsstring.len}\r\n\r\n${jsstring}'
}

fn get_content_len(clstr string) int {
    return clstr.all_after('Content-Length: ').int()
}

fn (mut s Vls) start_tcp(port int) {
    s.connection_type = .tcp
    server := net.listen(port) or {
        panic(err)
    }

    for {
        con := server.accept() or {
            server.close() or {}
            panic(err)
        }

        s.socket = con
        defer { s.socket.close() or {} }
        // get content-length
        mut req := s.socket.read_line()
        mut content_len := 0
        expected_content_len := get_content_len(req)
        
        println('expected content length: $expected_content_len')
        // advance
        req += s.socket.read_line()
        
        for content_len < expected_content_len {
            content := s.socket.read_line()
            content_len += content.len
            req += content.trim_right('\r\n')
        }

        println(req)
        
        s.exec(req) or {
            s.error(err)
            continue
        }
    }
}

fn (mut s Vls) start_stdio() {
    s.connection_type = .stdio

    $if windows {
        C._setmode(C._fileno(C.stdin), 0x8000)
        C._setmode(C._fileno(C.stdout), 0x8000)
    }

    // handling stdins are harder than u think
    // stdins are streams which are messy and not in order
    mut incoming := ''
    mut expected_len := 0
    mut waiting := ''

    if !os.exists('./vls_input.log') {
        os.create('./vls_input.log') or {
            panic(err)
        }
    }

    for {
        mut line := os.get_raw_line()
        line += os.get_raw_line()
        // if line.starts_with('Content-Length: ') {
        //     incoming = line
        //     expected_len = line.all_after('Content-Length: ').int()
        //     n++
        // }

        // if line == '\r\n' {
        //     incoming += line
        //     n++
        // }

        // if line[0] == `{` {
        //     if line.len > expected_len {
        //         incoming = incoming + line[..expected_len]
        //         waiting = line[expected_len..]
        //     } else {
        //         incoming = incoming + line
        //     }
        // }
        
        stdin_log := os.read_file('./vls_input.log') or { break }
        os.write_file('./vls_input.log', stdin_log + '\n' + line)
        // stdout_log := os.read_file('./vls_output.log') or { continue }
        // os.write_file('./vls_output.log', stdout_log + '\n' + incoming)

        s.send('{"jsonrpc":"2.0","method":"window/showMessage","params":{"type":3,"message":"This is VLS speaking: It works!"}}')

    }
}

fn main() {
    // TODO STDIO focus on TCP first.
    mut s := Vls{}

    if '-tcp' in os.args {
        println('starting vls in tcp')
        s.start_tcp(23556)
    } else {
        s.start_stdio()
    }
}