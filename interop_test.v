// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json2
import time

fn interop_test_must_mkdir_all(path string) {
	os.mkdir_all(path) or {
		assert false, 'Failed to create directory ${path}: ${err}'
		return
	}
}

fn interop_test_must_write_file(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'Failed to write file ${path}: ${err}'
		return
	}
}

// ============================================================================
// Unit tests for interop utilities (URI/path conversion)
// ============================================================================

// --- uri_to_path tests ---

fn test_uri_to_path_unix_style() {
	// Standard Unix path
	assert uri_to_path('file:///home/user/project/main.v') == '/home/user/project/main.v'
	assert uri_to_path('file:///tmp/test.v') == '/tmp/test.v'
	assert uri_to_path('file:///root/vls/handlers.v') == '/root/vls/handlers.v'
}

fn test_uri_to_path_windows_style() {
	// Windows path with drive letter
	result := uri_to_path('file:///C:/Users/test/project/main.v')
	// On Unix systems, this should strip the leading slash before the drive letter
	assert result == 'C:/Users/test/project/main.v' || result == '/C:/Users/test/project/main.v'
}

fn test_uri_to_path_with_file_prefix() {
	// Both file:// and file:/// prefixes should work
	result1 := uri_to_path('file:///path/to/file.v')
	result2 := uri_to_path('file://path/to/file.v')
	// file:// removes 7 characters, leaving /path/to/file.v or path/to/file.v
	assert result1.contains('file.v')
	assert result2.contains('file.v')
}

fn test_uri_to_path_no_prefix() {
	// If no file:// prefix, should return as-is
	assert uri_to_path('/home/user/test.v') == '/home/user/test.v'
	assert uri_to_path('relative/path.v') == 'relative/path.v'
}

fn test_uri_to_path_special_characters() {
	// Percent-encoded spaces must be decoded to real spaces (P0-10).
	result := uri_to_path('file:///home/user/my%20project/test.v')
	assert result == '/home/user/my project/test.v'
}

fn test_uri_to_path_percent_encoded_hash_and_percent() {
	// %23 -> '#', %25 -> '%' must round back to the literal characters.
	assert uri_to_path('file:///home/user/a%23b.v') == '/home/user/a#b.v'
	assert uri_to_path('file:///home/user/100%25.v') == '/home/user/100%.v'
}

fn test_uri_to_path_localhost_authority_is_local() {
	// A `localhost` authority denotes the local machine (RFC 8089), so the path
	// must resolve to the local file, not a //localhost/... UNC-style path.
	assert uri_to_path('file://localhost/tmp/main.v') == '/tmp/main.v'
	assert uri_to_path('file://LOCALHOST/tmp/main.v') == '/tmp/main.v'
	// A genuine remote authority is still preserved as a UNC path.
	assert uri_to_path('file://server/share/main.v') == '//server/share/main.v'
}

fn test_uri_to_path_drops_fragment_and_query() {
	assert uri_to_path('file:///home/user/test.v#L10') == '/home/user/test.v'
	assert uri_to_path('file:///home/user/test.v?rev=2') == '/home/user/test.v'
}

fn test_uri_path_roundtrip_with_spaces_and_hash() {
	for original in ['/home/user/my project/a#b.v', '/tmp/weird %name%.v', '/a/plus+file.v'] {
		uri := path_to_uri(original)
		// The URI must not contain a raw space.
		assert !uri.contains(' ')
		assert uri_to_path(uri) == original
	}
}

fn test_path_to_uri_encodes_space() {
	assert path_to_uri('/home/user/my project/a.v') == 'file:///home/user/my%20project/a.v'
}

fn test_uri_to_path_empty_string() {
	result := uri_to_path('')
	assert result == ''
}

fn test_uri_to_path_root() {
	result := uri_to_path('file:///')
	assert result == '/' || result == ''
}

fn test_uri_to_path_nested_deep() {
	result := uri_to_path('file:///a/b/c/d/e/f/g/h/i/j/file.v')
	assert result == '/a/b/c/d/e/f/g/h/i/j/file.v'
}

fn test_uri_to_path_with_dots() {
	result := uri_to_path('file:///path/./to/../file.v')
	assert result == '/path/./to/../file.v'
}

fn test_path_is_within_with_case_accepts_windows_case_differences() {
	assert path_is_within_with_case('c:/repo/src/main.v', 'C:/Repo', true)
	assert path_is_within_with_case('//server/share/FILE.v', '//SERVER/SHARE', true)
	assert !path_is_within_with_case('c:/repository/main.v', 'C:/Repo', true)
	assert !path_is_within_with_case('c:/repo/src/main.v', 'C:/Repo', false)
	relative := path_relative_to_with_case('c:/repo/src/Main.v', 'C:/Repo', true) or {
		assert false, 'expected a relative Windows path'
		return
	}
	assert relative == 'src/Main.v'
}

fn test_normalize_overlay_path_before_windows_containment_checks() {
	path := normalize_overlay_path(r'C:\Users\Alex\project\src\main.v')
	root := normalize_overlay_path(r'c:\users\alex\project')
	assert path == 'C:/Users/Alex/project/src/main.v'
	assert root == 'c:/users/alex/project'
	assert path_is_within_with_case(path, root, true)
	relative := path_relative_to_with_case(path, root, true) or {
		assert false, 'expected normalized Windows path to remain inside the project'
		return
	}
	assert relative == 'src/main.v'
}

// --- path_to_uri tests ---

fn test_path_to_uri_unix() {
	result := path_to_uri('/home/user/project/main.v')
	assert result == 'file:///home/user/project/main.v'
}

fn test_path_to_uri_relative() {
	// Relative paths should get file:/// prefix
	result := path_to_uri('project/main.v')
	assert result == 'file:///project/main.v'
}

fn test_path_to_uri_with_backslashes() {
	// On POSIX a backslash is a valid, literal filename character. It must be
	// percent-encoded in the URI (never left raw) and must round-trip exactly.
	original := '/home/user\\project\\main.v'
	result := path_to_uri(original)
	assert !result.contains('\\')
	assert uri_to_path(result) == original
}

fn test_path_to_uri_empty() {
	result := path_to_uri('')
	assert result == 'file:///'
}

fn test_path_to_uri_single_file() {
	result := path_to_uri('file.v')
	assert result == 'file:///file.v'
}

fn test_path_to_uri_current_dir() {
	result := path_to_uri('./file.v')
	assert result.contains('file.v')
}

fn test_path_to_uri_parent_dir() {
	result := path_to_uri('../file.v')
	assert result.contains('file.v')
}

fn test_compiler_location_reuses_equivalent_open_uri() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_compiler_location_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	path := os.join_path(temp_dir, 'main.v')
	interop_test_must_write_file(path, 'aaaa target\n')
	canonical_uri := path_to_uri(path)
	open_uri := canonical_uri.replace_once('file:///', 'file://localhost/')
	mut app := &App{
		open_files:        map[string]string{}
		position_encoding: .utf16
	}
	app.open_files[open_uri] = '🚀 target\n'

	location := app.compiler_location(path, 0, 5)

	assert location.uri == open_uri
	assert location.range.start.char == 3
	assert location.range.end.char == 3

	app.position_encoding = .utf32
	location_utf32 := app.compiler_location(path, 0, 5)
	assert location_utf32.uri == open_uri
	assert location_utf32.range.start.char == 2
}

// --- Round-trip conversion tests ---

fn test_path_uri_roundtrip() {
	// Test roundtrip conversion
	original := '/home/user/project/test.v'
	uri := path_to_uri(original)
	back := uri_to_path(uri)
	assert back == original
}

fn test_path_uri_roundtrip_multiple() {
	paths := [
		'/home/user/test.v',
		'/tmp/file.v',
		'/root/vls/main.v',
		'/a/b/c/d.v',
	]

	for path in paths {
		uri := path_to_uri(path)
		back := uri_to_path(uri)
		assert back == path
	}
}

fn test_make_singlefile_temp_path_uses_given_root() {
	temp_root := os.join_path(os.temp_dir(), 'vls_interop_temp_root')
	path := make_singlefile_temp_path(temp_root, '/tmp/example.v', 'check')
	assert path.starts_with(temp_root)
	assert path.ends_with('.v')
	assert path.contains('vls_check_')
}

fn test_make_singlefile_temp_path_has_unique_tag_for_purpose() {
	root := os.temp_dir()
	path_a := make_singlefile_temp_path(root, '/tmp/example.v', 'lineinfo')
	path_b := make_singlefile_temp_path(root, '/tmp/example.v', 'check')
	assert path_a != path_b
}

fn test_make_singlefile_temp_path_avoids_test_suffix_regression() {
	root := os.temp_dir()
	path := make_singlefile_temp_path(root, '/tmp/test.v', 'check')
	assert !path.ends_with('_test.v')
	assert path.ends_with('.v')
}

fn test_cleanup_compilation_temp_removes_singlefile_path() {
	tmppath := os.join_path(os.temp_dir(),
		'vls_cleanup_single_${os.getpid()}_${time.now().unix_nano()}.v')
	interop_test_must_write_file(tmppath, 'module main\n')
	assert os.exists(tmppath)
	cleanup_compilation_temp('', tmppath)
	assert !os.exists(tmppath)
}

fn test_cleanup_compilation_temp_removes_project_dir() {
	project_dir := os.join_path(os.temp_dir(),
		'vls_cleanup_project_${os.getpid()}_${time.now().unix_nano()}')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_write_file(os.join_path(project_dir, 'main.v'), 'module main\n')
	assert os.exists(project_dir)
	cleanup_compilation_temp(project_dir, '')
	assert !os.exists(project_dir)
}

// Compiler invocation is now argv-based (no shell). These tests assert that
// filenames — including ones containing shell metacharacters — are passed as
// single, literal argument-vector elements, so command injection is impossible.

fn test_build_v_check_args_single_passes_path_literally() {
	args := build_v_check_args_single('/tmp/a b/test.v')
	assert '/tmp/a b/test.v' in args
	assert '-vls-mode' in args
	assert '-check' in args
}

fn test_build_v_check_args_single_no_shell_injection() {
	// A path containing command substitution must remain one literal argv element.
	malicious := '/tmp/$(touch /tmp/pwned)/x.v'
	args := build_v_check_args_single(malicious)
	assert malicious in args
	// The dangerous text is never split or interpreted; it is exactly one element.
	mut count := 0
	for a in args {
		if a == malicious {
			count++
		}
	}
	assert count == 1
}

fn test_build_v_fmt_args_passes_temp_file_literally() {
	args := build_v_fmt_args('/tmp/fmt file.v')
	assert args == ['fmt', '-inprocess', '-w', '/tmp/fmt file.v']
}

fn test_build_v_line_info_args_single_embeds_line_info() {
	args := build_v_line_info_args_single('/tmp/a.v', '10:gd^5', '/tmp/a.v')
	assert '/tmp/a.v:10:gd^5' in args
	assert '-line-info' in args
}

fn test_run_v_argv_reports_missing_working_dir() {
	missing_dir := os.join_path(os.temp_dir(),
		'vls_missing_dir_${os.getpid()}_${time.now().unix_nano()}')
	original := os.getwd()
	result := run_v_argv(build_v_check_args_multifile(), missing_dir)
	assert result.exit_code != 0
	// The parent process working directory must never be mutated.
	assert os.getwd() == original
}

// ============================================================================
// Tests for v_error_to_lsp_diagnostic conversion
// ============================================================================

fn test_v_error_to_lsp_diagnostic_basic() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'undefined identifier `foo`'
		line_nr: 10
		col:     5
		len:     3
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	// LSP is 0-indexed, V parser is 1-indexed
	assert diag.range.start.line == 9
	assert diag.range.start.char == 4
	assert diag.range.end.line == 9
	assert diag.range.end.char == 7 // start_char + len = 4 + 3 = 7
	assert diag.message == 'undefined identifier `foo`'
	assert diag.severity == 1 // Error
}

fn test_v_error_to_lsp_diagnostic_first_line() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'syntax error'
		line_nr: 1
		col:     1
		len:     1
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 0
	assert diag.range.start.char == 0
	assert diag.range.end.char == 1
}

fn test_v_error_to_lsp_diagnostic_long_error() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'unexpected token'
		line_nr: 100
		col:     50
		len:     20
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 99
	assert diag.range.start.char == 49
	assert diag.range.end.char == 69 // 49 + 20
}

fn test_v_error_to_lsp_diagnostic_zero_length() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'error at position'
		line_nr: 5
		col:     10
		len:     0
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.char == 9
	assert diag.range.end.char == 9 // start + 0 = same position
}

fn test_v_error_to_lsp_diagnostic_large_line_numbers() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'error in large file'
		line_nr: 10000
		col:     200
		len:     50
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 9999
	assert diag.range.start.char == 199
	assert diag.range.end.char == 249
}

fn test_v_error_to_lsp_diagnostic_column_one() {
	v_err := JsonError{
		path:    '/test/file.v'
		message: 'error at start of line'
		line_nr: 5
		col:     1
		len:     5
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.char == 0
	assert diag.range.end.char == 5
}

// ============================================================================
// Tests for LSP data structures
// ============================================================================

fn test_position_struct() {
	pos := Position{
		line: 10
		char: 5
	}
	assert pos.line == 10
	assert pos.char == 5
}

fn test_position_struct_zero() {
	pos := Position{
		line: 0
		char: 0
	}
	assert pos.line == 0
	assert pos.char == 0
}

fn test_lsp_range_struct() {
	r := LSPRange{
		start: Position{
			line: 0
			char: 0
		}
		end:   Position{
			line: 0
			char: 10
		}
	}
	assert r.start.line == 0
	assert r.end.char == 10
}

fn test_lsp_range_multiline() {
	r := LSPRange{
		start: Position{
			line: 5
			char: 10
		}
		end:   Position{
			line: 10
			char: 5
		}
	}
	assert r.start.line < r.end.line
}

fn test_lsp_diagnostic_struct() {
	diag := LSPDiagnostic{
		range:    LSPRange{
			start: Position{
				line: 5
				char: 0
			}
			end:   Position{
				line: 5
				char: 10
			}
		}
		message:  'test error'
		severity: 1
	}
	assert diag.message == 'test error'
	assert diag.severity == 1
	assert diag.range.start.line == 5
}

fn test_lsp_diagnostic_severities() {
	// Test all severity levels
	severities := [1, 2, 3, 4] // Error, Warning, Information, Hint
	for sev in severities {
		diag := LSPDiagnostic{
			range:    LSPRange{}
			message:  'test'
			severity: sev
		}
		assert diag.severity == sev
	}
}

fn test_location_struct() {
	loc := Location{
		uri:   'file:///test/file.v'
		range: LSPRange{
			start: Position{
				line: 10
				char: 5
			}
			end:   Position{
				line: 10
				char: 15
			}
		}
	}
	assert loc.uri == 'file:///test/file.v'
	assert loc.range.start.line == 10
}

fn test_location_empty() {
	loc := Location{}
	assert loc.uri == ''
	assert loc.range.start.line == 0
}

fn test_detail_struct() {
	detail := Detail{
		kind:          6 // Function
		label:         'my_function'
		detail:        'fn my_function() string'
		documentation: 'A helper function'
	}
	assert detail.kind == 6
	assert detail.label == 'my_function'
	assert detail.detail == 'fn my_function() string'
}

fn test_detail_kinds() {
	// Test various completion item kinds
	kinds := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] // Text, Method, Function, etc.
	for k in kinds {
		detail := Detail{
			kind:  k
			label: 'test'
		}
		assert detail.kind == k
	}
}

fn test_detail_struct_with_snippet() {
	detail := Detail{
		kind:               6
		label:              'println'
		detail:             'fn println(s string)'
		documentation:      'Prints a string'
		insert_text:        'println(\${1:s})'
		insert_text_format: 2 // Snippet format
	}
	assert detail.insert_text? == 'println(\${1:s})'
	assert detail.insert_text_format? == 2
}

fn test_detail_without_snippet() {
	detail := Detail{
		kind:  6
		label: 'println'
	}
	assert detail.insert_text == none
	assert detail.insert_text_format == none
}

fn test_signature_help_struct() {
	sig := SignatureHelp{
		signatures:       [
			SignatureInformation{
				label:      'fn my_func(a int, b string) bool'
				parameters: [
					ParameterInformation{
						label: 'a int'
					},
					ParameterInformation{
						label: 'b string'
					},
				]
			},
		]
		active_signature: 0
		active_parameter: 1
	}
	assert sig.signatures.len == 1
	assert sig.active_parameter == 1
	assert sig.signatures[0].parameters.len == 2
}

fn test_signature_help_multiple_signatures() {
	sig := SignatureHelp{
		signatures:       [
			SignatureInformation{
				label: 'fn overload1(a int)'
			},
			SignatureInformation{
				label: 'fn overload2(a int, b int)'
			},
			SignatureInformation{
				label: 'fn overload3(a int, b int, c int)'
			},
		]
		active_signature: 1
		active_parameter: 0
	}
	assert sig.signatures.len == 3
	assert sig.active_signature == 1
}

fn test_signature_help_empty() {
	sig := SignatureHelp{}
	assert sig.signatures.len == 0
	assert sig.active_signature == 0
	assert sig.active_parameter == 0
}

fn test_capabilities_struct() {
	cap := Capabilities{
		capabilities: Capability{
			text_document_sync:      TextDocumentSyncOptions{
				open_close: true
				change:     1
			}
			completion_provider:     CompletionProvider{
				trigger_characters: ['.']
			}
			signature_help_provider: SignatureHelpOptions{
				trigger_characters: ['(', ',']
			}
			definition_provider:     true
		}
	}
	assert cap.capabilities.definition_provider == true
	assert cap.capabilities.completion_provider.trigger_characters == ['.']
	assert cap.capabilities.signature_help_provider.trigger_characters == ['(', ',']
	assert cap.capabilities.text_document_sync.change == 1
}

fn test_capabilities_minimal() {
	cap := Capabilities{
		capabilities: Capability{
			definition_provider: true
		}
	}
	assert cap.capabilities.definition_provider == true
	assert cap.capabilities.completion_provider.trigger_characters.len == 0
}

fn test_request_struct() {
	req := Request{
		id:      1
		method:  'textDocument/completion'
		jsonrpc: '2.0'
		params:  json2.encode(Params{
			position:      Position{
				line: 5
				char: 10
			}
			text_document: TextDocumentIdentifier{
				uri: 'file:///test.v'
			}
		},
			escape_unicode: true
		)
	}
	assert req.id == 1
	assert req.method == 'textDocument/completion'
	params := json2.decode[Params](req.params.str()) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert params.position.line == 5
}

fn test_request_params_decode_malformed_returns_error() {
	malformed := '{"textDocument":{"uri":"file:///test.v"},"position":{"line":5,"character":}}'
	if _ := json2.decode[Params](malformed) {
		assert false, 'Expected malformed params JSON to fail decoding'
	} else {
		assert true
	}
}

fn test_response_struct() {
	resp := Response{
		id:     1
		result: 'null'
	}
	assert resp.id == 1
	assert resp.jsonrpc == '2.0'
}

fn test_response_with_capabilities() {
	resp := Response{
		id:     0
		result: Capabilities{
			capabilities: Capability{
				definition_provider: true
			}
		}
	}
	assert resp.id == 0
	if resp.result is Capabilities {
		assert resp.result.capabilities.definition_provider == true
	}
}

fn test_notification_struct() {
	notif := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri:         'file:///test.v'
			diagnostics: []
		}
	}
	assert notif.method == 'textDocument/publishDiagnostics'
	assert notif.jsonrpc == '2.0'
}

fn test_notification_with_diagnostics() {
	notif := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri:         'file:///test.v'
			diagnostics: [
				LSPDiagnostic{
					range:    LSPRange{}
					message:  'error 1'
					severity: 1
				},
				LSPDiagnostic{
					range:    LSPRange{}
					message:  'error 2'
					severity: 1
				},
			]
		}
	}
	assert notif.params.diagnostics.len == 2
}

fn test_content_change_struct() {
	change := ContentChange{
		text: 'fn main() {\n\tprintln("hello")\n}'
	}
	assert change.text.contains('fn main()')
}

fn test_content_change_empty() {
	change := ContentChange{}
	assert change.text == ''
}

fn test_content_change_unicode() {
	change := ContentChange{
		text: "fn main() { println('Hello, 世界') }"
	}
	assert change.text.contains('世界')
}

// ============================================================================
// Tests for write_tracked_files_to_temp function
// ============================================================================

fn test_write_tracked_files_to_temp_single_file() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_interop_test_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	interop_test_must_mkdir_all(project_dir)

	test_file := os.join_path(project_dir, 'main.v')
	interop_test_must_write_file(test_file, 'module main')

	mut app := &App{
		temp_dir:   temp_dir
		open_files: map[string]string{}
	}

	uri := path_to_uri(test_file)
	app.open_files[uri] = 'module main\n\nfn main() { modified }'

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	assert os.exists(temp_project)
	temp_file := os.join_path(temp_project, 'main.v')
	assert os.exists(temp_file)

	content := os.read_file(temp_file) or { '' }
	assert content.contains('modified')
}

fn test_write_tracked_files_to_temp_multiple_files() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_interop_test2_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	interop_test_must_mkdir_all(project_dir)

	// Create original files
	files := ['main.v', 'utils.v', 'helpers.v']
	for file in files {
		path := os.join_path(project_dir, file)
		interop_test_must_write_file(path, 'module main\n\nfn ${file}() {}')
	}

	mut app := &App{
		temp_dir:   temp_dir
		open_files: map[string]string{}
	}

	// Track all files with modified content
	for file in files {
		path := os.join_path(project_dir, file)
		uri := path_to_uri(path)
		app.open_files[uri] = 'module main\n\nfn ${file}_modified() {}'
	}

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	// Verify all files were written
	for file in files {
		temp_file := os.join_path(temp_project, file)
		assert os.exists(temp_file)
		content := os.read_file(temp_file) or { '' }
		assert content.contains('_modified')
	}
}

fn test_write_tracked_files_to_temp_nested_directories() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_interop_test3_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	subdir := os.join_path(project_dir, 'src', 'internal')
	interop_test_must_mkdir_all(subdir)

	// Create nested file
	nested_file := os.join_path(subdir, 'util.v')
	interop_test_must_write_file(nested_file, 'module internal')

	mut app := &App{
		temp_dir:   temp_dir
		open_files: map[string]string{}
	}

	uri := path_to_uri(nested_file)
	app.open_files[uri] = 'module internal\n\nfn modified() {}'

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	// Verify nested structure was preserved
	temp_nested := os.join_path(temp_project, 'src', 'internal', 'util.v')
	assert os.exists(temp_nested)
}

fn test_write_tracked_files_skips_files_outside_working_dir() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_interop_test4_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	other_dir := os.join_path(temp_dir, 'other')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(other_dir)

	// Create files in both directories
	project_file := os.join_path(project_dir, 'main.v')
	other_file := os.join_path(other_dir, 'other.v')
	interop_test_must_write_file(project_file, 'module main')
	interop_test_must_write_file(other_file, 'module other')

	mut app := &App{
		temp_dir:   temp_dir
		open_files: map[string]string{}
	}

	// Track both files
	app.open_files[path_to_uri(project_file)] = 'module main modified'
	app.open_files[path_to_uri(other_file)] = 'module other modified'

	temp_project := app.write_tracked_files_to_temp(project_dir) or {
		assert false, 'Failed to write tracked files: ${err}'
		return
	}
	defer {
		os.rmdir_all(temp_project) or {}
	}

	// Only project file should be written
	assert os.exists(os.join_path(temp_project, 'main.v'))
	assert !os.exists(os.join_path(temp_project, 'other.v'))
}

// ============================================================================
// Tests for symlink_untracked_files function
// ============================================================================

fn test_symlink_untracked_files_basic() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_test_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(target_dir)

	// Create some V files
	tracked_file := os.join_path(project_dir, 'tracked.v')
	untracked_file := os.join_path(project_dir, 'untracked.v')
	interop_test_must_write_file(tracked_file, 'module main')
	interop_test_must_write_file(untracked_file, 'module main')

	// Only track one file
	mut tracked := map[string]string{}
	tracked[path_to_uri(tracked_file)] = 'content'

	symlink_untracked_files(project_dir, project_dir, target_dir, tracked) or {
		assert false, 'Failed to symlink: ${err}'
		return
	}

	// Only untracked file should be symlinked
	assert !os.exists(os.join_path(target_dir, 'tracked.v'))
	target_untracked := os.join_path(target_dir, 'untracked.v')
	assert os.exists(target_untracked) || os.is_link(target_untracked)
}

fn test_symlink_untracked_files_nested() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_test2_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	subdir := os.join_path(project_dir, 'src')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(subdir)
	interop_test_must_mkdir_all(target_dir)

	// Create nested untracked file
	nested_file := os.join_path(subdir, 'nested.v')
	interop_test_must_write_file(nested_file, 'module src')

	tracked := map[string]string{}

	symlink_untracked_files(project_dir, project_dir, target_dir, tracked) or {
		assert false, 'Failed to symlink: ${err}'
		return
	}

	// Nested structure should be created
	target_nested := os.join_path(target_dir, 'src', 'nested.v')
	assert os.exists(target_nested) || os.is_link(target_nested)
}

fn test_symlink_untracked_files_empty_tracked() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_symlink_test3_${os.getpid()}')
	interop_test_must_mkdir_all(temp_dir)

	project_dir := os.join_path(temp_dir, 'project')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(project_dir)
	interop_test_must_mkdir_all(target_dir)

	// Create files
	for i in 0 .. 3 {
		interop_test_must_write_file(os.join_path(project_dir, 'file${i}.v'), 'module main')
	}

	tracked := map[string]string{} // Empty - all files untracked

	symlink_untracked_files(project_dir, project_dir, target_dir, tracked) or {
		assert false, 'Failed to symlink: ${err}'
		return
	}

	// All files should be symlinked
	for i in 0 .. 3 {
		target_file := os.join_path(target_dir, 'file${i}.v')
		assert os.exists(target_file) || os.is_link(target_file)
	}
}

fn test_symlink_untracked_files_materializes_local_imports() {
	temp_dir := os.join_path(os.temp_dir(),
		'vls_symlink_local_import_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	module_dir := os.join_path(project_dir, 'mathutil')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(module_dir)
	interop_test_must_mkdir_all(target_dir)

	main_file := os.join_path(project_dir, 'main.v')
	main_content := 'module main\n\nimport mathutil\n'
	module_file := os.join_path(module_dir, 'mathutil.v')
	module_content := 'module mathutil\n\npub fn answer() int { return 42 }\n'
	interop_test_must_write_file(main_file, main_content)
	interop_test_must_write_file(module_file, module_content)

	mut tracked := map[string]string{}
	tracked[path_to_uri(main_file)] = main_content
	symlink_untracked_files(project_dir, project_dir, target_dir, tracked) or {
		assert false, 'Failed to populate overlay: ${err}'
		return
	}

	target_module_dir := os.join_path(target_dir, 'mathutil')
	target_module_file := os.join_path(target_module_dir, 'mathutil.v')
	assert os.is_dir(target_module_dir)
	assert !os.is_link(target_module_dir)
	assert os.is_file(target_module_file)
	assert !os.is_link(target_module_file)
	assert os.read_file(target_module_file) or { '' } == module_content
}

fn test_symlink_untracked_files_materializes_import_relative_to_source_module() {
	temp_dir := os.join_path(os.temp_dir(),
		'vls_symlink_nested_import_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	source_dir := os.join_path(project_dir, 'src')
	module_dir := os.join_path(source_dir, 'mathutil')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(module_dir)
	interop_test_must_mkdir_all(target_dir)

	main_file := os.join_path(source_dir, 'main.v')
	main_content := 'module main\n\nimport mathutil\n'
	module_file := os.join_path(module_dir, 'mathutil.v')
	module_content := 'module mathutil\n\npub fn answer() int { return 42 }\n'
	interop_test_must_write_file(main_file, main_content)
	interop_test_must_write_file(module_file, module_content)

	mut tracked := map[string]string{}
	tracked[path_to_uri(main_file)] = main_content
	symlink_untracked_files(project_dir, source_dir, target_dir, tracked) or {
		assert false, 'Failed to populate nested-source overlay: ${err}'
		return
	}

	target_module_dir := os.join_path(target_dir, 'src', 'mathutil')
	target_module_file := os.join_path(target_module_dir, 'mathutil.v')
	assert os.is_dir(target_module_dir)
	assert !os.is_link(target_module_dir)
	assert os.is_file(target_module_file)
	assert !os.is_link(target_module_file)
	assert os.read_file(target_module_file) or { '' } == module_content
}

fn deny_overlay_symlink(_ string, _ string) ! {
	return error('permission denied')
}

fn test_symlink_untracked_files_copies_when_symlinks_are_denied() {
	temp_dir := os.join_path(os.temp_dir(),
		'vls_symlink_denied_${os.getpid()}_${time.now().unix_nano()}')
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	project_dir := os.join_path(temp_dir, 'project')
	module_dir := os.join_path(project_dir, 'helper')
	target_dir := os.join_path(temp_dir, 'target')
	interop_test_must_mkdir_all(module_dir)
	interop_test_must_mkdir_all(target_dir)

	main_file := os.join_path(project_dir, 'main.v')
	vmod_file := os.join_path(project_dir, 'v.mod')
	module_file := os.join_path(module_dir, 'helper.v')
	git_dir := os.join_path(project_dir, '.git')
	node_modules_dir := os.join_path(project_dir, 'node_modules', 'dependency')
	build_dir := os.join_path(project_dir, 'build')
	main_content := 'module main\n'
	vmod_content := "Module {\n\tname: 'denied_symlink_test'\n}\n"
	module_content := 'module helper\n\npub fn answer() int { return 42 }\n'
	interop_test_must_mkdir_all(git_dir)
	interop_test_must_mkdir_all(node_modules_dir)
	interop_test_must_mkdir_all(build_dir)
	interop_test_must_write_file(main_file, main_content)
	interop_test_must_write_file(vmod_file, vmod_content)
	interop_test_must_write_file(module_file, module_content)
	interop_test_must_write_file(os.join_path(project_dir, 'README.md'), 'not compiler input\n')
	interop_test_must_write_file(os.join_path(git_dir, 'metadata.v'), 'module metadata\n')
	interop_test_must_write_file(os.join_path(node_modules_dir, 'dependency.v'),
		'module dependency\n')
	interop_test_must_write_file(os.join_path(build_dir, 'generated.v'), 'module generated\n')

	mut tracked := map[string]string{}
	tracked[path_to_uri(main_file)] = 'module main\n\n// unsaved\n'
	symlink_untracked_files_with_linker(project_dir, project_dir, target_dir, tracked,
		deny_overlay_symlink) or {
		assert false, 'Failed to copy denied symlinks: ${err}'
		return
	}

	assert !os.exists(os.join_path(target_dir, 'main.v'))
	target_vmod := os.join_path(target_dir, 'v.mod')
	target_module := os.join_path(target_dir, 'helper')
	target_module_file := os.join_path(target_module, 'helper.v')
	assert os.is_file(target_vmod)
	assert !os.is_link(target_vmod)
	assert os.read_file(target_vmod) or { '' } == vmod_content
	assert os.is_dir(target_module)
	assert !os.is_link(target_module)
	assert os.read_file(target_module_file) or { '' } == module_content
	assert !os.exists(os.join_path(target_dir, 'README.md'))
	assert !os.exists(os.join_path(target_dir, '.git'))
	assert !os.exists(os.join_path(target_dir, 'node_modules'))
	assert !os.exists(os.join_path(target_dir, 'build'))
}

// ============================================================================
// Tests for edge cases
// ============================================================================

fn test_uri_path_edge_cases() {
	// Test various URI formats
	test_cases := [
		'file:///simple.v',
		'file:///path/to/file.v',
		'file:///path/with spaces/file.v',
		'file:///very/deep/nested/path/to/file.v',
	]

	for uri in test_cases {
		path := uri_to_path(uri)
		reconstructed := path_to_uri(path)
		// Should be able to convert back (approximately)
		assert reconstructed.contains('file://')
		assert reconstructed.contains('.v')
	}
}

fn test_json_error_defaults() {
	err := JsonError{}
	assert err.path == ''
	assert err.message == ''
	assert err.line_nr == 0
	assert err.col == 0
	assert err.len == 0
}

fn test_json_error_negative_values() {
	// LSP positions must be non-negative. Invalid compiler values are clamped
	// to 0 rather than emitted as negative positions (P1-09).
	err := JsonError{
		line_nr: -1
		col:     -1
		len:     -1
	}
	diag := v_error_to_lsp_diagnostic(err)
	assert diag.severity == 1
	assert diag.range.start.line == 0
	assert diag.range.start.char == 0
	assert diag.range.end.line == 0
	assert diag.range.end.char == 0
}

fn test_text_document_identifier() {
	doc := TextDocumentIdentifier{
		uri: 'file:///test.v'
	}
	assert doc.uri == 'file:///test.v'
}

fn test_text_document_identifier_empty() {
	doc := TextDocumentIdentifier{}
	assert doc.uri == ''
}

fn test_params_struct_complete() {
	params := Params{
		content_changes: [ContentChange{
			text: 'test'
		}]
		position:        Position{
			line: 5
			char: 10
		}
		text_document:   TextDocumentIdentifier{
			uri: 'file:///test.v'
		}
	}
	assert params.content_changes.len == 1
	assert params.position.line == 5
	assert params.text_document.uri == 'file:///test.v'
}

fn test_completion_provider_multiple_triggers() {
	provider := CompletionProvider{
		trigger_characters: ['.', ':', '@', '(']
	}
	assert provider.trigger_characters.len == 4
	assert '.' in provider.trigger_characters
	assert ':' in provider.trigger_characters
}

fn test_signature_help_options_triggers() {
	opts := SignatureHelpOptions{
		trigger_characters: ['(', ',', '<']
	}
	assert opts.trigger_characters.len == 3
}

fn test_text_document_sync_options() {
	sync := TextDocumentSyncOptions{
		open_close: true
		change:     1 // Full sync
	}
	assert sync.open_close == true
	assert sync.change == 1
}

fn test_text_document_sync_incremental() {
	sync := TextDocumentSyncOptions{
		open_close: true
		change:     2 // Incremental sync
	}
	assert sync.change == 2
}

fn test_parameter_information() {
	param := ParameterInformation{
		label: 'x int'
	}
	assert param.label == 'x int'
}

fn test_signature_information_with_params() {
	sig := SignatureInformation{
		label:      'fn test(a int, b string, c bool)'
		parameters: [
			ParameterInformation{
				label: 'a int'
			},
			ParameterInformation{
				label: 'b string'
			},
			ParameterInformation{
				label: 'c bool'
			},
		]
	}
	assert sig.parameters.len == 3
	assert sig.label.contains('test')
}

fn test_publish_diagnostics_params() {
	params := PublishDiagnosticsParams{
		uri:         'file:///test.v'
		diagnostics: [
			LSPDiagnostic{
				range:    LSPRange{}
				message:  'error'
				severity: 1
			},
		]
	}
	assert params.uri == 'file:///test.v'
	assert params.diagnostics.len == 1
}
