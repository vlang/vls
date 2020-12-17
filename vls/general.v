module vls

import lsp
import json
import jsonrpc
import os
import v.parser
import v.pref
import v.ast

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

	// since builtin is used frequently, they should be parsed first and only once
	scope := ast.Scope{
		parent: 0
	}

	pref := pref.Preferences{
		output_mode: .silent
		backend: .c
		os: ._auto
		lookup_path: [
			vlib_path,
			vmodules_path
		]
	}

	builtin_files := os.ls(builtin_path) or { panic(err) }
	files_to_parse := pref.should_compile_filtered_files(builtin_path, builtin_files)
	parsed_builtin_files := parser.parse_files(files_to_parse, ls.base_table, &pref, &scope)
	ls.extract_symbols(parsed_builtin_files, ls.base_table)
	ls.insert_files(parsed_builtin_files)
	ls.parse_imports(parsed_builtin_files, ls.base_table, &pref, &scope)
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
