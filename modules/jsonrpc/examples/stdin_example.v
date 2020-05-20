module main

import os
import jsonrpc

fn emit_error(err_code int) Response {
	mut eres := Response{}
	eres.send_error(err_code)
    return eres
}

fn main() {
    srv := jsonrpc.new()
    srv.register('greet', fn (ctx mut Context) string {
        name := jsonrpc.as_string(ctx.req.params)
        return 'Hello, $name'
    })

    for {
        line := os.get_line()
        res := srv.exec(line) or { 
            err_code := err.int()
            eres := emit_error(err_code)
            println(eres.gen_json())
            continue
        }

        println(res.gen_json())
    }
}