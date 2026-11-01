// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// run_mcp_mode starts VLS as a minimal MCP server over stdio. It speaks
// JSON-RPC 2.0 with Content-Length framing (the same framing as LSP) and
// exposes a small set of tools backed by the VLS App.
fn run_mcp_mode() {
	mut app := &App{
		text:                  ''
		open_files:            map[string]string{}
		temp_dir:              os.join_path(os.temp_dir(), 'vls_mcp_${os.getpid()}')
		diagnostics_scheduler: new_diagnostics_scheduler()
		index_refresh:         new_index_refresh_scheduler()
		v3_line_info_enabled:  true
	}
	os.mkdir_all(app.temp_dir) or {
		eprintln('Failed to create temp directory: ${err}')
		return
	}
	mut reader := new_stdin_buffered_reader()
	for {
		body := read_mcp_frame(mut reader) or { break }
		if body == '' {
			continue
		}
		handle_mcp_message(mut app, body)
	}
	log('VLS MCP exiting.')
}

// read_mcp_frame reads one Content-Length framed JSON-RPC message from stdin.
fn read_mcp_frame[T](mut reader T) !string {
	mut header_bytes := 0
	mut len := -1
	mut header_error := ''
	for {
		line := reader.read_line() or {
			if err is io.Eof {
				return error('eof')
			}
			return err
		}
		header_bytes += line.len + 2
		if header_bytes > max_header_bytes {
			return error('header too large')
		}
		trimmed := line.trim_space()
		if trimmed == '' {
			break
		}
		lower := trimmed.to_lower()
		if lower.starts_with('content-length:') {
			parsed := trimmed.all_after(':').trim_space().int()
			if parsed < 0 {
				header_error = 'invalid content-length'
				continue
			}
			if parsed > max_content_length {
				header_error = 'content-length too large'
				continue
			}
			len = parsed
			continue
		}
		if lower.starts_with('content-type:') {
			continue
		}
	}
	if header_error != '' {
		return error(header_error)
	}
	if len < 0 {
		return ''
	}
	mut buf := []u8{len: len}
	mut total := 0
	for total < len {
		n := reader.read(mut buf[total..]) or { return error('read body failed') }
		if n <= 0 {
			return error('unexpected eof')
		}
		total += n
	}
	return string(buf)
}

// handle_mcp_message dispatches a single JSON-RPC request and writes the response.
fn handle_mcp_message(mut app App, body string) {
	method := mcp_json_field(body, 'method')
	id := mcp_json_field(body, 'id')
	if method == 'initialize' {
		resp := '{"jsonrpc":"2.0","id":${id},"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"vls","version":"${vls_version}"}}}'
		app.send_framed(resp)
		return
	}
	if method == 'notifications/initialized' {
		return
	}
	if method == 'tools/list' {
		resp := '{"jsonrpc":"2.0","id":${id},"result":{"tools":[{"name":"vls_check","description":"Compile-check a V source file and return diagnostics.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},{"name":"vls_hover","description":"Hover information at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["path","line","character"]}},{"name":"vls_definition","description":"Go to definition at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["path","line","character"]}},{"name":"vls_references","description":"Find references at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["path","line","character"]}},{"name":"vls_rename","description":"Rename a symbol at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"},"newName":{"type":"string"}},"required":["path","line","character","newName"]}},{"name":"vls_symbols","description":"List document symbols in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]}}'
		app.send_framed(resp)
		return
	}
	if method == 'tools/call' {
		tool_name := mcp_json_nested(body, 'params', 'name')
		args := mcp_json_nested(body, 'params', 'arguments')
		if tool_name == 'vls_check' {
			p := mcp_json_field(args, 'path')
			if p == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			content := os.read_file(p) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
				return
			}
			uri := path_to_uri(p)
			app.open_files[uri] = content
			notification := app.build_diagnostics_notification(uri, content)
			result := json2.encode(notification)
			resp := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(resp)
			return
		}
		if tool_name == 'vls_hover' {
			p := mcp_json_field(args, 'path')
			if p == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			content := os.read_file(p) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
				return
			}
			line := mcp_json_field(args, 'line').int()
			col := mcp_json_field(args, 'character').int()
			uri := path_to_uri(p)
			app.open_files[uri] = content
			hover := app.hover_at(uri, Position{ line: line, char: col })
			result := if h := hover { json2.encode(h) } else { '{"contents":null}' }
			resp := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(resp)
			return
		}
		if tool_name == 'vls_definition' {
			p := mcp_json_field(args, 'path')
			if p == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			content := os.read_file(p) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
				return
			}
			line := mcp_json_field(args, 'line').int()
			col := mcp_json_field(args, 'character').int()
			uri := path_to_uri(p)
			app.open_files[uri] = content
			params := '{"textDocument":{"uri":"${uri}"},"position":{"line":${line},"character":${col}}}'
			resp := app.operation_at_pos(.definition, Request{ id: 1, method: 'textDocument/definition', params: params })
			result := resp.result
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		if tool_name == 'vls_references' {
			p := mcp_json_field(args, 'path')
			if p == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			content := os.read_file(p) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
				return
			}
			line := mcp_json_field(args, 'line').int()
			col := mcp_json_field(args, 'character').int()
			uri := path_to_uri(p)
			app.open_files[uri] = content
			params := '{"textDocument":{"uri":"${uri}"},"position":{"line":${line},"character":${col}}}'
			resp := app.find_references(Request{ id: 1, method: 'textDocument/references', params: params })
			result := resp.result
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		if tool_name == 'vls_rename' {
			p := mcp_json_field(args, 'path')
			if p == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			content := os.read_file(p) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
				return
			}
			line := mcp_json_field(args, 'line').int()
			col := mcp_json_field(args, 'character').int()
			new_name := mcp_json_field(args, 'newName')
			if new_name == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing newName"}}')
				return
			}
			uri := path_to_uri(p)
			app.open_files[uri] = content
			params := '{"textDocument":{"uri":"${uri}"},"position":{"line":${line},"character":${col}},"newName":"${new_name}"}'
			resp := app.rename_request(Request{ id: 1, method: 'textDocument/rename', params: params }) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"${err.msg()}"}}')
				return
			}
			result := resp.result
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		if tool_name == 'vls_symbols' {
			p := mcp_json_field(args, 'path')
			if p == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			content := os.read_file(p) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
				return
			}
			uri := path_to_uri(p)
			app.open_files[uri] = content
			params := '{"textDocument":{"uri":"${uri}"}}'
			resp := app.handle_document_symbols(Request{ id: 1, method: 'textDocument/documentSymbol', params: params })
			result := resp.result
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32601,"message":"unknown tool"}}')
		return
	}
	// Unknown method.
	app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32601,"message":"method not found"}}')
}

// mcp_json_field extracts a top-level string field value from a JSON object.
fn mcp_json_field(body string, field string) string {
	key := '"${field}"'
	idx := body.index(key) or { return '' }
	rest := body[idx + key.len..]
	mut i := 0
	for i < rest.len && (rest[i] == `:` || rest[i] == ` ` || rest[i] == `\t` || rest[i] == `\n` || rest[i] == `\r`) {
		i++
	}
	if i >= rest.len {
		return ''
	}
	if rest[i] == `"` {
		mut j := i + 1
		mut out := ''
		for j < rest.len {
			if rest[j] == `"` {
				break
			}
			if rest[j] == `\\` && j + 1 < rest.len {
				out += rest[j..j + 2]
				j += 2
				continue
			}
			out += rest[j].str()
			j++
		}
		return out
	}
	mut j := i
	mut out := ''
	for j < rest.len && rest[j] != `,` && rest[j] != `}` && rest[j] != `]` {
		out += rest[j].str()
		j++
	}
	return out.trim_space()
}

// mcp_json_nested extracts a string field nested under `parent` object.
// Handles one level of nesting by finding the parent key then searching within.
fn mcp_json_nested(body string, parent string, field string) string {
	key := '"${parent}"'
	idx := body.index(key) or { return '' }
	rest := body[idx + key.len..]
	// find the opening brace of the nested object
	brace := rest.index('{') or { return '' }
	nested := rest[brace..]
	return mcp_json_field(nested, field)
}
