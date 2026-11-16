// Tests for MCP JSON-RPC parsing, responses, and tool argument handling.

module main

import json2
import os
import strings
import time

fn mcp_test_write_file(path string, content string) {
	os.write_file(path, content) or { panic(err) }
}

fn test_mcp_load_document_invalidates_rename_anchors() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_mcp_rename_cache_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	path := os.join_path(temp_dir, 'main.v')
	mcp_test_write_file(path, 'module main\nfn main() {}\n')
	uri := path_to_uri(path)
	mut app := &App{
		open_files:     map[string]string{}
		capture_output: true
		rename_anchors: map[string]?Location{}
	}
	app.rename_anchors_generation = app.open_files_generation
	app.rename_anchors['stale'] = ?Location(Location{ uri: uri })
	app.open_files[uri] = 'old buffer'
	app.open_files.clear()
	mcp_test_write_file(path, 'module main\nfn main() { println(1) }\n')
	document := mcp_load_document(mut app, json2.Any(1), {
		'path': json2.Any(path)
	}) or { panic('expected document') }
	assert document.content.contains('println(1)')
	assert app.open_files_generation == 1
	assert app.rename_anchor_cache().len == 0
}

fn test_mcp_json2_decodes_nested_arguments() {
	body := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"vls_definition","arguments":{"path":"/tmp/main.v","line":10,"character":5}}}'
	request := mcp_request_object(body) or { panic(err) }
	params := mcp_object_field(request, 'params')
	args := mcp_object_field(params, 'arguments')
	assert mcp_string_field(params, 'name') == 'vls_definition'
	assert mcp_string_field(args, 'path') == '/tmp/main.v'
	assert mcp_int_field(args, 'line') or { -1 } == 10
	assert mcp_int_field(args, 'character') or { -1 } == 5
	position := mcp_position(args) or { panic('expected valid position') }
	assert position == Position{ line: 10, char: 5 }
}

fn test_mcp_position_rejects_missing_invalid_and_negative_coordinates() {
	assert mcp_position(map[string]json2.Any{}) == none
	assert mcp_position({
		'line':      json2.Any('2')
		'character': json2.Any(1)
	}) == none
	assert mcp_position({
		'line':      json2.Any(-1)
		'character': json2.Any(1)
	}) == none
}

fn test_mcp_missing_position_returns_tool_error() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_mcp_missing_position_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	path := os.join_path(temp_dir, 'main.v')
	mcp_test_write_file(path, 'module main\nfn main() {}\n')
	mut app := &App{ capture_output: true }
	body := json2.encode({
		'jsonrpc': json2.Any('2.0')
		'id':      json2.Any('missing-position')
		'method':  json2.Any('tools/call')
		'params':  json2.Any({
			'name':      json2.Any('vls_hover')
			'arguments': json2.Any({
				'path': json2.Any(path)
			})
		})
	})
	handle_mcp_message(mut app, body)
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	result := mcp_object_field(response, 'result')
	assert json2.encode(result['isError'] or { json2.null }) == 'true'
	content := (result['content'] or { json2.null }).as_array()
	assert mcp_string_field(content[0].as_map(), 'text') == 'line and character must be non-negative integers'
}

fn test_mcp_json2_keeps_rename_argument_and_decodes_escapes() {
	body := '{"params":{"name":"vls_rename","arguments":{"path":"/tmp/main.v","line":3,"character":7,"newName":"count"}}}'
	request := mcp_request_object(body) or { panic(err) }
	args := mcp_object_field(mcp_object_field(request, 'params'), 'arguments')
	assert mcp_string_field(args, 'path') == '/tmp/main.v'
	assert mcp_int_field(args, 'line') or { -1 } == 3
	assert mcp_int_field(args, 'character') or { -1 } == 7
	assert mcp_string_field(args, 'newName') == 'count'
}

fn test_mcp_json2_decodes_backslash_escapes() {
	body := '{"arguments":{"path":"C:\\\\Users\\\\dev\\\\main.v","newName":"say \\\"hi\\\""}}'
	request := mcp_request_object(body) or { panic(err) }
	arguments := mcp_object_field(request, 'arguments')
	assert mcp_string_field(arguments, 'path') == 'C:\\Users\\dev\\main.v'
	assert mcp_string_field(arguments, 'newName') == 'say "hi"'
}

fn test_mcp_json2_decodes_unicode_escapes() {
	body := '{"path":"/tmp/\\u00e9.v","name":"\\ud83d\\ude00"}'
	request := mcp_request_object(body) or { panic(err) }
	assert mcp_string_field(request, 'path') == '/tmp/' + rune(0xe9).str() + '.v'
	assert mcp_string_field(request, 'name') == rune(0x1F600).str()
}

fn test_mcp_json2_preserves_string_id_separately_from_nested_id() {
	body := '{"jsonrpc":"2.0","id":"request-1","method":"initialize","params":{"id":7}}'
	request := mcp_request_object(body) or { panic(err) }
	assert json2.encode(request['id'] or { json2.null }) == '"request-1"'
	params := mcp_object_field(request, 'params')
	assert mcp_int_field(params, 'id') or { -1 } == 7
}

fn test_mcp_send_message_uses_newline_framing() {
	mut app := &App{ capture_output: true }
	app.send_mcp_message('{"jsonrpc":"2.0","id":1,"result":{}}')
	assert app.captured_output == ['{"jsonrpc":"2.0","id":1,"result":{}}\n']
}

fn test_standalone_session_cleanup_stops_background_schedulers() {
	mut app := &App{
		diagnostics_scheduler: new_diagnostics_scheduler()
		index_refresh:         new_index_refresh_scheduler()
	}
	app.stop_standalone_session()
	diagnostics := app.diagnostics_scheduler or { panic('missing diagnostics scheduler') }
	index := app.index_refresh or { panic('missing index scheduler') }
	assert diagnostics.stopped
	assert index.stopped
}

fn test_mcp_transport_suppresses_lsp_output() {
	mut app := &App{
		capture_output:      true
		suppress_lsp_output: true
	}
	app.send_log_message('internal diagnostic', 4)
	app.send_mcp_message('{"jsonrpc":"2.0","id":1,"result":{}}')
	assert app.captured_output == ['{"jsonrpc":"2.0","id":1,"result":{}}\n']
}

fn test_mcp_tools_list_is_encoded_as_json_objects() {
	mut app := &App{ capture_output: true }
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","id":6,"method":"tools/list"}')
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	result := (response['result'] or { json2.null }).as_map()
	tools := (result['tools'] or { json2.null }).as_array()
	assert tools.len == 7
	first_tool := tools[0].as_map()
	assert mcp_string_field(first_tool, 'name') == 'vls_check'
	assert mcp_object_field(first_tool, 'inputSchema').len > 0
}

fn test_mcp_tool_failure_uses_is_error_result() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_mcp_missing_file_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut app := &App{ capture_output: true }
	body := json2.encode({
		'jsonrpc': json2.Any('2.0')
		'id':      json2.Any('missing-file')
		'method':  json2.Any('tools/call')
		'params':  json2.Any({
			'name':      json2.Any('vls_check')
			'arguments': json2.Any({
				'path': json2.Any(os.join_path(temp_dir, 'missing.v'))
			})
		})
	})
	handle_mcp_message(mut app, body)
	assert app.captured_output.len == 1
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	assert 'error' !in response
	result := mcp_object_field(response, 'result')
	assert json2.encode(result['isError'] or { json2.null }) == 'true'
	content := (result['content'] or { json2.null }).as_array()
	assert content.len == 1
	assert mcp_string_field(content[0].as_map(), 'text') == 'cannot read file'
}

fn test_mcp_load_document_rejects_non_regular_files() {
	if !os.exists('/dev/zero') {
		return
	}
	mut app := &App{ capture_output: true }
	document := mcp_load_document(mut app, json2.Any(1), {
		'path': json2.Any('/dev/zero')
	})
	assert document == none
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	result := mcp_object_field(response, 'result')
	assert json2.encode(result['isError'] or { json2.null }) == 'true'
	content := (result['content'] or { json2.null }).as_array()
	assert mcp_string_field(content[0].as_map(), 'text') == 'path is not a regular file'
}

fn test_mcp_load_document_rejects_oversized_sources() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_mcp_oversized_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	path := os.join_path(temp_dir, 'large.v')
	os.write_file(path, strings.repeat(`x`, int(index_max_file_bytes) + 1)) or { panic(err) }
	mut app := &App{ capture_output: true }
	document := mcp_load_document(mut app, json2.Any(1), {
		'path': json2.Any(path)
	})
	assert document == none
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	result := mcp_object_field(response, 'result')
	assert json2.encode(result['isError'] or { json2.null }) == 'true'
	content := (result['content'] or { json2.null }).as_array()
	assert mcp_string_field(content[0].as_map(), 'text') == 'source file is too large'
}

fn test_mcp_symbols_return_standard_json() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_mcp_symbols_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	path := os.join_path(temp_dir, 'main.v')
	mcp_test_write_file(path, 'module main\nfn apple() {}\n')
	mut app := &App{
		open_files:     map[string]string{}
		capture_output: true
	}
	body := json2.encode({
		'jsonrpc': json2.Any('2.0')
		'id':      json2.Any('symbols')
		'method':  json2.Any('tools/call')
		'params':  json2.Any({
			'name':      json2.Any('vls_symbols')
			'arguments': json2.Any({
				'path': json2.Any(path)
			})
		})
	})
	handle_mcp_message(mut app, body)
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	result := mcp_object_field(response, 'result')
	content := (result['content'] or { json2.null }).as_array()
	text := mcp_string_field(content[0].as_map(), 'text')
	assert !text.contains('"_type"')
	symbols := json2.decode[[]DocumentSymbol](text) or { panic(err) }
	assert symbols.any(it.name == 'apple')
}

fn test_mcp_invalid_rename_returns_tool_error_result() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_mcp_invalid_rename_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	path := os.join_path(temp_dir, 'main.v')
	mcp_test_write_file(path, 'module main\nfn main() {}\n')
	mut app := &App{ capture_output: true }
	body := json2.encode({
		'jsonrpc': json2.Any('2.0')
		'id':      json2.Any(7)
		'method':  json2.Any('tools/call')
		'params':  json2.Any({
			'name':      json2.Any('vls_rename')
			'arguments': json2.Any({
				'path':      json2.Any(path)
				'line':      json2.Any(0)
				'character': json2.Any(0)
			})
		})
	})
	handle_mcp_message(mut app, body)
	assert app.captured_output.len == 1
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	assert 'error' !in response
	result := mcp_object_field(response, 'result')
	assert json2.encode(result['isError'] or { json2.null }) == 'true'
	content := (result['content'] or { json2.null }).as_array()
	assert mcp_string_field(content[0].as_map(), 'text') == 'missing newName'
}

fn test_mcp_unknown_tool_returns_tool_error_result() {
	mut app := &App{ capture_output: true }
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"vls_unknown","arguments":{}}}')
	assert app.captured_output.len == 1
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	assert 'error' !in response
	result := mcp_object_field(response, 'result')
	assert json2.encode(result['isError'] or { json2.null }) == 'true'
	content := (result['content'] or { json2.null }).as_array()
	assert mcp_string_field(content[0].as_map(), 'text') == 'unknown tool'
}

fn test_mcp_install_config_is_json2_encoded() {
	config := json2.decode_standard[map[string]json2.Any](mcp_install_config()) or {
		panic(err)
	}
	servers := mcp_object_field(config, 'mcpServers')
	assert servers.len == 1
	server := mcp_object_field(servers, 'vls')
	assert server.len == 2
	assert mcp_string_field(server, 'command') == 'vls'
	args := (server['args'] or { json2.null }).as_array()
	assert args.len == 1
	assert args[0].str() == '--mcp'
}

// P2: ping answers with an empty successful result.
fn test_mcp_ping_returns_empty_result() {
	mut app := &App{ capture_output: true }
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","id":5,"method":"ping"}')
	assert app.captured_output == ['{"jsonrpc":"2.0","id":5,"result":{}}\n']
}

fn test_mcp_ping_preserves_string_request_id() {
	mut app := &App{ capture_output: true }
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","id":"request-1","method":"ping"}')
	assert app.captured_output == ['{"jsonrpc":"2.0","id":"request-1","result":{}}\n']
}

fn test_mcp_invalid_jsonrpc_requests_return_invalid_request() {
	mut app := &App{ capture_output: true }
	handle_mcp_message(mut app, '[]')
	handle_mcp_message(mut app, '{"jsonrpc":"1.0","id":1,"method":"ping"}')
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","id":2}')
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","id":3,"method":4}')
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","id":[],"method":"ping"}')
	assert app.captured_output.len == 5
	for message in app.captured_output {
		response := json2.decode_standard[map[string]json2.Any](message.trim_space()) or {
			panic(err)
		}
		error := mcp_object_field(response, 'error')
		assert (error['code'] or { json2.null }).int() == -32600
		assert json2.encode(response['id'] or { json2.null }) == 'null'
	}
	app.captured_output.clear()
	handle_mcp_message(mut app, '{invalid json')
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	error := mcp_object_field(response, 'error')
	assert (error['code'] or { json2.null }).int() == -32700
}

fn test_mcp_dispatch_uses_top_level_method() {
	mut app := &App{ capture_output: true }
	body := '{"jsonrpc":"2.0","id":"init-1","params":{"protocolVersion":"2024-11-05","capabilities":{"experimental":{"method":"ping"}},"clientInfo":{"name":"probe","version":"1"}},"method":"initialize"}'
	handle_mcp_message(mut app, body)
	assert app.captured_output.len == 1
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	assert (response['id'] or { json2.null }).str() == 'init-1'
	result := (response['result'] or { json2.null }).as_map()
	assert (result['protocolVersion'] or { json2.null }).str() == '2024-11-05'
}

fn test_mcp_completion_uses_filtered_completion_pipeline() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_mcp_test_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut app := &App{
		open_files:     map[string]string{}
		temp_dir:       temp_dir
		capture_output: true
	}
	project_dir := os.join_path(temp_dir, 'mcp_completion')
	os.mkdir_all(project_dir) or { panic(err) }
	path := os.join_path(project_dir, 'main.v')
	content := 'module main\n\nfn apple() {}\nfn banana() {}\n\nfn main() {\n\tapp\n}\n'
	mcp_test_write_file(path, content)
	line := content.split_into_lines().index('\tapp')
	assert line >= 0
	character := content.split_into_lines()[line].len
	body := json2.encode({
		'jsonrpc': json2.Any('2.0')
		'id':      json2.Any('completion-1')
		'method':  json2.Any('tools/call')
		'params':  json2.Any({
			'name':      json2.Any('vls_completion')
			'arguments': json2.Any({
				'path':      json2.Any(path)
				'line':      json2.Any(line)
				'character': json2.Any(character)
			})
		})
	})
	handle_mcp_message(mut app, body)
	assert app.captured_output.len == 1
	response := json2.decode_standard[map[string]json2.Any](app.captured_output[0].trim_space()) or {
		panic(err)
	}
	result := (response['result'] or { json2.null }).as_map()
	contents := (result['content'] or { json2.null }).as_array()
	assert contents.len == 1
	text := mcp_string_field(contents[0].as_map(), 'text')
	completion := json2.decode_standard[map[string]json2.Any](text) or { panic(err) }
	items := (completion['items'] or { json2.null }).as_array()
	labels := items.map(mcp_string_field(it.as_map(), 'label'))
	assert 'apple' in labels
	assert 'banana' !in labels
}

// P2: notifications (no id) must never receive a response.
fn test_mcp_notification_gets_no_response() {
	mut app := &App{ capture_output: true }
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"reason":"x"}}')
	assert app.captured_output.len == 0
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","method":"notifications/initialized"}')
	assert app.captured_output.len == 0
}

// strip_non_code_segments blanks single-line string contents and cuts line
// comments so the map-init scan below only sees real code.
fn strip_non_code_segments(line string) string {
	mut out := []u8{cap: line.len}
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `"` || c == `'` {
			quote := c
			i++
			for i < line.len && line[i] != quote {
				if line[i] == `\\` && i + 1 < line.len {
					i += 2
					continue
				}
				i++
			}
			i++ // past the closing quote (or EOL on unterminated input)
			out << ` `
			continue
		}
		if c == `/` && i + 1 < line.len && line[i + 1] == `/` {
			break
		}
		out << c
		i++
	}
	return out.bytestr()
}

// explicit_map_init_offenders lists `path:line` rows for non-empty map
// literals written with explicit type parameters (`map[string]T{...}` with
// entries). Released V compilers reject that form (`explicit map
// initialization does not support parameters`), so letting one into the tree
// breaks `v .` builds and the `v ls --install` source fallback on stable
// toolchains. Empty `map[string]T{}` literals and inferred `{...}` literals
// are fine and are not reported.
fn explicit_map_init_offenders(files []string) []string {
	mut offenders := []string{}
	for path in files {
		content := os.read_file(path) or { continue }
		lines := content.split_into_lines()
		for idx in 0 .. lines.len {
			code := strip_non_code_segments(lines[idx])
			mut search := 0
			for {
				rel := code[search..].index('map[string') or { break }
				start := search + rel
				// `map[` in type position, not a literal: a fn return
				// type (`)`, `!` before it) or an `is` type test.
				mut b := start - 1
				for b >= 0 && (code[b] == ` ` || code[b] == `\t`) {
					b--
				}
				if b >= 0 && (code[b] == `)` || code[b] == `!`) {
					search = start + 1
					continue
				}
				if b >= 0 && code[b].is_letter() {
					mut w := b
					for w >= 0 && (code[w].is_letter() || code[w] == `_`) {
						w--
					}
					if code[w + 1..b + 1] == 'is' {
						search = start + 1
						continue
					}
				}
				// The value type is one token (dots allowed for
				// qualified types like `json2.Any`); anything else (`,`,
				// `)`, `=`) means a declaration, parameter, or return type.
				rest := code[start + 'map[string'.len..]
				mut t := 0
				for t < rest.len {
					c := rest[t]
					if !(c.is_letter() || c.is_digit() || c == `_` || c == `?` || c == `&`
						|| c == `|` || c == `[` || c == `]` || c == `.`) {
						break
					}
					t++
				}
				after_type := rest[t..].trim_left(' \t')
				if !after_type.starts_with('{') {
					search = start + 1
					continue
				}
				after := after_type[1..].trim_space()
				if after.starts_with('}') {
					// empty `map[string]T{}` literal; keep scanning the line
					search = start + 1
					continue
				}
				if after == '' {
					// `{` ends the line: entries on following lines are the
					// banned shape, unless the next line just closes it.
					mut j := idx + 1
					for j < lines.len && lines[j].trim_space() == '' {
						j++
					}
					if j < lines.len
						&& strip_non_code_segments(lines[j]).trim_space().starts_with('}') {
						break
					}
				}
				offenders << '${path}:${idx + 1}: ${lines[idx].trim_space()}'
				break
			}
		}
	}
	return offenders
}

fn test_sources_have_no_explicit_nonempty_map_init() {
	src_dir := os.dir(@FILE)
	entries := os.ls(src_dir) or { panic(err) }
	mut files := []string{}
	for entry in entries {
		if entry.ends_with('.v') && !entry.starts_with('.') {
			files << os.join_path(src_dir, entry)
		}
	}
	offenders := explicit_map_init_offenders(files)
	assert offenders.len == 0, 'map init with explicit type params is rejected by released V:\n' + offenders.join('\n')
}

fn test_explicit_map_init_scan_catches_banned_form() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_map_scan_${os.getpid()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	bad := os.join_path(temp_dir, 'bad.v')
	os.write_file(bad, "module main\nfn main() {\n\tmut m := map[string]int{\n\t\t'a': 1\n\t}\n\tmut m2 := json2.Any(map[string]json2.Any{\n\t\t'b': json2.Any(2)\n\t})\n\tprintln(m)\n\tprintln(m2)\n}\n") or {
		panic(err)
	}
	good := os.join_path(temp_dir, 'good.v')
	os.write_file(good, 'module main\n// map[string]int{\'a\': 1} in a comment is fine\nfn main() {\n\tmut e := map[string]int{}\n\tmut i := {\'a\': 1}\n\tcontent := "ages := map[string]int{\\n\\t\\t\'a\': 1\\n\\t}\\n"\n\tprintln(e)\n\tprintln(i)\n\tprintln(content)\n}\n') or {
		panic(err)
	}
	offenders := explicit_map_init_offenders([bad, good])
	assert offenders.len == 2
	assert offenders[0].contains('bad.v')
	assert offenders[1].contains('bad.v')
}

fn test_mcp_hover_without_result_returns_null_contents() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_mcp_hover_null_${os.getpid()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	path := os.join_path(temp_dir, 'main.v')
	mcp_test_write_file(path, 'module main\nfn main() {}\n\n')
	mut app := &App{ capture_output: true }
	body := json2.encode({
		'jsonrpc': json2.Any('2.0')
		'id':      json2.Any('hover-null')
		'method':  json2.Any('tools/call')
		'params':  json2.Any({
			'name':      json2.Any('vls_hover')
			'arguments': json2.Any({
				'path':      json2.Any(path)
				'line':      json2.Any(2)
				'character': json2.Any(0)
			})
		})
	})
	handle_mcp_message(mut app, body)
	assert app.captured_output.len >= 1
	// Select the tool response by id: depending on the configured V
	// compiler, an unrelated window/showMessage notice (missing V1
	// compatibility compiler) may be captured alongside it.
	mut found := ''
	for m in app.captured_output {
		if m.contains('"id":"hover-null"') {
			found = m
		}
	}
	assert found != '', 'missing tools/call response among ${app.captured_output.len} captured message(s)'
	response := json2.decode_standard[map[string]json2.Any](found.trim_space()) or {
		panic(err)
	}
	assert 'error' !in response
	result := mcp_object_field(response, 'result')
	assert json2.encode(result['isError'] or { json2.null }) == 'false'
	content := (result['content'] or { json2.null }).as_array()
	assert content.len == 1
	assert mcp_string_field(content[0].as_map(), 'text') == '{"contents":null}'
}
