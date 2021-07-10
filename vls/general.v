module vls

import lsp
import json
import jsonrpc
import os
// import v.parser
// import v.ast
import v.vmod
import runtime

const (
	completion_trigger_characters       = ['=', '.', ':', '{', ',', '(', ' ']
	signature_help_trigger_characters   = ['(']
	signature_help_retrigger_characters = [',', ' ']
)

// initialize sends the server capabilities to the client
fn (mut ls Vls) initialize(id int, params string) {
	// Show message that VLS is not yet ready!
	ls.show_message('VLS is a work-in-progress, pre-alpha language server. It may not be guaranteed to work reliably due to memory issues and other related factors. We encourage you to submit an issue if you encounter any problems.',
		.warning)

	// NB: Just to be sure just in case the panic happens
	// inside the base table.
	// ls.base_table.panic_handler = table_panic_handler
	// ls.base_table.panic_userdata = ls

	initialize_params := json.decode(lsp.InitializeParams, params) or {
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}
	// TODO: configure capabilities based on client support
	// ls.client_capabilities = initialize_params.capabilities

	ls.capabilities = lsp.ServerCapabilities{
		text_document_sync: .incremental
		completion_provider: lsp.CompletionOptions{
			resolve_provider: false
		}
		workspace_symbol_provider: Feature.workspace_symbol in ls.enabled_features
		document_symbol_provider: Feature.document_symbol in ls.enabled_features
		document_formatting_provider: Feature.formatting in ls.enabled_features
		hover_provider: Feature.hover in ls.enabled_features
		folding_range_provider: Feature.folding_range in ls.enabled_features
		definition_provider: Feature.definition in ls.enabled_features
	}

	if Feature.completion in ls.enabled_features {
		ls.capabilities.completion_provider.trigger_characters = vls.completion_trigger_characters
	}

	if Feature.signature_help in ls.enabled_features {
		ls.capabilities.signature_help_provider = lsp.SignatureHelpOptions{
			trigger_characters: vls.signature_help_trigger_characters
			retrigger_characters: vls.signature_help_retrigger_characters
		}
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

	// set up logger set to the workspace path
	ls.setup_logger(initialize_params.trace, initialize_params.client_info)

	// since builtin is used frequently, they should be parsed first and only once
	ls.process_builtin()
	ls.send(result)
}

fn (mut ls Vls) setup_logger(trace string, client_info lsp.ClientInfo) {
	meta := vmod.decode(@VMOD_FILE) or { vmod.Manifest{} }
	mut arch := 32
	if runtime.is_64bit() {
		arch += 32
	}

	// Create the file either in debug mode or when the client trace is set to verbose.
	if ls.debug || (!ls.debug && trace == 'verbose') {
		log_path := ls.log_path()
		os.rm(log_path) or {}
		ls.logger.set_logpath(log_path)
	}

	// print important info for reporting
	ls.log_message('VLS Version: $meta.version, OS: $os.user_os() $arch', .info)
	if client_info.name.len != 0 {
		ls.log_message('Client / Editor: $client_info.name $client_info.version', .info)
	} else {
		ls.log_message('Client / Editor: Unknown', .info)
	}
}

[manualfree]
fn (mut ls Vls) process_builtin() {
	mut builtin_import, _ := ls.store.add_import({
		resolved: true
		module_name: 'builtin'
		path: builtin_path
	})

	mut imports := [builtin_import]
	ls.store.import_modules(mut imports)
	ls.store.register_auto_import(builtin_import, '')
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
fn (mut ls Vls) exit() {
	// saves the log into the disk
	ls.logger.close()

	// move exit to shutdown for now
	// == .shutdown => 0
	// != .shutdown => 1
	unsafe {
		// for key, _ in ls.tables {
		// 	ls.free_table(key, '')
		// }
		// ls.base_table.free()
	}

	// Close the IO.
	ls.io.close()

	exit(int(ls.status != .shutdown))
}
