module vls

import lsp
import json
import jsonrpc

// initialize sends the server capabilities to the client
fn (mut ls Vls) initialize(id int, params string) {
	initialize_params := json.decode(lsp.InitializeParams, params) or { panic(err) }
	mut capabilities := lsp.ServerCapabilities{
		text_document_sync: 1
	}
	result := jsonrpc.Response<lsp.InitializeResult>{
		id: id
		result: lsp.InitializeResult{
			capabilities: capabilities
		}
	}
	// only files are supported right now
	ls.root_path = initialize_params.root_uri.path()
	ls.status = .initialized
	ls.send(json.encode(result))
}

// shutdown sets the state to shutdown but does not exit
fn (mut ls Vls) shutdown(params string) {
	ls.status = .shutdown
}

// exit stops the process
fn (ls Vls) exit(params string) {
	// move exit to shutdown for now
	// == .shutdown => 0
	// != .shutdown => 1
	exit(int(ls.status != .shutdown))
}
