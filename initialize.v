module main

import jsonrpc
// import json
// import lsp

// method: 'initialize'
fn (mut s Vls) initialize(mut ctx jsonrpc.Context) ?string {
    // mut params := lsp.InitializeParams{}
    
    if ctx.req.params != '{}' {
        // println(ctx.req.params)
        // decoded_params := json.decode(lsp.InitializeParams, ctx.req.params) or {
        //     return error('${jsonrpc.invalid_params}')
        // }

        // params = decoded_params
    } else {
        return error('${jsonrpc.invalid_params}')
    }

    // s.send('{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"Commencing VLS..."}}')
    // s.logger.info('Client [with pid: ${params.process_id.str()} is attempting to connect with the server.')
    return '{"capabilities":{"documentSymbolProvider":true}}'
}

fn (s Vls) initialized() string {
    s.send('{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"VLS has commenced."}}')
    return ''
}

fn (s Vls) shutdown() string {
    // do nothing!
    s.send('{"jsonrpc":"2.0","method":"window/showMessage","params:{"type":3,"message":"Sending signal client that it will shutdown."}}')
    return 'nul:null'
}

fn (s Vls) exit() {
    s.send('{"jsonrpc":"2.0","method":"window/showMessage","params:{"type":3,"message":"VLS is shutting down..."}}')
    s.send('{"jsonrpc":"2.0","method":"exit"}')
    exit(0)
}