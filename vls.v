module main

import jsonrpc
import lsp
import net.http
import json
import os
import log

// TODO
struct Vls {
mut:
    logger log.Log = log.Log{}
    root_uri string
}

fn (s mut Vls) exec(incoming string) ?string {
    s.logger.info(incoming)
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
	req.headers = http.parse_headers(vals)
    mut res := jsonrpc.Response{ id: req.id, result: '' }
    mut ctx := jsonrpc.Context{ res, req }

    match req.method {
        'initialize' { 
            init_result := s.initialize(mut ctx) or { return error(err) }
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
    print(eres.gen_resp_text())
}

fn gen_resp_text(jsstring string) string {
    return 'Content-Length: ${jsstring.len}\r\n\r\n${jsstring}'
}

fn main() {
    mut s := Vls{}
    s.logger.set_level(.info)
    s.logger.set_full_logpath('./vls.log')
    for {
        raw := os.get_raw_line()
        rpcreq := raw.replace('\\r\\n', '\r\n')
        resp := s.exec(rpcreq) or {
            s.error(err)
            continue
        }
        stdin_log := os.read_file('./vls_input.log') or { continue }
        os.write_file('./vls_input.log', stdin_log + '\n' + raw)
        stdout_log := os.read_file('./vls_output.log') or { continue }
        os.write_file('./vls_output.log', stdout_log + '\n' + resp)

        print(resp)
    }
}