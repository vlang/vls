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
		completion_provider: lsp.CompletionOptions{
			// TODO: add support for comma
			trigger_characters: ['=', '.', ':']
			resolve_provider: false
		}
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
	mut builtin_files := os.ls(builtin_path) or { panic(err) }
	builtin_files = pref.should_compile_filtered_files(builtin_path, builtin_files)
	parsed_files := parser.parse_files(builtin_files, ls.base_table, pref, scope)
	ls.insert_files(parsed_files)
	unsafe {
		builtin_files.free()
		parsed_files.free()
	}
	ls.send(json.encode(result))
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
