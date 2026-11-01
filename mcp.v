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
	// Parse minimal fields manually to avoid tight coupling to json2 types.
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
		resp := '{"jsonrpc":"2.0","id":${id},"result":{"tools":[{"name":"vls_check","description":"Compile-check a V source file and return diagnostics.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]}}'
		app.send_framed(resp)
		return
	}
	if method == 'tools/call' {
		// Extract path argument (best-effort).
		path := mcp_json_nested(body, 'arguments', 'path')
		if path == '' {
			app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32602,"message":"missing path"}}')
			return
		}
		content := os.read_file(path) or {
			app.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":-32603,"message":"cannot read file"}}')
			return
		}
		uri := path_to_uri(path)
		app.open_files[uri] = content
		notification := app.build_diagnostics_notification(uri, content)
		result := json2.encode(notification)
		resp := '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json2.encode(result)}}],"isError":false}}'
		app.send_framed(resp)
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
	// skip colon and whitespace
	mut i := 0
	for i < rest.len && (rest[i] == `:` || rest[i] == ` ` || rest[i] == `\t` || rest[i] == `\n` || rest[i] == `\r`) {
		i++
	}
	if i >= rest.len {
		return ''
	}
	if rest[i] == `"` {
		// string value
		mut j := i + 1
		mut out := ''
		for j < rest.len {
			if rest[j] == `"` {
				break
			}
			if rest[j] == `\\` && j + 1 < rest.len {
				out += rest[j..j+2]
				j += 2
				continue
			}
			out += rest[j].str()
			j++
		}
		return out
	}
	// non-string: read until comma/brace
	mut j := i
	mut out := ''
	for j < rest.len && rest[j] != `,` && rest[j] != `}` && rest[j] != `]` {
		out += rest[j].str()
		j++
	}
	return out.trim_space()
}

// mcp_json_nested extracts a string field nested under `parent` object.
fn mcp_json_nested(body string, parent string, field string) string {
	key := '"${parent}"'
	idx := body.index(key) or { return '' }
	rest := body[idx + key.len..]
	// find the nested object
	brace := rest.index('{') or { return '' }
	nested := rest[brace..]
	return mcp_json_field(nested, field)
}