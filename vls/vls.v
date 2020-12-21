module vls

import v.table
import v.ast
import v.pref
import json
import jsonrpc
import lsp

interface ReceiveSender {
	send(data string)
	receive() ?string
}

struct Vls {
mut:
	// NB: a base table is required since this is where we
	// are gonna store the information for the builtin types
	// which are only parsed once.
	base_table &table.Table
	status     ServerStatus = .off
	// TODO: change map key to DocumentUri
	// files  map[DocumentUri]ast.File
	files      map[string]ast.File
	// sources  map[DocumentUri]string
	sources    map[string]string
	// NB: a separate table is required for each folder in
	// order to do functions such as typ_to_string or when
	// some of the features needed additional information
	// that is mostly stored into the table.
	//
	// A single table is not feasible since files are always
	// changing and there can be instances that a change might
	// break another module/project data.
	// tables  map[DocumentUri]&table.Table
	tables     map[string]&table.Table
	root_path  lsp.DocumentUri
	symbols						map[string]&ast.Stmt
	cached_completion []lsp.CompletionItem
pub mut:
	// TODO: replace with io.ReadWriter
	io         ReceiveSender
}

pub fn new(io ReceiveSender) Vls {
	mut tbl := table.new_table()
	tbl.is_fmt = false
	return Vls{
		io: io
		base_table: tbl
	}
}

pub fn (mut ls Vls) execute(payload string) {
	request := json.decode(jsonrpc.Request, payload) or {
		ls.send(new_error(jsonrpc.parse_error))
		return
	}
	if request.method != 'exit' && ls.status == .shutdown {
		ls.send(new_error(jsonrpc.invalid_request))
		return
	}
	if request.method != 'initialize' && ls.status != .initialized {
		ls.send(new_error(jsonrpc.server_not_initialized))
		return
	}
	match request.method {
		'initialize' {
			ls.initialize(request.id, request.params)
		}
		'initialized' {} // does nothing currently
		'shutdown' {
			ls.shutdown(request.params)
		}
		'exit' {
			ls.exit(request.params)
		}
		'textDocument/didOpen' {
			ls.did_open(request.id, request.params)
		}
		'textDocument/didChange' {
			ls.did_change(request.id, request.params)
		}
		'textDocument/didClose' {
			ls.did_close(request.id, request.params)
		}
		'textDocument/formatting' {
			ls.formatting(request.id, request.params)
		}
		'textDocument/completion' {
			ls.completion(request.id, request.params)
		}
		else {
			if ls.status != .initialized {
				ls.send(new_error(jsonrpc.server_not_initialized))
			}
		}
	}
}

// status returns the current server status
pub fn (ls Vls) status() ServerStatus {
	return ls.status
}

// TODO: fn (ls Vls) send<T>(data T) {
fn (ls Vls) send(data string) {
	ls.io.send(data)
}

// start_loop starts an endless loop which waits for stdin and prints responses to the stdout
pub fn (mut ls Vls) start_loop() {
	for {
		payload := ls.io.receive() or { continue }
		ls.execute(payload)
	}
}

// new_scope_and_pref returns a new instance of scope and pref based on the given lookup paths
fn new_scope_and_pref(lookup_paths ...string) (&ast.Scope, &pref.Preferences) {
	mut lpaths := [vlib_path, vmodules_path]
	for i := lookup_paths.len - 1; i >= 0; i-- {
		lookup_path := lookup_paths[i]
		lpaths.prepend(lookup_path)
	}
	scope := &ast.Scope{
		parent: 0
	}
	prefs := &pref.Preferences{
		output_mode: .silent
		backend: .c
		os: ._auto
		lookup_path: lpaths
	}
	return scope, prefs
}

// extract_symbols extracts the top-level statements and stores them into ls.symbols for quick access
fn (mut ls Vls) extract_symbols(parsed_files []ast.File, table &table.Table, pub_only bool) {
	for file in parsed_files {
		for stmt in file.stmts {
			if stmt is ast.FnDecl {
				if stmt.is_method {
					continue
				}
			}
			mut name := ''
			match stmt {
				ast.InterfaceDecl,
				ast.StructDecl,
				ast.EnumDecl,
				ast.FnDecl {
					if pub_only && !stmt.is_pub {
						continue
					}
					name = stmt.name
				}
				else { continue }
			}
			ls.symbols[name] = stmt
		}
	}
}

// insert_files inserts an array file asts onto the ls.files map
fn (mut ls Vls) insert_files(files []ast.File) {
	for file in files {
		file_uri := lsp.document_uri_from_path(file.path)
		if file_uri in ls.files {
			ls.files.delete(file_uri)
		}
		ls.files[file_uri.str()] = file
		unsafe {
			file_uri.free()
		}
	}
}

// new_table returns a new table based on the existing data of base_table
fn (ls Vls) new_table() &table.Table {
	mut tbl := table.new_table()
	tbl.types = ls.base_table.types.clone()
	tbl.type_idxs = ls.base_table.type_idxs.clone()
	tbl.fns = ls.base_table.fns.clone()
	tbl.imports = ls.base_table.imports.clone()
	tbl.modules = ls.base_table.modules.clone()
	tbl.cflags = ls.base_table.cflags.clone()
	tbl.redefined_fns = ls.base_table.redefined_fns.clone()
	tbl.fn_gen_types = ls.base_table.fn_gen_types.clone()
	tbl.cmod_prefix = ls.base_table.cmod_prefix
	tbl.is_fmt = ls.base_table.is_fmt
	return tbl
}

pub enum ServerStatus {
	off
	initialized
	shutdown
}

// with error
struct JrpcResponse2 <T> {
	jsonrpc string = jsonrpc.version
	id      int
	error   jsonrpc.ResponseError
	result  T
}

[inline]
fn new_error(code int) string {
	err := JrpcResponse2<string>{
		error: jsonrpc.new_response_error(code)
	}
	return json.encode(err)
}
