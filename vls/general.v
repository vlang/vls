module vls

import lsp
import json
import jsonrpc
import os
import v.parser
import v.ast

const (
	completion_trigger_characters = ['=', '.', ':', '{', ',', '(', ' ']
)

// initialize sends the server capabilities to the client.
fn (mut ls Vls) initialize(id int, params string) {
	initialize_params := json.decode(lsp.InitializeParams, params) or { panic(err) }
	// TODO: configure capabilities based on client support
	// ls.client_capabilities = initialize_params.capabilities
	ls.capabilities = lsp.ServerCapabilities{
		text_document_sync: 1
		completion_provider: lsp.CompletionOptions{
			resolve_provider: false
		}
		workspace_symbol_provider: Feature.workspace_symbol in ls.enabled_features
		document_symbol_provider: Feature.document_symbol in ls.enabled_features
		document_formatting_provider: Feature.formatting in ls.enabled_features
	}

	if Feature.completion in ls.enabled_features {
		ls.capabilities.completion_provider.trigger_characters = vls.completion_trigger_characters
	}

	result := jsonrpc.Response<lsp.InitializeResult>{
		id: id
		result: lsp.InitializeResult{
			capabilities: ls.capabilities
		}
	}
	// only files are supported right now
	ls.root_uri = initialize_params.root_uri
	ls.status = .initialized
	// since builtin is used frequently, they should be parsed first and only once
	ls.process_builtin()
	ls.send(result)
}

// process_builtin imports the builtin module, extracts its symbols, and uses its data
// as the base for the base table to be used later when a file is parsed.
fn (mut ls Vls) process_builtin() {
	scope, pref := new_scope_and_pref()
	mut builtin_files := os.ls(builtin_path) or { panic(err) }
	builtin_files = pref.should_compile_filtered_files(builtin_path, builtin_files)
	parsed_files := parser.parse_files(builtin_files, ls.base_table, pref, scope)
	// This part extracts the symbols for the builtin module
	// for use in autocompletion. This is disabled in test mode in
	// order to simplify the testing output in autocompletion test.
	$if !test {
		for file in parsed_files {
			for stmt in file.stmts {
				if stmt is ast.FnDecl {
					if !stmt.is_pub || stmt.is_method {
						continue
					}
					ls.builtin_symbols << stmt.name
				}
			}
		}
	}
	unsafe {
		builtin_files.free()
		parsed_files.free()
	}
}

// shutdown sets the state to shutdown but does not exit.
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
