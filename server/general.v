module server

import lsp
import lsp.log { LogRecorder }
import jsonrpc
import os
import analyzer
import runtime

const (
	completion_trigger_characters       = ['=', '.', ':', '{', ',', '(', ' ']
	signature_help_trigger_characters   = ['(']
	signature_help_retrigger_characters = [',', ' ']
)

const features_require_v_tool = ['v_diagnostics', 'formatting']

// initialize sends the server capabilities to the client
pub fn (mut ls Vls) initialize(params lsp.InitializeParams, mut wr ResponseWriter) lsp.InitializeResult {
	// If the parent process is not alive, then the server should exit
	// (see exit notification) its process.
	// https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#initialize
	if params.process_id != -2 && !is_proc_exists(params.process_id) {
		ls.exit(mut wr)
	}

	ls.client_pid = params.process_id

	// Set defaults when vroot_path is empty
	if ls.vroot_path.len == 0 {
		if found_vroot_path := detect_vroot_path() {
			ls.set_vroot_path(found_vroot_path)
			ls.store.default_import_paths << os.join_path(found_vroot_path, 'vlib')
			ls.store.default_import_paths << os.vmodules_dir()
		} else {
			// avoid process launch fails when VROOT does not exist
			ls.set_features(features_require_v_tool, false) or {}
			wr.show_message("V installation directory was not found. Some of the features won't work properly.",
				.error)
		}
	} else {
		ls.store.default_import_paths << os.join_path(ls.vroot_path, 'vlib')
		ls.store.default_import_paths << os.vmodules_dir()
	}

	// TODO: configure capabilities based on client support
	// ls.client_capabilities = params.capabilities

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

	// only files are supported right now
	ls.root_uri = params.root_uri
	ls.status = .initialized

	is_debug := jsonrpc.is_interceptor_enabled<LogRecorder>(wr.server)

	// Create the file either in debug mode or when the client trace is set to verbose.
	if is_debug || (!is_debug && params.trace == 'verbose') {
		// set up logger set to the workspace path
		ls.setup_logger(mut wr) or { wr.show_message(err.msg(), .error) }
	}

	// print initial info
	ls.print_info(params.process_id, params.client_info, mut wr)

	// since builtin is used frequently, they should be parsed first and only once
	analyzer.setup_builtin(mut ls.store, os.join_path(ls.vroot_path, 'vlib', 'builtin'))

	return lsp.InitializeResult{
		capabilities: ls.capabilities
	}
}

fn (mut ls Vls) setup_logger(mut rw ResponseWriter) ?string {
	log_path := ls.log_path()
	if os.exists(log_path) {
		os.rm(log_path) or {}
	}

	rw.server.dispatch_event(log.set_logpath_event, log_path) or {
		sanitized_root_uri := ls.root_uri.path().replace_each(['/', '_', ':', '_', '\\', '_'])
		logs_dir_path := os.join_path(get_folder_path(), 'logs')
		if !os.exists(logs_dir_path) {
			os.mkdir(logs_dir_path)?
		}

		alt_log_path := os.join_path(logs_dir_path, 'vls__${sanitized_root_uri}.log')
		rw.show_message('Cannot save log to ${log_path}. Saving log to $alt_log_path',
			.error)

		// avoid saving log path in test
		$if !test {
			rw.server.dispatch_event(log.set_logpath_event, alt_log_path) or {
				return error('Cannot save log to $alt_log_path')
			}
		}

		return alt_log_path
	}

	return log_path
}

fn (mut ls Vls) print_info(process_id int, client_info lsp.ClientInfo, mut wr ResponseWriter) {
	arch := if runtime.is_64bit() { 64 } else { 32 }
	client_name := if client_info.name.len != 0 {
		'$client_info.name $client_info.version'
	} else {
		'Unknown'
	}

	// print important info for reporting
	wr.log_message('VLS Version: $meta.version, OS: $os.user_os() $arch', .info)
	wr.log_message('VLS executable path: $os.executable()', .info)
	wr.log_message('VLS build with V ${@VHASH}', .info)
	wr.log_message('Client / Editor: $client_name (PID: $process_id)', .info)
	wr.log_message('Using V path (VROOT): $ls.vroot_path', .info)
}

// shutdown sets the state to shutdown but does not exit
[noreturn]
pub fn (mut ls Vls) shutdown(mut wr ResponseWriter) {
	ls.status = .shutdown
	if wr.req_id.len != 0 {
		// error: code and message set in case an exception happens during shutdown request
		wr.write(jsonrpc.null)
	}
	ls.exit(mut wr)
}

// exit stops the process
[noreturn]
pub fn (mut ls Vls) exit(mut rw ResponseWriter) {
	// saves the log into the disk
	rw.server.dispatch_event(log.close_event, '') or {}
	ls.typing_ch.close()

	// move exit to shutdown for now
	// == .shutdown => 0
	// != .shutdown => 1
	exit(int(ls.status != .shutdown))
}
