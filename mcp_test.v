// Tests for the minimal MCP server's JSON helpers: the arguments object
// must survive intact (P1), and string escapes must decode (P2).

module main

// P1: an arguments object with several keys must come back complete, so
// positional tools do not run at (0, 0).
fn test_mcp_json_nested_returns_full_arguments_object() {
	body := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"vls_definition","arguments":{"path":"/tmp/main.v","line":10,"character":5}}}'
	args := mcp_json_nested(body, 'params', 'arguments')
	assert mcp_json_field(args, 'path') == '/tmp/main.v'
	assert mcp_json_field(args, 'line') == '10'
	assert mcp_json_field(args, 'character') == '5'
	assert mcp_json_nested(body, 'params', 'name') == 'vls_definition'
}

// P1: rename must keep newName alongside the position.
fn test_mcp_json_nested_keeps_new_name() {
	body := '{"params":{"name":"vls_rename","arguments":{"path":"/tmp/main.v","line":3,"character":7,"newName":"count"}}}'
	args := mcp_json_nested(body, 'params', 'arguments')
	assert mcp_json_field(args, 'path') == '/tmp/main.v'
	assert mcp_json_field(args, 'line') == '3'
	assert mcp_json_field(args, 'character') == '7'
	assert mcp_json_field(args, 'newName') == 'count'
}

// P2: a JSON path holding a literal backslash must decode to one backslash.
fn test_mcp_json_field_decodes_backslash_escapes() {
	body := '{"path":"C:\\\\Users\\\\dev\\\\main.v"}'
	assert mcp_json_field(body, 'path') == 'C:\\Users\\dev\\main.v'
}

// P2: \uXXXX escapes must decode, including surrogate pairs.
fn test_mcp_json_field_decodes_unicode_escapes() {
	body := '{"path":"/tmp/\\u00e9.v"}'
	assert mcp_json_field(body, 'path') == '/tmp/' + rune(0xe9).str() + '.v'
	assert mcp_json_field('{"name":"\\ud83d\\ude00"}', 'name') == rune(0x1F600).str()
}

// The production ID extractor must preserve strings and ignore nested IDs.
fn test_mcp_top_level_raw_field_preserves_string_id() {
	body := '{"jsonrpc":"2.0","id":"request-1","method":"initialize","params":{"id":7}}'
	assert mcp_top_level_raw_field(body, 'id') == '"request-1"'
	assert mcp_top_level_raw_field(body, 'missing') == 'null'
}

fn test_mcp_send_message_uses_newline_framing() {
	mut app := &App{ capture_output: true }
	app.send_mcp_message('{"jsonrpc":"2.0","id":1,"result":{}}')
	assert app.captured_output == ['{"jsonrpc":"2.0","id":1,"result":{}}\n']
}

// Balanced-object parsing must skip braces inside strings.
fn test_mcp_object_at_skips_braces_in_strings() {
	assert mcp_object_at('{"a":"}","b":1} trailing') == '{"a":"}","b":1}'
	assert mcp_object_at('{"a":1') == ''
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

// P2: notifications (no id) must never receive a response.
fn test_mcp_notification_gets_no_response() {
	mut app := &App{ capture_output: true }
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"reason":"x"}}')
	assert app.captured_output.len == 0
	handle_mcp_message(mut app, '{"jsonrpc":"2.0","method":"notifications/initialized"}')
	assert app.captured_output.len == 0
}
