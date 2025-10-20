module main

// This is a simple LSP tester.
// Usage : v run lsp_test_main.v /tmp/vls2
import os
import x.json2 as json
import time

const test_directory = os.join_path(os.real_path(os.vtmp_dir()), 'lsp_test')
const test_file = os.join_path(test_directory, 'test.v')

struct LSPMessage {
	jsonrpc string = '2.0'
	id      int
	method  string
	params  map[string]json.Any
}

struct LSPResponse {
	jsonrpc string = '2.0'
	id      int
	result  map[string]json.Any
	error   map[string]json.Any
}

struct LSPNotification {
	jsonrpc string = '2.0'
	method  string
	params  map[string]json.Any
}

struct TestResult {
mut:
	name     string
	success  bool
	message  string
	duration f64
}

struct LSPServer {
mut:
	process &os.Process = unsafe { nil }
}

fn main() {
	println('=== LSP Server Test Program ===')
	if os.args.len != 2 {
		println('Usage: ${os.args[0]} path_to_vls')
		exit(0)
	}

	// Configure test parameters
	server_path := os.args[1]

	// Create test directory
	os.mkdir_all(test_directory) or {
		println('Failed to create test directory: ${err}')
		return
	}
	defer {
		os.rmdir(test_directory) or {}
	}

	// Start server
	mut server := start_server(server_path, test_directory) or {
		println('Failed to start server: ${err}')
		return
	}

	// Run test suite
	mut results := []TestResult{}

	results << lsp_test_initialize(mut server)!
	results << lsp_test_did_open(mut server, test_directory)!
	results << lsp_test_completion(mut server)!
	results << lsp_test_shutdown(mut server)!

	// Stop server
	stop_server(mut server) or { println('Failed to stop server: ${err}') }

	// Print test results
	print_results(results)
}

// Start LSP server
fn start_server(server_path string, workspace_dir string) !LSPServer {
	println('Starting server: ${server_path}')

	if !os.exists(server_path) {
		return error('Server path does not exist: ${server_path}')
	}

	mut server := LSPServer{}

	// Start process
	server.process = os.new_process(server_path)
	server.process.set_redirect_stdio()
	server.process.set_work_folder(workspace_dir)

	server.process.run()

	// Wait for server to start
	time.sleep(1000)

	println('Server started successfully, PID: ${server.process.pid}')
	return server
}

// Stop server
fn stop_server(mut server LSPServer) ! {
	if server.process.is_alive() {
		println('Stopping server...')
		server.process.signal_kill()
	}
	server.process.close()
}

// Send LSP message
fn send_message(mut server LSPServer, message string) ! {
	message_json := json.decode[map[string]json.Any](message)!
	message_json2 := json.encode(message_json)
	content_length := message_json2.len

	header := 'Content-Length: ${content_length}\r\n\r\n'
	full_message := '${header}${message_json2}'

	println('-->Sending message: ${message_json2}')
	server.process.stdin_write(full_message)
}

// Receive LSP message
fn receive_message(mut server LSPServer) !map[string]json.Any {
	mut header_buffer := ''
	mut content_length := -1

	// Read header
	for {
		buffer := server.process.stdout_read()
		header_buffer += buffer

		// Find Content-Length
		if header_buffer.contains('Content-Length:') {
			lines := header_buffer.split('\r\n')
			for line in lines {
				if line.starts_with('Content-Length:') {
					length_str := line.all_after(':').trim_space()
					content_length = length_str.int()
					break
				}
			}

			// Find header end marker
			header_end := header_buffer.index('\r\n\r\n') or { -1 }
			if header_end != -1 {
				// Skip header
				header_buffer = header_buffer[header_end + 4..]
				break
			}
		}

		if header_buffer.len > 4096 {
			return error('Header too long')
		}
	}

	if content_length == -1 {
		return error('Content-Length not found')
	}

	// Read message body
	mut message_body := header_buffer
	for message_body.len < content_length {
		buffer := server.process.stdout_read()
		message_body += buffer
	}

	if message_body.len > content_length {
		message_body = message_body[..content_length]
	}

	println('<--Received message: ${message_body}')

	// Parse JSON
	return json.decode[map[string]json.Any](message_body)!
}

// Test 1: Initialize request
fn lsp_test_initialize(mut server LSPServer) !TestResult {
	println('\n')
	println(@FN)
	mut result := TestResult{
		name:     'Initialize Request'
		success:  false
		message:  ''
		duration: 0.0
	}

	start_time := time.ticks()

	defer {
		result.duration = f64(time.ticks() - start_time) / 1000.0
	}

	message := '{
		"id":	0,
		"method":	"initialize",
		"jsonrpc":	"2.0",
		"params":	{
			"contentChanges":	[],
			"position":	{
				"line":	0,
				"character":	0
			},
			"textDocument":	{
				"uri":	""
			}
		}
	}'

	send_message(mut server, message)!

	response := receive_message(mut server)!

	// Validate response
	check_valid_jsonrpc(response)!
	check_valid_id(response, 0)!

	if 'result' !in response {
		result.message = 'Response missing result field'
		return result
	}
	if result_obj := response['result'] {
		if 'capabilities' !in result_obj.as_map() {
			result.message = 'Response missing capabilities field'
			return result
		}
	}

	result.success = true
	result.message = 'Initialize successful'
	return result
}

// Test 2: Open document notification
fn lsp_test_did_open(mut server LSPServer, test_directory string) !TestResult {
	println('\n')
	println(@FN)
	mut result := TestResult{
		name:     'Open Document Notification'
		success:  false
		message:  ''
		duration: 0.0
	}

	start_time := time.ticks()

	defer {
		result.duration = f64(time.ticks() - start_time) / 1000.0
	}

	// Create test file
	test_content := "module main\n\nfn main() {\n    println('Hello, World!')\n}"
	os.write_file(test_file, test_content)!

	message := '{
		"jsonrpc" : "2.0",
		"method" : "textDocument/didOpen",
		"params" : {
			"textDocument" : {
				"uri" : "file:///${test_file}",
				"languageId" : "v",
				"version" : 1,
				"text" : "${test_content}"
			}
		}
	}'

	send_message(mut server, message)!

	// Open document is a notification, no response expected
	time.sleep(500)

	result.success = true
	result.message = 'Open document notification sent successfully'
	return result
}

// Test 3: Code completion request
fn lsp_test_completion(mut server LSPServer) !TestResult {
	println('\n')
	println(@FN)
	mut result := TestResult{
		name:     'Code Completion Request'
		success:  false
		message:  ''
		duration: 0.0
	}

	start_time := time.ticks()

	defer {
		result.duration = f64(time.ticks() - start_time) / 1000.0
	}

	message := '{
		"jsonrpc" : "2.0",
		"id" : 2,
		"method" : "textDocument/completion",
		"params" : {
			"textDocument" : {
				"uri" : "file:///${test_file}"
			},
			"position" : {
				"line" : 2,
				"character" : 5
			}
		}
	}'

	send_message(mut server, message)!
	response := receive_message(mut server)!

	// Validate response
	check_valid_jsonrpc(response)!
	check_valid_id(response, 2)!

	// Completion response may contain result or error
	if 'result' !in response && 'error' !in response {
		result.message = 'Response missing result or error field'
		return result
	}

	result.success = true
	result.message = 'Code completion request successful'
	return result
}

// Test 4: Shutdown server
fn lsp_test_shutdown(mut server LSPServer) !TestResult {
	println('\n')
	println(@FN)
	mut result := TestResult{
		name:     'Shutdown Server'
		success:  false
		message:  ''
		duration: 0.0
	}

	start_time := time.ticks()

	defer {
		result.duration = f64(time.ticks() - start_time) / 1000.0
	}

	// Send shutdown request
	shutdown_message := '{
		"jsonrpc" : "2.0",
		"id" : 3,
		"method" : "shutdown"
	}'

	send_message(mut server, shutdown_message)!

	response := receive_message(mut server)!

	// Validate shutdown response
	check_valid_jsonrpc(response)!
	check_valid_id(response, 3)!

	// Send exit notification
	exit_message := '{
		"jsonrpc" : "2.0",
		"method" : "exit"
	}'

	send_message(mut server, exit_message) or {
		result.message = 'Failed to send exit notification: ${err}'
		return result
	}

	result.success = true
	result.message = 'Server shutdown successful'
	return result
}

// Print test results
fn print_results(results []TestResult) {
	println('\n=== Test Results ===')

	mut total_tests := 0
	mut passed_tests := 0
	mut total_duration := 0.0

	for result in results {
		total_tests++
		total_duration += result.duration

		status := if result.success { '✓' } else { '✗' }
		println('${status} ${result.name} - ${result.message} (${result.duration:.2f}s)')

		if result.success {
			passed_tests++
		} else {
			println('  Error: ${result.message}')
		}
	}

	println('\n=== Summary ===')
	println('Total tests: ${total_tests}')
	println('Passed: ${passed_tests}')
	println('Failed: ${total_tests - passed_tests}')
	println('Total duration: ${total_duration:.2f}s')

	success_rate := if total_tests > 0 { f64(passed_tests) / f64(total_tests) * 100.0 } else { 0.0 }
	println('Success rate: ${success_rate:.1f}%')

	if passed_tests == total_tests {
		println('\n🎉 All tests passed!')
	} else {
		println('\n❌ Some tests failed, please check server implementation.')
	}
}

fn check_valid_jsonrpc(response map[string]json.Any) ! {
	if x := response['jsonrpc'] {
		if x.str() != '2.0' {
			return error('Invalid JSON-RPC version: ${x.str()}')
		}
	} else {
		return error('No JSON-RPC version')
	}
}

fn check_valid_id(response map[string]json.Any, id int) ! {
	if x := response['id'] {
		if x.int() != id {
			return error('Invalid id: ${x.int()}')
		}
	} else {
		return error('No id')
	}
}
