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
	defer {
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

// handle_mcp_message dispatches a single JSON-RPC message and writes the
// response, unless it is a notification, which must never receive one.
fn handle_mcp_message(mut app App, body string) {
	method := mcp_json_field(body, 'method')
	id := mcp_top_level_raw_field(body, 'id')
	if id == 'null' {
		// JSON-RPC notification (no id): fire-and-forget, never answered.
		handle_mcp_notification(method)
		return
	}
	if method == 'ping' {
		app.send_framed('{"jsonrpc":"2.0","id":${id},"result":{}}')
		return
	}
	if method == 'initialize' {
		resp := '{"jsonrpc":"2.0","id":${id},"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"vls","version":"${vls_version}"}}}'
		app.send_framed(resp)
		return
	}
	if method == 'tools/list' {
		resp := '{"jsonrpc":"2.0","id":${id},"result":{"tools":[{"name":"vls_check","description":"Compile-check a V source file and return diagnostics.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},{"name":"vls_hover","description":"Hover information at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["path","line","character"]}},{"name":"vls_definition","description":"Go to definition at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["path","line","character"]}},{"name":"vls_references","description":"Find references at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["path","line","character"]}},{"name":"vls_rename","description":"Rename a symbol at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"},"newName":{"type":"string"}},"required":["path","line","character","newName"]}},{"name":"vls_symbols","description":"List document symbols in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},{"name":"vls_completion","description":"Completion candidates at a position in a V source file.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["path","line","character"]}}]}}'
		app.send_framed(resp)
		return
	}
	if method == 'tools/call' {
		tool_name := mcp_json_nested(body, 'params', 'name')
		args := mcp_json_nested(body, 'params', 'arguments')
		if tool_name == 'vls_check' {
			raw_path := mcp_json_field(args, 'path')
			if raw_path == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			p := os.real_path(raw_path)
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
			raw_path := mcp_json_field(args, 'path')
			if raw_path == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			p := os.real_path(raw_path)
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
			raw_path := mcp_json_field(args, 'path')
			if raw_path == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			p := os.real_path(raw_path)
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
			result := json2.encode(resp.result)
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		if tool_name == 'vls_references' {
			raw_path := mcp_json_field(args, 'path')
			if raw_path == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			p := os.real_path(raw_path)
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
			result := json2.encode(resp.result)
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		if tool_name == 'vls_rename' {
			raw_path := mcp_json_field(args, 'path')
			if raw_path == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			p := os.real_path(raw_path)
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
			result := json2.encode(resp.result)
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		if tool_name == 'vls_symbols' {
			raw_path := mcp_json_field(args, 'path')
			if raw_path == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			p := os.real_path(raw_path)
			content := os.read_file(p) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
				return
			}
			uri := path_to_uri(p)
			app.open_files[uri] = content
			params := '{"textDocument":{"uri":"${uri}"}}'
			resp := app.handle_document_symbols(Request{ id: 1, method: 'textDocument/documentSymbol', params: params })
			result := json2.encode(resp.result)
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		if tool_name == 'vls_completion' {
			raw_path := mcp_json_field(args, 'path')
			if raw_path == '' {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
				return
			}
			p := os.real_path(raw_path)
			content := os.read_file(p) or {
				app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
				return
			}
			line := mcp_json_field(args, 'line').int()
			col := mcp_json_field(args, 'character').int()
			uri := path_to_uri(p)
			app.open_files[uri] = content
			result := app.indexed_completions(uri, Position{ line: line, char: col })
			result_json := json2.encode(result)
			out := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result_json)}}],"isError":false}}'
			app.send_framed(out)
			return
		}
		app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32601,"message":"unknown tool"}}')
		return
	}
	// Unknown method. Notifications (no id) must never receive a response.
	if id == 'null' {
		handle_mcp_notification(method)
		return
	}
	app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32601,"message":"method not found"}}')
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

// mcp_json_field extracts a top-level scalar field value from a JSON object.
// Strings are unescaped; numbers and literals are returned verbatim.
fn mcp_json_field(body string, field string) string {
	key := '"${field}"'
	idx := body.index(key) or { return '' }
	return mcp_parse_value(body[idx + key.len..])
}

// mcp_parse_value parses one JSON value at the start of `s`, after an
// optional colon and whitespace. Strings are unescaped, objects are returned
// balanced and complete, and numbers and literals are returned verbatim.
fn mcp_parse_value(s string) string {
	mut i := 0
	for i < s.len && (s[i] == `:` || s[i] == ` ` || s[i] == `\t` || s[i] == `\n` || s[i] == `\r`) {
		i++
	}
	if i >= s.len {
		return ''
	}
	if s[i] == `"` {
		return mcp_parse_string(s[i..])
	}
	if s[i] == `{` {
		return mcp_object_at(s[i..])
	}
	mut out := ''
	mut j := i
	for j < s.len && s[j] != `,` && s[j] != `}` && s[j] != `]` {
		out += s[j..j + 1]
		j++
	}
	return out.trim_space()
}

// mcp_object_at returns the balanced JSON object starting at s[0] == `{`,
// skipping over braces inside strings. Returns '' when unbalanced.
fn mcp_object_at(s string) string {
	mut depth := 0
	mut in_str := false
	mut i := 0
	for i < s.len {
		c := s[i]
		if in_str {
			if c == `\\` {
				i += 2
				continue
			}
			if c == `"` {
				in_str = false
			}
			i++
			continue
		}
		if c == `"` {
			in_str = true
		} else if c == `{` {
			depth++
		} else if c == `}` {
			depth--
			if depth == 0 {
				return s[..i + 1]
			}
		}
		i++
	}
	return ''
}

// mcp_parse_string decodes one JSON string starting at s[0] == `"`,
// reusing the request parser's decoder so escapes (including \uXXXX with
// surrogate pairs) behave identically on both transports.
fn mcp_parse_string(s string) string {
	str, _ := read_json_string_token(s, 0)
	return str
}

// mcp_top_level_raw_field returns the raw JSON value of a field that is a
// direct child of the top-level object, so a nested `id` (e.g. inside
// `capabilities.experimental`) can never shadow the request id.
fn mcp_top_level_raw_field(body string, field string) string {
	key := '"${field}"'
	// Find the top-level object's opening brace.
	start := body.index('{') or { return 'null' }
	mut depth := 0
	mut in_str := false
	mut i := start
	for i < body.len {
		c := body[i]
		if in_str {
			if c == `\\` {
				i += 2
				continue
			}
			if c == `"` {
				in_str = false
			}
			i++
			continue
		}
		if c == `"` {
			// Candidate key at depth 1?
			if depth == 1 && body[i..].starts_with(key) {
				// Ensure it is a real key: followed by optional ws then colon.
				mut j := i + key.len
				for j < body.len && (body[j] == ` ` || body[j] == `\t` || body[j] == `\n` || body[j] == `\r`) {
					j++
				}
				if j < body.len && body[j] == `:` {
					// Parse the value starting after the colon.
					return mcp_parse_value(body[j..])
				}
			}
			in_str = true
		} else if c == `{` {
			depth++
		} else if c == `}` {
			depth--
			if depth == 0 {
				break
			}
		}
		i++
	}
	return 'null'
}

// mcp_json_raw_field returns the raw JSON value of a top-level field (including
// quotes for strings), so string IDs are preserved verbatim in responses.
fn mcp_json_raw_field(body string, field string) string {
	key := '"${field}"'
	idx := body.index(key) or { return 'null' }
	rest := body[idx + key.len..]
	mut i := 0
	for i < rest.len && (rest[i] == `:` || rest[i] == ` ` || rest[i] == `\t` || rest[i] == `\n` || rest[i] == `\r`) {
		i++
	}
	if i >= rest.len {
		return 'null'
	}
	if rest[i] == `"` {
		// string: read until closing quote, handling escapes
		mut j := i + 1
		mut out := '"'
		for j < rest.len {
			out += rest[j..j + 1]
			if rest[j] == `\\` && j + 1 < rest.len {
				out += rest[j + 1..j + 2]
				j += 2
				continue
			}
			if rest[j] == `"` {
				j++
				break
			}
			j++
		}
		return out
	}
	// non-string: read until comma/brace
	mut j := i
	mut out := ''
	for j < rest.len && rest[j] != `,` && rest[j] != `}` && rest[j] != `]` {
		out += rest[j..j + 1]
		j++
	}
	return out.trim_space()
}

// mcp_json_nested extracts a field nested one level under `parent`.
// Object values are returned balanced and complete, so an `arguments`
// object with several keys survives intact; scalars are decoded.
fn mcp_json_nested(body string, parent string, field string) string {
	pkey := '"${parent}"'
	pidx := body.index(pkey) or { return '' }
	pobj := mcp_object_at_value(body[pidx + pkey.len..])
	if pobj == '' {
		return ''
	}
	fkey := '"${field}"'
	fidx := pobj.index(fkey) or { return '' }
	return mcp_parse_value(pobj[fidx + fkey.len..])
}

// mcp_object_at_value skips a colon and whitespace, then returns the balanced
// object that follows, or '' when there is none.
fn mcp_object_at_value(s string) string {
	mut i := 0
	for i < s.len && (s[i] == `:` || s[i] == ` ` || s[i] == `\t` || s[i] == `\n` || s[i] == `\r`) {
		i++
	}
	if i >= s.len || s[i] != `{` {
		return ''
	}
	return mcp_object_at(s[i..])
}
