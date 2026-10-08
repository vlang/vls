// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time

fn test_version_request_only_matches_standalone_arguments() {
	assert is_version_request(['vls', '--version'])
	assert is_version_request(['vls', 'version'])
	assert !is_version_request([]string{})
	assert !is_version_request(['vls'])
	assert !is_version_request(['version'])
	assert !is_version_request(['vls', '--port', 'version'])
	assert !is_version_request(['vls', '--host', '--version'])
	assert !is_version_request(['vls', '--version', '--port', '7777'])
}

fn main_test_temp_dir(tag string) string {
	dir := os.join_path(os.temp_dir(), 'vls_find_v_dir_${tag}_${os.getpid()}_${time.now().unix_nano()}')
	os.mkdir_all(dir) or {
		assert false, 'Failed to create ${dir}: ${err}'
		return dir
	}
	return os.real_path(dir)
}

fn main_test_write(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'Failed to write ${path}: ${err}'
	}
}

// The plain case: the executable sits directly beside vlib.
fn test_find_v_dir_from_exe_beside_vlib() {
	root := main_test_temp_dir('beside')
	defer {
		os.rmdir_all(root) or {}
	}
	main_test_write(os.join_path(root, 'v.exe'), 'binary')
	os.mkdir_all(os.join_path(root, 'vlib')) or {
		assert false, 'Failed to create vlib: ${err}'
		return
	}

	assert find_v_dir_from_exe(os.join_path(root, 'v.exe')) == root
}

// The regression case. V's Windows launcher is a `.bat` wrapper kept in `.bin/`
// that forwards to the real `v.exe` in the parent, so the executable's own
// directory has no vlib. Trusting it made every vlib lookup resolve to nothing.
fn test_find_v_dir_from_exe_wrapper_script_in_bin_dir() {
	root := main_test_temp_dir('wrapper')
	defer {
		os.rmdir_all(root) or {}
	}
	main_test_write(os.join_path(root, 'v.exe'), 'binary')
	os.mkdir_all(os.join_path(root, 'vlib')) or {
		assert false, 'Failed to create vlib: ${err}'
		return
	}
	bin_dir := os.join_path(root, '.bin')
	os.mkdir_all(bin_dir) or {
		assert false, 'Failed to create .bin: ${err}'
		return
	}
	wrapper := os.join_path(bin_dir, 'v.bat')
	// The wrapper's own contents do not matter, only that it is a file that is
	// not the real compiler.
	main_test_write(wrapper, '@echo off\r\ncall v.exe %*\r\n')

	assert find_v_dir_from_exe(wrapper) == root
}

// A wrapper nested one level deeper still resolves, because the walk is bounded
// by the number of levels between the launcher and the V root rather than by one.
fn test_find_v_dir_from_exe_deeply_nested_wrapper() {
	root := main_test_temp_dir('nested')
	defer {
		os.rmdir_all(root) or {}
	}
	main_test_write(os.join_path(root, 'v.exe'), 'binary')
	os.mkdir_all(os.join_path(root, 'vlib')) or {
		assert false, 'Failed to create vlib: ${err}'
		return
	}
	nested := os.join_path(root, '.bin', 'shims')
	os.mkdir_all(nested) or {
		assert false, 'Failed to create nested shim dir: ${err}'
		return
	}
	wrapper := os.join_path(nested, 'v.bat')
	main_test_write(wrapper, '@echo off\r\n')

	assert find_v_dir_from_exe(wrapper) == root
}

// A directory that holds no vlib anywhere on the way up reports nothing found,
// instead of returning a directory whose vlib path does not exist.
fn test_find_v_dir_from_exe_without_any_vlib() {
	root := main_test_temp_dir('novlib')
	defer {
		os.rmdir_all(root) or {}
	}
	exe := os.join_path(root, 'v.exe')
	main_test_write(exe, 'binary')

	assert find_v_dir_from_exe(exe) == ''
}

fn test_find_v_dir_from_exe_rejects_unresolved_name() {
	assert find_v_dir_from_exe('v') == ''
}

fn test_find_v_dir_from_exe_rejects_missing_file() {
	assert find_v_dir_from_exe(os.join_path(os.temp_dir(), 'vls_no_such_v_exe_9f3a')) == ''
}

fn test_main_is_loopback_host_accepts_local_only() {
	assert is_loopback_host('127.0.0.1'), 'IPv4 loopback must be loopback'
	assert is_loopback_host('::1'), 'IPv6 loopback must be loopback'
	assert is_loopback_host('localhost'), 'localhost must be loopback'
	assert is_loopback_host(''), 'empty host must be loopback'
	assert !is_loopback_host('0.0.0.0'), 'all-interfaces bind must not be loopback'
	assert !is_loopback_host('192.168.1.1'), 'LAN address must not be loopback'
	assert !is_loopback_host('example.com'), 'public hostname must not be loopback'
}

fn test_main_method_may_ask_compiler_splits_compiler_backed_methods() {
	assert method_may_ask_compiler(.definition), 'definition may wait for the compiler'
	assert method_may_ask_compiler(.hover), 'hover may wait for the compiler'
	assert method_may_ask_compiler(.rename), 'rename may wait for the compiler'
	assert method_may_ask_compiler(.formatting), 'formatting may wait for v fmt'
	assert method_may_ask_compiler(.inlay_hint), 'inlay_hint may wait for the compiler'
	assert !method_may_ask_compiler(.initialize), 'initialize never waits for the compiler'
	assert !method_may_ask_compiler(.semantic_tokens), 'semantic_tokens never waits for the compiler'
	assert !method_may_ask_compiler(.shutdown), 'shutdown never waits for the compiler'
	assert !method_may_ask_compiler(.did_open), 'did_open never waits for the compiler'
}

fn test_main_method_never_asks_compiler_lists_index_only_methods() {
	assert method_never_asks_compiler(.semantic_tokens), 'semantic_tokens is index-only'
	assert method_never_asks_compiler(.semantic_tokens_range), 'semantic_tokens_range is index-only'
	assert method_never_asks_compiler(.document_symbols), 'document_symbols is index-only'
	assert method_never_asks_compiler(.folding_range), 'folding_range is index-only'
	assert method_never_asks_compiler(.selection_range), 'selection_range is index-only'
	assert method_never_asks_compiler(.code_action), 'code_action is index-only'
	assert !method_never_asks_compiler(.hover), 'hover may ask the compiler'
	assert !method_never_asks_compiler(.definition), 'definition may ask the compiler'
	assert !method_never_asks_compiler(.rename), 'rename may ask the compiler'
}

fn test_main_split_mime_parameters_keeps_quoted_semicolons() {
	assert split_mime_parameters('application/json') == ['application/json'], 'type without params stays whole'
	assert split_mime_parameters('text/plain; charset=utf-8') == ['text/plain', 'charset=utf-8'], 'plain parameter splits'
	quoted := split_mime_parameters('text/plain; title="a;b"; charset=utf-8')
	assert quoted == ['text/plain', 'title="a;b"', 'charset=utf-8'], 'semicolon inside quotes must not split'
}

fn test_main_unquote_mime_parameter_decodes_quoted_pairs() {
	assert unquote_mime_parameter('"utf-8"') == 'utf-8', 'quoted charset unquotes'
	assert unquote_mime_parameter('utf-8') == 'utf-8', 'bare value passes through'
	assert unquote_mime_parameter('""') == '', 'empty quotes decode to empty'
	assert unquote_mime_parameter('"a\\"b"') == 'a"b', 'quoted-pair escape decodes'
	assert unquote_mime_parameter('"abc\\"') == '"abc\\"', 'dangling escape stays invalid'
}

fn test_main_charset_is_unsupported_rejects_non_utf8() {
	assert !charset_is_unsupported('application/json'), 'no charset means UTF-8'
	assert !charset_is_unsupported('text/plain; charset=utf-8'), 'utf-8 is supported'
	assert !charset_is_unsupported('text/plain; charset=UTF8'), 'historic utf8 spelling is supported'
	assert !charset_is_unsupported('text/plain; charset="utf-8"'), 'quoted utf-8 is supported'
	assert charset_is_unsupported('text/plain; charset=latin-1'), 'latin-1 is unsupported'
	assert charset_is_unsupported('text/plain; CHARSET=UTF-16'), 'charset name match is case-insensitive'
	assert charset_is_unsupported('text/plain; boundary=x; charset=iso-8859-1'), 'unrelated params are skipped'
}

fn test_main_raw_id_to_int_collapses_non_numeric_ids() {
	assert raw_id_to_int('') == 0, 'absent id collapses to 0'
	assert raw_id_to_int('"abc"') == 0, 'string id collapses to 0'
	assert raw_id_to_int('null') == 0, 'null id collapses to 0'
	assert raw_id_to_int('5') == 5, 'numeric id converts'
	assert raw_id_to_int('-3') == -3, 'negative id converts'
}

fn test_main_json_is_ws_matches_insignificant_bytes_only() {
	assert json_is_ws(u8(32)), 'space is whitespace'
	assert json_is_ws(u8(9)), 'tab is whitespace'
	assert json_is_ws(u8(10)), 'newline is whitespace'
	assert json_is_ws(u8(13)), 'carriage return is whitespace'
	assert !json_is_ws(u8(65)), 'letter is not whitespace'
	assert !json_is_ws(u8(123)), 'brace is not whitespace'
	assert !json_is_ws(u8(48)), 'digit is not whitespace'
}

fn test_main_hex4_to_int_parses_four_hex_digits() {
	assert hex4_to_int('0041') or { -1 } == 65, 'hex 0041 is 65'
	assert hex4_to_int('ffff') or { -1 } == 65535, 'lowercase ffff parses'
	assert hex4_to_int('ABCD') or { -1 } == 43981, 'uppercase ABCD parses'
	assert hex4_to_int('00G1') == none, 'non-hex digit is none'
	assert hex4_to_int('123') == none, 'short input is none'
	assert hex4_to_int('12345') == none, 'long input is none'
	assert hex4_to_int('') == none, 'empty input is none'
}

fn test_main_decode_json_unicode_escape_reads_bmp_and_astral() {
	if cp, adv := decode_json_unicode_escape('\\u0041', 0) {
		assert cp == 65, 'U+0041 decodes to 65'
		assert adv == 6, 'BMP escape consumes 6 bytes'
	} else {
		assert false, 'valid BMP escape must decode'
	}
	if cp, adv := decode_json_unicode_escape('\\uD83D\\uDE00', 0) {
		assert cp == 128512, 'surrogate pair decodes to U+1F600'
		assert adv == 12, 'pair consumes 12 bytes'
	} else {
		assert false, 'valid surrogate pair must decode'
	}
	assert decode_json_unicode_escape('\\uZZZZ', 0) == none, 'non-hex escape is none'
	assert decode_json_unicode_escape('\\u00', 0) == none, 'truncated escape is none'
	assert decode_json_unicode_escape('\\uD83D', 0) == none, 'unpaired high surrogate is none'
}

fn test_main_skip_json_value_stops_after_one_value() {
	assert skip_json_value('{"a":1},rest', 0) == 7, 'object value ends after closing brace'
	assert skip_json_value('[1,[2]],x', 0) == 7, 'nested arrays end after matching bracket'
	assert skip_json_value('"ab\\"cd" ,', 0) == 8, 'escaped quote does not end the string'
	assert skip_json_value('123, 456', 0) == 3, 'number ends before comma'
	assert skip_json_value('true}', 0) == 4, 'keyword ends before brace'
	assert skip_json_value('', 0) == 0, 'empty input stays at start'
}

fn test_main_content_has_member_reads_top_level_keys_only() {
	assert content_has_member('{"id":1,"method":"initialize"}', 'id'), 'top-level id is found'
	assert content_has_member('{"id":1,"method":"initialize"}', 'method'), 'top-level method is found'
	assert !content_has_member('{"id":1,"method":"initialize"}', 'result'), 'absent key is not found'
	assert !content_has_member('{"params":{"id":99}}', 'id'), 'nested id must not count as top-level'
	assert !content_has_member('{}', 'id'), 'empty object has no members'
	assert !content_has_member('not json', 'id'), 'non-object has no members'
}

fn test_main_matches_needle_at_checks_byte_prefix() {
	assert matches_needle_at('hello', 1, 'ell'), 'matching offset reports true'
	assert !matches_needle_at('hello', 2, 'ell'), 'mismatching offset reports false'
	assert !matches_needle_at('hi', 5, 'x'), 'overflow start reports false'
	assert !matches_needle_at('hi', 0, 'hello'), 'needle longer than rest reports false'
	assert matches_needle_at('abc', 3, ''), 'empty needle always matches'
}

fn test_main_derive_diagnostic_code_and_tags_maps_known_messages() {
	code1, tags1 := derive_diagnostic_code_and_tags('unused variable `x`')
	assert code1 or { '' } == 'unused_variable', 'unused variable maps to unused_variable'
	assert (tags1 or { []int{} }) == [1], 'unused_variable carries tag 1'
	code2, tags2 := derive_diagnostic_code_and_tags('UNUSED IMPORT os')
	assert code2 or { '' } == 'unused_import', 'match is case-insensitive'
	assert (tags2 or { []int{} }) == [1], 'unused_import carries tag 1'
	code3, tags3 := derive_diagnostic_code_and_tags('fn is deprecated')
	assert code3 or { '' } == 'deprecated', 'deprecated maps to deprecated'
	assert (tags3 or { []int{} }) == [2], 'deprecated carries tag 2'
	code4, tags4 := derive_diagnostic_code_and_tags('undefined: foo')
	assert code4 or { '' } == 'undefined', 'undefined maps to undefined'
	assert tags4 == none, 'undefined carries no tags'
	code5, _ := derive_diagnostic_code_and_tags('cannot convert int to string')
	assert code5 or { '' } == 'type_mismatch', 'conversion failure maps to type_mismatch'
	code6, _ := derive_diagnostic_code_and_tags('unknown module `foo`')
	assert code6 or { '' } == 'unknown_module', 'unknown module maps to unknown_module'
	code7, tags7 := derive_diagnostic_code_and_tags('some other error')
	assert code7 == none, 'unknown message has no code'
	assert tags7 == none, 'unknown message has no tags'
}

fn test_main_method_requires_response_separates_requests_from_notifications() {
	assert method_requires_response(.initialize), 'initialize expects a response'
	assert method_requires_response(.completion), 'completion expects a response'
	assert method_requires_response(.shutdown), 'shutdown expects a response'
	assert method_requires_response(.code_action), 'code_action expects a response'
	assert method_requires_response(.workspace_symbol), 'workspace_symbol expects a response'
	assert !method_requires_response(.initialized), 'initialized is notification-only'
	assert !method_requires_response(.did_open), 'did_open is notification-only'
	assert !method_requires_response(.did_change), 'did_change is notification-only'
	assert !method_requires_response(.exit), 'exit is notification-only'
	assert !method_requires_response(.set_trace), 'set_trace is notification-only'
}

fn test_main_is_valid_v_identifier_name_checks_shape_only() {
	assert is_valid_v_identifier_name('foo'), 'plain name is valid'
	assert is_valid_v_identifier_name('_bar'), 'leading underscore is valid'
	assert is_valid_v_identifier_name('foo123'), 'trailing digits are valid'
	assert is_valid_v_identifier_name(' foo '), 'surrounding spaces are trimmed'
	assert !is_valid_v_identifier_name(''), 'empty name is invalid'
	assert !is_valid_v_identifier_name('   '), 'blank name is invalid'
	assert !is_valid_v_identifier_name('2foo'), 'leading digit is invalid'
	assert !is_valid_v_identifier_name('foo bar'), 'inner space is invalid'
	assert !is_valid_v_identifier_name('foo!'), 'punctuation is invalid'
}

fn test_main_make_request_failed_error_response_carries_code_and_message() {
	resp := make_request_failed_error_response(7, 'rename would break the program')
	assert resp.id == 7, 'failed response keeps the request id'
	assert resp.error.code == jsonrpc_err_request_failed, 'failed response uses request-failed code'
	assert resp.error.message == 'rename would break the program', 'failed response keeps the message'
}

fn test_main_make_invalid_request_error_response_defaults_empty_message() {
	custom := make_invalid_request_error_response(3, 'bad shape')
	assert custom.id == 3, 'invalid response keeps the request id'
	assert custom.error.code == jsonrpc_err_invalid_request, 'invalid response uses invalid-request code'
	assert custom.error.message == 'bad shape', 'invalid response keeps a custom message'
	fallback := make_invalid_request_error_response(4, '')
	assert fallback.error.message == 'Invalid request', 'empty message falls back to default'
}
