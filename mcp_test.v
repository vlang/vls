// Tests for MCP JSON-RPC parsing, responses, and tool argument handling.

module main

import json2
import os
import time

fn mcp_test_write_file(path string, content string) {
	os.write_file(path, content) or { panic(err) }
}

fn test_mcp_json2_decodes_nested_arguments() {
	body := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"vls_definition","arguments":{"path":"/tmp/main.v","line":10,"character":5}}}'
	request := mcp_request_object(body) or { panic(err) }
	params := mcp_object_field(request, 'params')
	args := mcp_object_field(params, 'arguments')
	assert mcp_string_field(params, 'name') == 'vls_definition'
	assert mcp_string_field(args, 'path') == '/tmp/main.v'
	assert mcp_int_field(args, 'line') == 10
	assert mcp_int_field(args, 'character') == 5
}

fn test_mcp_json2_keeps_rename_argument_and_decodes_escapes() {
	body := '{"params":{"name":"vls_rename","arguments":{"path":"/tmp/main.v","line":3,"character":7,"newName":"count"}}}'
	request := mcp_request_object(body) or { panic(err) }
	args := mcp_object_field(mcp_object_field(request, 'params'), 'arguments')
	assert mcp_string_field(args, 'path') == '/tmp/main.v'
	assert mcp_int_field(args, 'line') == 3
	assert mcp_int_field(args, 'character') == 7
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
	assert mcp_int_field(params, 'id') == 7
}

fn test_mcp_send_message_uses_newline_framing() {
	mut app := &App{ capture_output: true }
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

fn test_mcp_install_config_is_json2_encoded() {
	config := json2.decode_standard[map[string]json2.Any](mcp_install_config()) or {
		panic(err)
	}
	servers := mcp_object_field(config, 'mcpServers')
	server := mcp_object_field(servers, 'vls')
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
	body := json2.encode(map[string]json2.Any{
		'jsonrpc': json2.Any('2.0')
		'id':      json2.Any('completion-1')
		'method':  json2.Any('tools/call')
		'params':  json2.Any(map[string]json2.Any{
			'name':      json2.Any('vls_completion')
			'arguments': json2.Any(map[string]json2.Any{
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
