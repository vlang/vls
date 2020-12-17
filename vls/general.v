module vls

import lsp
import json
import jsonrpc

// initialize sends the server capabilities to the client
fn (mut ls Vls) initialize(id int, params string) {
	initialize_params := json.decode(lsp.InitializeParams, params) or { panic(err) }
	mut capabilities := lsp.ServerCapabilities{
		text_document_sync: 1
		workspace_symbol_provider: true
		document_symbol_provider: true
		completion_provider: lsp.CompletionOptions{
			resolve_provider: false
		}
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

struct NullResponse {
	jsonrpc string = jsonrpc.version
	id      int
	result  string = 'null'
}

// shutdown sets the state to shutdown but does not exit
fn (mut ls Vls) shutdown(id int, params string) {
	ls.status = .shutdown
	result := NullResponse{
		id: id
		// error: code and message set in case an exception happens during shutdown request
	}
	ls.send(json.encode(result))
	unsafe {
		// ls.projects.free()
		ls.mod_import_paths.free()
		ls.import_graph.free()
		ls.mod_docs.free()
	}
}

// exit stops the process
fn (ls Vls) exit(params string) {
	// move exit to shutdown for now
	// == .shutdown => 0
	// != .shutdown => 1
	exit(int(ls.status != .shutdown))
}
