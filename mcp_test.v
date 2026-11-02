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

// String request IDs must round-trip verbatim (with quotes) for responses.
fn test_mcp_json_raw_field_preserves_string_id() {
	body := '{"jsonrpc":"2.0","id":"request-1","method":"initialize"}'
	assert mcp_json_raw_field(body, 'id') == '"request-1"'
	assert mcp_json_raw_field(body, 'missing') == 'null'
}

// Balanced-object parsing must skip braces inside strings.
fn test_mcp_object_at_skips_braces_in_strings() {
	assert mcp_object_at('{"a":"}","b":1} trailing') == '{"a":"}","b":1}'
	assert mcp_object_at('{"a":1') == ''
}
