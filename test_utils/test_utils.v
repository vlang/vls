module test_utils

import json
import jsonrpc
import jsonrpc.server_test_utils
import os
import io
import lsp
import benchmark
import v.util.diff

const diff_cmd = diff.find_working_diff_command() or { '' }

struct TestResponse {
	jsonrpc string = jsonrpc.version
	id      int
	result  string                [raw]
	error   jsonrpc.ResponseError
}

struct TestNotification {
	jsonrpc string = jsonrpc.version
	method  string
	params  string [raw]
}

pub struct Tester {
pub:
	test_files_dir string [required]
	folder_name    string
pub mut:
	bench  benchmark.Benchmark = benchmark.new_benchmark()
	client &server_test_utils.TestClient
}

pub fn (mut t Tester) initialize() !TestFilesIterator {
	t.client.send[lsp.InitializeParams, lsp.InitializeResult]('initialize', lsp.InitializeParams{
		root_uri: lsp.document_uri_from_path(os.join_path(t.test_files_dir, t.folder_name))
	}) or {
		if err is io.Eof {
			return error('')
		}
		return err
	}

	files := load_test_file_paths(t.test_files_dir, t.folder_name)!
	t.bench.set_total_expected_steps(files.len)
	return TestFilesIterator{
		file_paths: files
		tester: unsafe { t }
	}
}

pub fn (mut t Tester) fail(file TestFile, msg string) {
	final_msg := if msg.len == 0 { '<unknown error>' } else { msg }
	println(t.bench.step_message_fail('${file.file_name}: ${final_msg}'))
	t.bench.fail()
}

pub fn (mut t Tester) ok(file TestFile) {
	println(t.bench.step_message_ok(file.file_name))
	t.bench.ok()
}

pub fn (mut t Tester) is_equal[T](expected T, actual T) ! {
	if expected != actual {
		println(diff.color_compare_strings(test_utils.diff_cmd, 'vls_${t.folder_name}_test',
			expected.str(), actual.str()))
		return error('actual != expected')
	}
}

pub fn (mut t Tester) is_null(file TestFile, fail_criteria bool, err IError) {
	if fail_criteria && (err is none || err.str() == 'none') {
		t.ok(file)
	} else {
		t.fail(file, err.msg())
	}
}

pub fn (t &Tester) is_ok() bool {
	return t.bench.nfail == 0
}

pub fn (mut t Tester) diagnostics() !lsp.PublishDiagnosticsParams {
	got := t.client.stream.last_notification_at_method[lsp.PublishDiagnosticsParams]('textDocument/publishDiagnostics')!
	return got.params
}

pub fn (mut t Tester) count_errors(file TestFile) int {
	params := t.diagnostics() or { return 0 }
	if params.uri.path() != file.file_path {
		return 0
	}

	mut count := 0
	for diag in params.diagnostics {
		eprintln(diag)
		if diag.severity == .error {
			count++
		}
	}
	return count
}

// open_document generates and returns the request data for the `textDocument/didOpen` reqeust.
pub fn (mut t Tester) open_document(file TestFile) !lsp.TextDocumentIdentifier {
	doc_uri := lsp.document_uri_from_path(file.file_path)
	t.client.notify('textDocument/didOpen', lsp.DidOpenTextDocumentParams{
		text_document: lsp.TextDocumentItem{
			uri: doc_uri
			language_id: 'v'
			version: 1
			text: file.contents
		}
	})!
	return lsp.TextDocumentIdentifier{
		uri: doc_uri
	}
}

// close_document generates and returns the request data for the `textDocument/didClose` reqeust.
pub fn (mut t Tester) close_document(doc_id lsp.TextDocumentIdentifier) ! {
	t.client.notify('textDocument/didClose', lsp.DidCloseTextDocumentParams{
		text_document: doc_id
	})!
}

pub struct TestFile {
pub:
	file_name string [required]
	file_path string [required]
	contents  string
}

pub struct TestFilesIterator {
mut:
	tester &Tester
	idx    int = -1
pub mut:
	file_paths []string
}

pub fn (iter &TestFilesIterator) get(idx int) !TestFile {
	test_file_path := iter.file_paths[idx]
	test_file_name := os.base(test_file_path)
	content := os.read_file(test_file_path)!
	return TestFile{
		file_name: test_file_name
		file_path: test_file_path
		contents: content
	}
}

pub fn (mut iter TestFilesIterator) next() ?TestFile {
	iter.idx++
	if iter.idx >= iter.file_paths.len {
		iter.tester.bench.stop()
		return none
	}

	iter.tester.bench.step()
	test_file := iter.get(iter.idx) or {
		iter.tester.fail(TestFile{
			file_name: os.base(iter.file_paths[iter.idx])
			file_path: ''
		}, 'file is missing')
		return iter.next()
	}

	return test_file
}

pub struct Testio {
pub:
	test_files_dir string
mut:
	nr_responses     int
	max_nr_responses int = 5
	current_req_id   int = 1
	decoded_resp_idx int = -1
	response         TestResponse // parsed response data from raw_response
pub mut:
	bench         benchmark.Benchmark = benchmark.new_benchmark()
	raw_responses []string // raw JSON string of the response data
	debug         bool
}

pub fn (mut io Testio) send(data string) {
	io.nr_responses++
	if io.nr_responses > io.max_nr_responses {
		io.nr_responses = 0
		io.raw_responses.clear()
	}
	io.raw_responses << data
}

pub fn (io Testio) receive() ?string {
	return ''
}

pub fn (mut io Testio) init() ? {
	io.nr_responses = 0
	io.raw_responses = []string{cap: io.max_nr_responses}
}

// request returns a JSON string of JSON-RPC request with empty parameters.
pub fn (mut io Testio) request(method string) string {
	return io.request_with_params(method, map[string]string{})
}

// request_with_params returns a JSON string of JSON-RPC request with parameters.
pub fn (mut io Testio) request_with_params[T](method string, params T) string {
	enc_params := json.encode(params)
	payload := '{"jsonrpc":"${jsonrpc.version}","id":${io.current_req_id},"method":"${method}","params":${enc_params}}'
	io.current_req_id++
	return payload
}

// result returns the response result/notification params.
pub fn (mut io Testio) result() string {
	io.decode_response_at_index(io.raw_responses.len - 1) or { return '' }
	return io.response.result
}

// notification returns the parameters of the notification.
pub fn (io Testio) notification() !(string, string) {
	return io.notification_at_index(io.raw_responses.len - 1)
}

// notification verifies the parameters of the notification.
pub fn (io Testio) notification_at_index(idx int) !(string, string) {
	resp := json.decode(TestNotification, io.raw_responses[idx])!
	return resp.method, resp.params
}

// response_error returns the error code and message from the response.
pub fn (mut io Testio) response_error() !(int, string) {
	io.decode_response_at_index(io.raw_responses.len - 1)!
	return io.response.error.code, io.response.error.message
}

fn (mut io Testio) decode_response_at_index(idx int) ! {
	if io.decoded_resp_idx != idx {
		io.response = json.decode(TestResponse, io.raw_responses[idx])!
		io.decoded_resp_idx = idx
	}
}

// get_test_files_path returns the appended location of the test file dir and dir var.
pub fn get_test_files_path(dir string) string {
	if os.is_file(dir) {
		return os.join_path(os.dir(dir), 'test_files')
	}

	return os.join_path(dir, 'tests', 'test_files')
}

// load_test_file_paths returns a list of input test file locations.
[manualfree]
pub fn (io &Testio) load_test_file_paths(folder_name string) ![]string {
	return load_test_file_paths(io.test_files_dir, folder_name)
}

// load_test_file_paths returns a list of input test file locations.
[manualfree]
pub fn load_test_file_paths(test_files_dir string, folder_name string) ![]string {
	current_os := os.user_os()
	target_path := os.join_path(test_files_dir, folder_name)
	dir := os.ls(target_path) or { return error('error loading test files for "${folder_name}"') }
	mut filtered := []string{cap: dir.len}
	skip_os_file_ext := '_skip_${current_os}.vv'
	for path in dir {
		if (path.ends_with('.vv') && !path.ends_with('_skip.vv')
			&& !path.ends_with(skip_os_file_ext)) || path.ends_with('.test.txt') {
			filtered << os.join_path(target_path, path)
		}
	}
	// unsafe { dir.free() }
	if filtered.len == 0 {
		return error('no test files found for "${folder_name}"')
	}
	filtered.sort()
	return filtered
}

// save_document generates and returns the request data for the `textDocument/didSave` request.
pub fn (mut io Testio) save_document(file_path string, contents string) (string, lsp.TextDocumentIdentifier) {
	doc_uri := lsp.document_uri_from_path(file_path)
	docid := lsp.TextDocumentIdentifier{
		uri: doc_uri
	}
	req := io.request_with_params('textDocument/didSave', lsp.DidSaveTextDocumentParams{
		text_document: docid
		text: contents
	})
	return req, docid
}

// open_document generates and returns the request data for the `textDocument/didOpen` reqeust.
pub fn (mut io Testio) open_document(file_path string, contents string) (string, lsp.TextDocumentIdentifier) {
	doc_uri := lsp.document_uri_from_path(file_path)
	req := io.request_with_params('textDocument/didOpen', lsp.DidOpenTextDocumentParams{
		text_document: lsp.TextDocumentItem{
			uri: doc_uri
			language_id: 'v'
			version: 1
			text: contents
		}
	})
	docid := lsp.TextDocumentIdentifier{
		uri: doc_uri
	}
	return req, docid
}

// close_document generates and returns the request data for the `textDocument/didClose` reqeust.
pub fn (mut io Testio) close_document(doc_id lsp.TextDocumentIdentifier) string {
	return io.request_with_params('textDocument/didClose', lsp.DidCloseTextDocumentParams{
		text_document: doc_id
	})
}

// file_errors parses and returns the list of file errors received
// from the server after executing the `textDocument/didOpen` request.
pub fn (mut io Testio) file_errors() ![]lsp.Diagnostic {
	mut errors := []lsp.Diagnostic{}
	_, diag_params := io.notification()!
	diag_info := json.decode(lsp.PublishDiagnosticsParams, diag_params)!
	for diag in diag_info.diagnostics {
		if diag.severity != .error {
			continue
		}
		errors << diag
	}
	return errors
}
