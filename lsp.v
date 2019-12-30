module main

import (
	vargs
	os
	json
)

struct Lsp {
	file string
mut:
	computed Computed
	init InitializeParams
}

struct PrintMessageParams {
	name string
	custom_message string
}

fn process_server(ctx ServerContext) string {
	req := ctx.req
	mut output := ''

	if req.method == 'test/printMessage' {
		params := json.decode(PrintMessageParams, req.params) or {
			eprintln('Failed to decode')
			return ''
		}

		output = 'Hello, ${params.name}! ${params.custom_message}'
	}

	return output
}

fn main() {
	_args := vargs.parse(os.args, 1)

	// server_port := if 'port' in _args.options { _args.options['port'].int() } else { 8042 } 

	// mut srv := new_jsonrpc_server()
	// srv.start_and_listen(process_server, server_port)

	lsp := Lsp{os.args[1], Computed{}, InitializeParams{}}
	lsp.analyze()
}