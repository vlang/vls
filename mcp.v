// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

struct McpRpcSuccessResponse {
	jsonrpc string = '2.0'
	id      json2.Any
	result  json2.Any
}

struct McpRpcErrorBody {
	code    int
	message string
}

struct McpRpcErrorResponse {
	jsonrpc string = '2.0'
	id      json2.Any
	error   McpRpcErrorBody
}

struct McpTextContent {
	content_type string @[json: 'type']
	text         string
}

struct McpToolCallResult {
	content  []McpTextContent
	is_error bool @[json: 'isError']
}

struct McpInitializeCapabilities {
	tools map[string]json2.Any
}

struct McpServerInfo {
	name    string
	version string
}

struct McpInitializeResult {
	protocol_version string @[json: 'protocolVersion']
	capabilities     McpInitializeCapabilities
	server_info      McpServerInfo @[json: 'serverInfo']
}

struct McpPropertySchema {
	schema_type string @[json: 'type']
}

struct McpInputSchema {
	schema_type string @[json: 'type']
	properties  map[string]McpPropertySchema
	required    []string
}

struct McpTool {
	name         string
	description  string
	input_schema McpInputSchema @[json: 'inputSchema']
}

struct McpToolsListResult {
	tools []McpTool
}

fn mcp_tool(name string, description string, properties map[string]string, required []string) McpTool {
	mut schema_properties := map[string]McpPropertySchema{}
	for key, schema_type in properties {
		schema_properties[key] = McpPropertySchema{
			schema_type: schema_type
		}
	}
	return McpTool{
		name:         name
		description:  description
		input_schema: McpInputSchema{
			schema_type: 'object'
			properties:  schema_properties
			required:    required
		}
	}
}

fn mcp_tools() []McpTool {
	return [
		mcp_tool('vls_check', 'Compile-check a V source file and return diagnostics.', {
			'path': 'string'
		}, ['path']),
		mcp_tool('vls_hover', 'Hover information at a position in a V source file.', {
			'path':      'string'
			'line':      'integer'
			'character': 'integer'
		}, ['path', 'line', 'character']),
		mcp_tool('vls_definition', 'Go to definition at a position in a V source file.', {
			'path':      'string'
			'line':      'integer'
			'character': 'integer'
		}, ['path', 'line', 'character']),
		mcp_tool('vls_references', 'Find references at a position in a V source file.', {
			'path':      'string'
			'line':      'integer'
			'character': 'integer'
		}, ['path', 'line', 'character']),
		mcp_tool('vls_rename', 'Rename a symbol at a position in a V source file.', {
			'path':      'string'
			'line':      'integer'
			'character': 'integer'
			'newName':   'string'
		}, ['path', 'line', 'character', 'newName']),
		mcp_tool('vls_symbols', 'List document symbols in a V source file.', {
			'path': 'string'
		}, ['path']),
		mcp_tool('vls_completion', 'Completion candidates at a position in a V source file.', {
			'path':      'string'
			'line':      'integer'
			'character': 'integer'
		}, ['path', 'line', 'character']),
	]
}

// run_mcp_mode starts VLS as a minimal MCP server over stdio. It speaks
// JSON-RPC 2.0 with newline-delimited stdio messages and exposes a small set
// of tools backed by the VLS App.
fn run_mcp_mode() {
	mut app := &App{
		text:                  ''
		open_files:            map[string]string{}
		temp_dir:              os.join_path(os.temp_dir(), 'vls_mcp_${os.getpid()}')
		diagnostics_scheduler: new_diagnostics_scheduler()
		index_refresh:         new_index_refresh_scheduler()
		v3_line_info_enabled:  true
		suppress_lsp_output:   true
	}
	os.mkdir_all(app.temp_dir) or {
		eprintln('Failed to create temp directory: ${err}')
		return
	}
	defer {
		app.stop_standalone_session()
		os.rmdir_all(app.temp_dir) or {}
	}
	mut reader := new_stdin_buffered_reader()
	for {
		line := reader.read_line() or { break }
		body := line.trim_space()
		if body == '' {
			continue
		}
		handle_mcp_message(mut app, body)
		// Drop per-request buffers so a later query never sees stale
		// source from an earlier one (issue: MCP-loaded buffers linger).
		app.open_files.clear()
	}
	log('VLS MCP exiting.')
}

fn (mut app App) send_mcp_message(content string) {
	app.write_mcp_data('${content}\n')
}

fn (mut app App) write_mcp_data(data string) {
	app.write_mutex.lock()
	defer {
		app.write_mutex.unlock()
	}
	if app.capture_output {
		app.captured_output << data
		return
	}
	print(data)
	flush_stdout()
}

fn (mut app App) send_mcp_success(id json2.Any, result_json string) {
	result := json2.decode_standard[json2.Any](result_json) or { json2.null }
	app.send_mcp_message(json2.encode(McpRpcSuccessResponse{
		id:     id
		result: result
	}))
}

fn (mut app App) send_mcp_error(id json2.Any, code int, message string) {
	app.send_mcp_message(json2.encode(McpRpcErrorResponse{
		id:    id
		error: McpRpcErrorBody{
			code:    code
			message: message
		}
	}))
}

fn (mut app App) send_mcp_tool_result(id json2.Any, text string, is_error bool) {
	result := McpToolCallResult{
		content:  [McpTextContent{
			content_type: 'text'
			text:         text
		}]
		is_error: is_error
	}
	app.send_mcp_success(id, json2.encode(result))
}

fn (mut app App) send_mcp_tool_error(id json2.Any, message string) {
	app.send_mcp_tool_result(id, message, true)
}

// handle_mcp_message dispatches a single JSON-RPC message and writes the
// response, unless it is a notification, which must never receive one.
fn mcp_request_object(body string) !map[string]json2.Any {
	value := json2.decode_standard[json2.Any](body)!
	if value is map[string]json2.Any {
		return value
	}
	return error('JSON-RPC message must be an object')
}

fn handle_mcp_message(mut app App, body string) {
	request := mcp_request_object(body) or {
		if err.msg() == 'JSON-RPC message must be an object' {
			app.send_mcp_error(json2.null, -32600, 'invalid request')
		} else {
			app.send_mcp_error(json2.null, -32700, 'parse error')
		}
		return
	}
	if mcp_string_field(request, 'jsonrpc') != '2.0' {
		app.send_mcp_error(json2.null, -32600, 'invalid request')
		return
	}
	method_value := request['method'] or {
		app.send_mcp_error(json2.null, -32600, 'invalid request')
		return
	}
	if method_value !is string {
		app.send_mcp_error(json2.null, -32600, 'invalid request')
		return
	}
	if 'id' in request {
		id_value := request['id'] or { json2.null }
		if id_value is []json2.Any || id_value is map[string]json2.Any || id_value is bool {
			app.send_mcp_error(json2.null, -32600, 'invalid request')
			return
		}
	}
	method := method_value as string
	if 'id' !in request {
		// JSON-RPC notification (no id): fire-and-forget, never answered.
		handle_mcp_notification(method)
		return
	}
	id := request['id'] or { json2.null }
	if method == 'ping' {
		app.send_mcp_success(id, json2.encode(map[string]json2.Any{}))
		return
	}
	if method == 'initialize' {
		result := McpInitializeResult{
			protocol_version: '2024-11-05'
			capabilities:     McpInitializeCapabilities{
				tools: map[string]json2.Any{}
			}
			server_info:      McpServerInfo{
				name:    'vls'
				version: vls_version
			}
		}
		app.send_mcp_success(id, json2.encode(result))
		return
	}
	if method == 'tools/list' {
		app.send_mcp_success(id, json2.encode(McpToolsListResult{
			tools: mcp_tools()
		}))
		return
	}
	if method == 'tools/call' {
		params := mcp_object_field(request, 'params')
		tool_name := mcp_string_field(params, 'name')
		args := mcp_object_field(params, 'arguments')
		if tool_name == 'vls_check' {
			document := mcp_load_document(mut app, id, args) or { return }
			notification := app.build_diagnostics_notification(document.uri, document.content)
			app.send_mcp_tool_result(id, json2.encode(notification), false)
			return
		}
		if tool_name == 'vls_hover' {
			document := mcp_load_document(mut app, id, args) or { return }
			position := mcp_position(args) or {
				app.send_mcp_tool_error(id, 'line and character must be non-negative integers')
				return
			}
			hover := app.hover_at(document.uri, position)
			result := if h := hover {
				json2.encode(h)
			} else {
				json2.encode(map[string]json2.Any{
					'contents': json2.null
				})
			}
			app.send_mcp_tool_result(id, result, false)
			return
		}
		if tool_name == 'vls_definition' {
			document := mcp_load_document(mut app, id, args) or { return }
			position := mcp_position(args) or {
				app.send_mcp_tool_error(id, 'line and character must be non-negative integers')
				return
			}
			params_json := json2.encode(TextDocumentPositionParams{
				text_document: TextDocumentIdentifier{
					uri: document.uri
				}
				position:      position
			})
			response := app.operation_at_pos(.definition, Request{
				id:     1
				method: 'textDocument/definition'
				params: params_json
			})
			app.send_mcp_tool_result(id, json_response_result(response.result), false)
			return
		}
		if tool_name == 'vls_references' {
			document := mcp_load_document(mut app, id, args) or { return }
			position := mcp_position(args) or {
				app.send_mcp_tool_error(id, 'line and character must be non-negative integers')
				return
			}
			params_json := json2.encode(ReferenceParams{
				text_document: TextDocumentIdentifier{
					uri: document.uri
				}
				position:      position
				context:       ReferenceContext{}
			})
			response := app.find_references(Request{
				id:     1
				method: 'textDocument/references'
				params: params_json
			})
			app.send_mcp_tool_result(id, json_response_result(response.result), false)
			return
		}
		if tool_name == 'vls_rename' {
			document := mcp_load_document(mut app, id, args) or { return }
			position := mcp_position(args) or {
				app.send_mcp_tool_error(id, 'line and character must be non-negative integers')
				return
			}
			new_name := mcp_string_field(args, 'newName')
			if new_name == '' {
				app.send_mcp_tool_error(id, 'missing newName')
				return
			}
			params_json := json2.encode(RenameParams{
				text_document: TextDocumentIdentifier{
					uri: document.uri
				}
				position:      position
				new_name:      new_name
			})
			response := app.rename_request(Request{
				id:     1
				method: 'textDocument/rename'
				params: params_json
			}) or {
				app.send_mcp_tool_error(id, err.msg())
				return
			}
			app.send_mcp_tool_result(id, json_response_result(response.result), false)
			return
		}
		if tool_name == 'vls_symbols' {
			document := mcp_load_document(mut app, id, args) or { return }
			params_json := json2.encode(DocumentSymbolParams{
				text_document: TextDocumentIdentifier{
					uri: document.uri
				}
			})
			response := app.handle_document_symbols(Request{
				id:     1
				method: 'textDocument/documentSymbol'
				params: params_json
			})
			app.send_mcp_tool_result(id, json_response_result(response.result), false)
			return
		}
		if tool_name == 'vls_completion' {
			document := mcp_load_document(mut app, id, args) or { return }
			position := mcp_position(args) or {
				app.send_mcp_tool_error(id, 'line and character must be non-negative integers')
				return
			}
			result := app.completion_result_at(document.uri, position)
			app.send_mcp_tool_result(id, json2.encode(result), false)
			return
		}
		app.send_mcp_tool_error(id, 'unknown tool')
		return
	}
	app.send_mcp_error(id, -32601, 'method not found')
}

// handle_mcp_notification answers fire-and-forget JSON-RPC notifications,
// which must never receive a response. The synchronous MCP server has no
// cancellable operations, so cancellation is a no-op.
fn handle_mcp_notification(method string) {
	if method == 'notifications/initialized' {
		log('VLS MCP initialized.')
	}
	if method == 'ping' {
		// Ping as a notification is a no-op.
	}
}

struct McpDocument {
	uri     string
	content string
}

fn mcp_object_field(object map[string]json2.Any, field string) map[string]json2.Any {
	value := object[field] or { return map[string]json2.Any{} }
	if value is map[string]json2.Any {
		return value
	}
	return map[string]json2.Any{}
}

fn mcp_string_field(object map[string]json2.Any, field string) string {
	value := object[field] or { return '' }
	if value is string {
		return value
	}
	return ''
}

fn mcp_int_field(object map[string]json2.Any, field string) ?int {
	value := object[field] or { return none }
	if value is f64 {
		if value < 0 || value >= f64(max_int) {
			return none
		}
		converted := int(value)
		return if f64(converted) == value { ?int(converted) } else { none }
	}
	if value is f32 {
		if value < 0 || value >= f32(max_int) {
			return none
		}
		converted := int(value)
		return if f32(converted) == value { ?int(converted) } else { none }
	}
	if value is i64 {
		if value < i64(min_int) || value > i64(max_int) {
			return none
		}
		converted := int(value)
		return if i64(converted) == value { ?int(converted) } else { none }
	}
	if value is int {
		return value
	}
	if value is i32 {
		return int(value)
	}
	if value is i16 {
		return int(value)
	}
	if value is i8 {
		return int(value)
	}
	if value is u64 {
		if value > u64(max_int) {
			return none
		}
		converted := int(value)
		return if converted >= 0 && u64(converted) == value { ?int(converted) } else { none }
	}
	if value is u32 {
		if value > u32(max_int) {
			return none
		}
		converted := int(value)
		return if converted >= 0 && u32(converted) == value { ?int(converted) } else { none }
	}
	if value is u16 {
		return int(value)
	}
	if value is u8 {
		return int(value)
	}
	return none
}

fn mcp_position(arguments map[string]json2.Any) ?Position {
	line := mcp_int_field(arguments, 'line') or { return none }
	character := mcp_int_field(arguments, 'character') or { return none }
	if line < 0 || character < 0 {
		return none
	}
	return Position{
		line: line
		char: character
	}
}

fn mcp_load_document(mut app App, id json2.Any, arguments map[string]json2.Any) ?McpDocument {
	raw_path := mcp_string_field(arguments, 'path')
	if raw_path == '' {
		app.send_mcp_tool_error(id, 'missing path')
		return none
	}
	path := os.real_path(raw_path)
	file_info := os.stat(path) or {
		app.send_mcp_tool_error(id, 'cannot read file')
		return none
	}
	if file_info.get_mode().typ != .regular {
		app.send_mcp_tool_error(id, 'path is not a regular file')
		return none
	}
	if file_info.size > index_max_file_bytes {
		app.send_mcp_tool_error(id, 'source file is too large')
		return none
	}
	content := os.read_file(path) or {
		app.send_mcp_tool_error(id, 'cannot read file')
		return none
	}
	if u64(content.len) > index_max_file_bytes {
		app.send_mcp_tool_error(id, 'source file is too large')
		return none
	}
	uri := path_to_uri(path)
	app.bump_generation(uri)
	app.open_files[uri] = content
	return McpDocument{
		uri:     uri
		content: content
	}
}
