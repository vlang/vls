module server

import lsp
import json
import jsonrpc
import os
import analyzer
import runtime

const (
	completion_trigger_characters       = ['=', '.', ':', '{', ',', '(', ' ']
	signature_help_trigger_characters   = ['(']
	signature_help_retrigger_characters = [',', ' ']
)

// initialize sends the server capabilities to the client
fn (mut ls Vls) initialize(id string, params string) {
	initialize_params := json.decode(lsp.InitializeParams, params) or {
		ls.panic(err.msg())
		ls.send_null(id)
		return
	}

	// If the parent process is not alive, then the server should exit
	// (see exit notification) its process.
	// https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#initialize
	if initialize_params.process_id != -2 && !is_proc_exists(initialize_params.process_id) {
		ls.exit()
	}

	ls.client_pid = initialize_params.process_id

	// Set defaults when vroot_path is empty
	if ls.vroot_path.len == 0 {
		if found_vroot_path := detect_vroot_path() {
			ls.set_vroot_path(found_vroot_path)
			ls.store.default_import_paths << os.join_path(found_vroot_path, 'vlib')
			ls.store.default_import_paths << os.vmodules_dir()
		} else {
			ls.show_message("V installation directory was not found. Modules in vlib such as `os` won't be detected.",
				.error)
		}
	} else {
		ls.store.default_import_paths << os.join_path(ls.vroot_path, 'vlib')
		ls.store.default_import_paths << os.vmodules_dir()
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
		implementation_provider: Feature.implementation in ls.enabled_features
	}

	if Feature.completion in ls.enabled_features {
		ls.capabilities.completion_provider.trigger_characters = server.completion_trigger_characters
	}

	if Feature.signature_help in ls.enabled_features {
		ls.capabilities.signature_help_provider = lsp.SignatureHelpOptions{
			trigger_characters: server.signature_help_trigger_characters
			retrigger_characters: server.signature_help_retrigger_characters
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

	// Create the file either in debug mode or when the client trace is set to verbose.
	if ls.debug || (!ls.debug && initialize_params.trace == 'verbose') {
		// set up logger set to the workspace path
		ls.setup_logger() or { ls.show_message(err.msg(), .error) }
	}

	// print initial info
	ls.print_info(initialize_params.process_id, initialize_params.client_info)

	// since builtin is used frequently, they should be parsed first and only once
	ls.process_builtin()
	ls.send(result)
}

fn (mut ls Vls) setup_logger() ?string {
	log_path := ls.log_path()
	if os.exists(log_path) {
		os.rm(log_path) or {}
	}

	ls.logger.set_logpath(log_path) or {
		sanitized_root_uri := ls.root_uri.path().replace_each(['/', '_', ':', '_', '\\', '_'])
		alt_log_path := os.join_path(os.home_dir(), 'vls__${sanitized_root_uri}.log')
		ls.show_message('Cannot save log to ${log_path}. Saving log to $alt_log_path',
			.error)

		// avoid saving log path in test
		$if !test {
			ls.logger.set_logpath(alt_log_path) or {
				return error('Cannot save log to $alt_log_path')
			}
		}

		return alt_log_path
	}

	return log_path
}

fn (mut ls Vls) print_info(process_id int, client_info lsp.ClientInfo) {
	arch := if runtime.is_64bit() { 64 } else { 32 }
	client_name := if client_info.name.len != 0 {
		'$client_info.name $client_info.version'
	} else {
		'Unknown'
	}

	// print important info for reporting
	ls.log_message('VLS Version: $meta.version, OS: $os.user_os() $arch', .info)
	ls.log_message('VLS executable path: $os.executable()', .info)
	ls.log_message('VLS build with V ${@VHASH}', .info)
	ls.log_message('Client / Editor: $client_name (PID: $process_id)', .info)
	ls.log_message('Using V path (VROOT): $ls.vroot_path', .info)
}

fn (mut ls Vls) process_builtin() {
	mut builtin_import, _ := ls.store.add_import(
		resolved: true
		module_name: 'builtin'
		path: os.join_path(ls.vroot_path, 'vlib', 'builtin')
	)

	mut imports := [builtin_import]
	ls.store.register_auto_import(builtin_import, '')
	analyzer.register_builtin_symbols(mut ls.store, builtin_import)
	ls.store.import_modules(mut imports)
}

// shutdown sets the state to shutdown but does not exit
[noreturn]
fn (mut ls Vls) shutdown(id string) {
	ls.status = .shutdown
	if id.len != 0 {
		ls.send(jsonrpc.Response<string>{
			id: id
			result: 'null'
			// error: code and message set in case an exception happens during shutdown request
		})
	}
	ls.exit()
}

// exit stops the process
[noreturn]
fn (mut ls Vls) exit() {
	// saves the log into the disk
	ls.logger.close()
	ls.typing_ch.close()

	// move exit to shutdown for now
	// == .shutdown => 0
	// != .shutdown => 1
	exit(int(ls.status != .shutdown))
}
