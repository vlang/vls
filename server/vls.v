module server

import json
import jsonrpc
import lsp
import lsp.log
import os
import tree_sitter
import tree_sitter_v as v
import analyzer
import time
import v.vmod
import strings

pub const meta = meta_info()

fn meta_info() vmod.Manifest {
	parsed := vmod.decode(@VMOD_FILE) or { panic(err) }
	build_commit := $if with_build_commit ? { '-' + $env('VLS_BUILD_COMMIT') } $else { '' }
	return vmod.Manifest{
		...parsed
		version: parsed.version + build_commit
	}
}

// These are the list of features available in VLS
// If the feature is experimental, the value name should have a `exp_` prefix
pub enum Feature {
	diagnostics
	formatting
	document_symbol
	workspace_symbol
	signature_help
	completion
	hover
	folding_range
	definition
	implementation
}

// feature_from_str returns the Feature-enum value equivalent of the given string.
// used internally for Vls.set_features method only.
fn feature_from_str(feature_name string) ?Feature {
	match feature_name {
		'diagnostics' { return Feature.diagnostics }
		'formatting' { return Feature.formatting }
		'document_symbol' { return Feature.document_symbol }
		'workspace_symbol' { return Feature.workspace_symbol }
		'signature_help' { return Feature.signature_help }
		'completion' { return Feature.completion }
		'hover' { return Feature.hover }
		'folding_range' { return Feature.folding_range }
		'definition' { return Feature.definition }
		else { return error('feature "$feature_name" not found') }
	}
}

pub const (
	default_features_list = [
		Feature.diagnostics,
		.formatting,
		.document_symbol,
		.workspace_symbol,
		.signature_help,
		.completion,
		.hover,
		.folding_range,
		.definition,
		.implementation,
	]
)

interface ReceiveSender {
	debug bool
	init() ?
	send(data string)
	receive() ?string
}

struct Vls {
mut:
	vroot_path       string
	parser           &C.TSParser
	store            analyzer.Store
	status           ServerStatus = .off
	sources          map[string]File
	trees            map[string]&C.TSTree
	root_uri         lsp.DocumentUri
	is_typing        bool
	typing_ch        chan int
	enabled_features []Feature = server.default_features_list
	capabilities     lsp.ServerCapabilities
	logger           log.Logger
	panic_count      int
	debug            bool
	// client_capabilities lsp.ClientCapabilities
pub mut:
	// TODO: replace with io.ReadWriter
	io ReceiveSender
}

pub fn new(io ReceiveSender) Vls {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)

	inst := Vls{
		io: io
		parser: parser
		debug: io.debug
		logger: log.new(.text)
		store: analyzer.Store{}
	}

	$if test {
		inst.typing_ch.close()
	}

	return inst
}

pub fn (mut ls Vls) dispatch(payload string) {
	request := json.decode(jsonrpc.Request, payload) or {
		ls.send(new_error(jsonrpc.parse_error, ''))
		return
	}
	// The server will log a send request/notification
	// log based on the the received payload since the spec
	// doesn't indicate a way to log on the client side and
	// notify it to the server.
	//
	// Notification has no ID attached so the server can detect
	// if its a notification or a request payload by checking
	// if the ID is empty.
	if request.id.len == 0 {
		ls.logger.notification(payload, .receive)
	} else {
		ls.logger.request(payload, .receive)
	}
	if ls.status == .initialized {
		match request.method {
			// not only requests but also notifications
			'initialized' {} // does nothing currently
			'shutdown' {
				// NB: Some users reported that after closing their text editors,
				// the vls process isn't properly closed at all and the editor still
				// continuously sending useless requests during the shutdown phase
				// which dramatically increases the memory. Unless there is a fix
				// or other possible alternatives, the solution for now is to
				// immediately exit when the server receives a shutdown request.
				// Freeing extra memory here
				ls.exit()
				// ls.shutdown(request.id)
			}
			'exit' {
				// ignore for the reasons stated in the above comment
			}
			'textDocument/didOpen' {
				ls.did_open(request.id, request.params)
			}
			'textDocument/didSave' {
				ls.did_save(request.id, request.params)
			}
			'textDocument/didChange' {
				ls.typing_ch <- 1
				ls.did_change(request.id, request.params)
			}
			'textDocument/didClose' {
				ls.did_close(request.id, request.params)
			}
			'textDocument/formatting' {
				ls.formatting(request.id, request.params)
			}
			'textDocument/documentSymbol' {
				ls.document_symbol(request.id, request.params)
			}
			'workspace/symbol' {
				ls.workspace_symbol(request.id, request.params)
			}
			'textDocument/signatureHelp' {
				ls.signature_help(request.id, request.params)
			}
			'textDocument/completion' {
				ls.completion(request.id, request.params)
			}
			'textDocument/hover' {
				ls.hover(request.id, request.params)
			}
			'textDocument/foldingRange' {
				ls.folding_range(request.id, request.params)
			}
			'textDocument/definition' {
				ls.definition(request.id, request.params)
			}
			'textDocument/implementation' {
				ls.implementation(request.id, request.params)
			}
			else {}
		}
	} else {
		match request.method {
			'exit' {
				ls.exit()
			}
			'initialize' {
				ls.initialize(request.id, request.params)
			}
			else {
				err_type := if ls.status == .shutdown {
					jsonrpc.invalid_request
				} else {
					jsonrpc.server_not_initialized
				}
				ls.send(new_error(err_type, request.id))
			}
		}
	}
}

// set_vroot_path changes the path of the V root directory
pub fn (mut ls Vls) set_vroot_path(new_vroot_path string) {
	unsafe { ls.vroot_path.free() }
	ls.vroot_path = new_vroot_path
}

// set_logger changes the language server's logger
pub fn (mut ls Vls) set_logger(logger log.Logger) {
	ls.logger.close()
	ls.logger = logger
}

// capabilities returns the current server capabilities
pub fn (ls Vls) capabilities() lsp.ServerCapabilities {
	return ls.capabilities
}

// features returns the current server features enabled
pub fn (ls Vls) features() []Feature {
	return ls.enabled_features
}

// status returns the current server status
pub fn (ls Vls) status() ServerStatus {
	return ls.status
}

// log_path returns the combined path of the workspace's root URI and the log file name.
fn (ls Vls) log_path() string {
	return os.join_path(ls.root_uri.path(), 'vls.log')
}

// panic generates a log report and exits the language server.
fn (mut ls Vls) panic(message string) {
	ls.panic_count++

	// NB: Would 2 be enough to exit?
	if ls.panic_count == 2 {
		log_path := ls.log_path()
		ls.logger.set_logpath(log_path)
		ls.show_message('VLS Panic: ${message}. Log saved to ${os.real_path(log_path)}. Please refer to https://github.com/vlang/vls#error-reporting for more details.',
			.error)
		ls.logger.close()
		ls.exit()
	} else {
		ls.log_message('VLS: An error occurred. Message: $message', .error)
	}
}

fn (mut ls Vls) send<T>(resp jsonrpc.Response<T>) {
	mut resp_wr := strings.new_builder(100)
	defer { unsafe { resp_wr.free() } }
	resp_wr.write_string('{"jsonrpc":"${jsonrpc.version}","id":${resp.id}')
	if resp.id.len == 0 {
		resp_wr.write_string('null')
	}
	if resp.error.code != 0 {
		err := json.encode(resp.error)
		resp_wr.write_string(',"error":${err}')
	} else {
		res := json.encode(resp.result)
		resp_wr.write_string(',"result":${res}')
	}
	resp_wr.write_b(`}`)
	str := resp_wr.str()
	ls.logger.response(str, .send)
	ls.io.send(str)
}

// notify sends a notification to the client
fn (mut ls Vls) notify<T>(data jsonrpc.NotificationMessage<T>) {
	str := json.encode(data)
	ls.logger.notification(str, .send)
	ls.io.send(str)
}

// send_null sends a null result to the client
fn (mut ls Vls) send_null(id string) {
	str := '{"jsonrpc":"${jsonrpc.version}","id":$id,"result":null}'
	ls.logger.response(str, .send)
	ls.io.send(str)
}

fn monitor_changes(mut ls Vls) {
	// This is for debouncing analysis
	for {
		select {
			a := <-ls.typing_ch {
				ls.is_typing = a != 0
			}
			50 * time.millisecond {
				if !ls.is_typing {
					continue
				}

				uri := lsp.document_uri_from_path(ls.store.cur_file_path)
				analyze(mut ls.store, ls.root_uri, ls.trees[uri], ls.sources[uri])
				ls.is_typing = false
				ls.show_diagnostics(uri)
				unsafe { uri.free() }
			}
		}
	}
}

// start_loop starts an endless loop which waits for stdin and prints responses to the stdout
pub fn (mut ls Vls) start_loop() {
	go monitor_changes(mut ls)
	ls.io.init() or { panic(err) }

		// Show message that VLS is not yet ready!
	ls.show_message('VLS is a work-in-progress, pre-alpha language server. It may not be guaranteed to work reliably due to memory issues and other related factors. We encourage you to submit an issue if you encounter any problems.',
		.warning)

	for {
		payload := ls.io.receive() or { continue }
		ls.dispatch(payload)
	}
}

// set_features enables or disables a language feature. emits an error if not found
pub fn (mut ls Vls) set_features(features []string, enable bool) ? {
	for feature_name in features {
		feature_val := feature_from_str(feature_name) ?
		if feature_val !in ls.enabled_features && !enable {
			return error('feature "$feature_name" is already disabled')
		} else if feature_val in ls.enabled_features && enable {
			return error('feature "$feature_name" is already enabled')
		} else if feature_val !in ls.enabled_features && enable {
			ls.enabled_features << feature_val
		} else {
			mut idx := -1
			for i, f in ls.enabled_features {
				if f == feature_val {
					idx = i
					break
				}
			}
			ls.enabled_features.delete(idx)
		}
	}
}

pub fn (ls Vls) launch_v_tool(args ...string) &os.Process {
	mut v_exe_name := 'v'
	defer {
		unsafe { v_exe_name.free() }
	}

	$if windows {
		v_exe_name += '.exe'
	}

	full_v_path := os.join_path(ls.vroot_path, v_exe_name)
	mut p := os.new_process(full_v_path)
	p.set_args(args)
	p.set_redirect_stdio()
	return p
}

pub enum ServerStatus {
	off
	initialized
	shutdown
}

[inline]
fn new_error(code int, id string) jsonrpc.Response<string> {
	return jsonrpc.Response<string>{
		id: id
		error: jsonrpc.new_response_error(code)
	}
}

pub fn detect_vroot_path() ?string {
	vroot_env := os.getenv('VROOT')
	if vroot_env.len != 0 {
		return vroot_env
	}

	vexe_path_from_env := os.getenv('VEXE')
	defer {
		unsafe {
			vroot_env.free()
			vexe_path_from_env.free()
		}
	}

	// Return the directory of VEXE if present
	if vexe_path_from_env.len != 0 {
		return os.dir(vexe_path_from_env)
	}

	// Find the V executable in PATH
	path_env := os.getenv('PATH')
	paths := path_env.split(path_list_sep)
	defer {
		unsafe {
			vexe_path_from_env.free()
			paths.free()
		}
	}

	for path in paths {
		full_path := os.join_path(path, v_exec_name)
		if os.exists(full_path) && os.is_executable(full_path) {
			defer {
				unsafe { full_path.free() }
			}
			if os.is_link(full_path) {
				// Get the real path of the V executable
				full_real_path := os.real_path(full_path)
				defer {
					unsafe { full_real_path.free() }
				}
				return os.dir(full_real_path)
			} else {
				return os.dir(full_path)
			}
		}
		unsafe { full_path.free() }
	}

	return error('V path not found.')
}
