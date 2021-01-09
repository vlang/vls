module vls

import lsp
import json
import jsonrpc
import os
import v.parser

// initialize sends the server capabilities to the client
fn (mut ls Vls) initialize(id int, params string) {
	initialize_params := json.decode(lsp.InitializeParams, params) or { panic(err) }
	mut capabilities := lsp.ServerCapabilities{
		text_document_sync: 1
		workspace_symbol_provider: true
		document_symbol_provider: true
	}
	result := jsonrpc.Response<lsp.InitializeResult>{
		id: id
		result: lsp.InitializeResult{
			capabilities: capabilities
		}
	}
	// only files are supported right now
	ls.root_path = initialize_params.root_uri
	ls.status = .initialized
	// since builtin is used frequently, they should be parsed first and only once
	scope, pref := new_scope_and_pref()
	builtin_files := os.ls(builtin_path) or { panic(err) }
	files_to_parse := pref.should_compile_filtered_files(builtin_path, builtin_files)
	mut parsed_files := parser.parse_files(files_to_parse, ls.base_table, pref, scope)
	parsed_files << ls.parse_imports(parsed_files, ls.base_table, pref, scope)
	ls.insert_files(parsed_files)
	ls.send(json.encode(result))
	unsafe {
		builtin_files.free()
		files_to_parse.free()
		parsed_files.free()
	}
}

// shutdown sets the state to shutdown but does not exit
fn (mut ls Vls) shutdown(id int) {
	ls.status = .shutdown
	result := jsonrpc.Response<string>{
		id: id
		result: 'null'
		// error: code and message set in case an exception happens during shutdown request
	}
	json.encode(result)
}

// exit stops the process
fn (ls Vls) exit() {
	// move exit to shutdown for now
	// == .shutdown => 0
	// != .shutdown => 1
	exit(int(ls.status != .shutdown))
}
