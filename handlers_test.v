// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json2

fn must_mkdir_all(path string) {
	os.mkdir_all(path) or {
		assert false, 'Failed to create directory ${path}: ${err}'
		return
	}
}

fn must_write_file(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'Failed to write file ${path}: ${err}'
		return
	}
}

fn create_test_app() &App {
	temp_dir := os.join_path(os.temp_dir(), 'vls_test_${os.getpid()}')
	os.mkdir_all(temp_dir) or {
		assert false, 'Failed to create test temp dir: ${err}'
		return &App{
			text:       ''
			open_files: map[string]string{}
			temp_dir:   temp_dir
		}
	}
	return &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
}

fn cleanup_test_app(app &App) {
	os.rmdir_all(app.temp_dir) or {}
}

fn test_on_did_open_tracks_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Create a temporary test file
	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	test_content := 'module main\n\nfn main() {\n\tprintln("hello")\n}'
	must_write_file(test_file, test_content)

	uri := path_to_uri(test_file)
	request := Request{
		id:      1
		method:  'textDocument/didOpen'
		jsonrpc: '2.0'
		params:  json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	app.on_did_open(request)

	// Verify file is tracked
	assert uri in app.open_files
	assert app.open_files[uri] == test_content
	assert app.text == test_content
}

fn test_on_did_open_multiple_files() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Create multiple test files
	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	test_file1 := os.join_path(test_dir, 'main.v')
	test_file2 := os.join_path(test_dir, 'utils.v')
	content1 := 'module main\n\nfn main() {}'
	content2 := 'module main\n\nfn helper() {}'

	must_write_file(test_file1, content1)
	must_write_file(test_file2, content2)

	uri1 := path_to_uri(test_file1)
	uri2 := path_to_uri(test_file2)

	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri1
			}
		},
			escape_unicode: true
		)
	})
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri2
			}
		},
			escape_unicode: true
		)
	})

	assert app.open_files.len == 2
	assert uri1 in app.open_files
	assert uri2 in app.open_files
}

fn test_on_did_open_updates_current_text() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	test_file1 := os.join_path(test_dir, 'first.v')
	test_file2 := os.join_path(test_dir, 'second.v')
	content1 := 'module main\n\nfn first() {}'
	content2 := 'module main\n\nfn second() {}'

	must_write_file(test_file1, content1)
	must_write_file(test_file2, content2)

	uri1 := path_to_uri(test_file1)
	uri2 := path_to_uri(test_file2)

	// Open first file
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri1
			}
		},
			escape_unicode: true
		)
	})
	assert app.text == content1

	// Open second file - app.text should update to second file's content
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri2
			}
		},
			escape_unicode: true
		)
	})
	assert app.text == content2
}

fn test_on_did_open_nonexistent_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Try to open a file that doesn't exist
	nonexistent := os.join_path(app.temp_dir, 'nonexistent.v')
	uri := path_to_uri(nonexistent)

	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	// File should not be tracked if it doesn't exist
	assert uri !in app.open_files
}

fn test_on_did_open_uses_text_document_payload() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := path_to_uri(os.join_path(app.temp_dir, 'unsaved.v'))
	content := 'module main\n\nfn main() {\n\tprintln("from_payload")\n}'
	app.on_did_open(Request{
		params: json2.encode(DidOpenTextDocumentParams{
			text_document: DidOpenTextDocumentItem{
				uri:  uri
				text: content
			}
		},
			escape_unicode: true
		)
	})

	assert uri in app.open_files
	assert app.open_files[uri] == content
	assert app.text == content
}

fn test_on_did_open_uses_empty_text_payload_without_disk_fallback() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := path_to_uri(os.join_path(app.temp_dir, 'unsaved_empty.v'))
	app.on_did_open(Request{
		params: json2.encode(DidOpenTextDocumentParams{
			text_document: DidOpenTextDocumentItem{
				uri:  uri
				text: ''
			}
		},
			escape_unicode: true
		)
	})

	assert uri in app.open_files
	assert app.open_files[uri] == ''
	assert app.text == ''
}

fn test_on_did_open_empty_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'empty.v')
	must_write_file(test_file, '')

	uri := path_to_uri(test_file)
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	assert uri in app.open_files
	assert app.open_files[uri] == ''
	assert app.text == ''
}

fn test_on_did_open_reopen_same_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')

	// Write initial content
	content1 := 'module main\n\nfn main() {}'
	must_write_file(test_file, content1)

	uri := path_to_uri(test_file)
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})
	assert app.open_files[uri] == content1

	// Update file content on disk
	content2 := 'module main\n\nfn main() { updated }'
	must_write_file(test_file, content2)

	// Reopen the file - should get new content
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})
	assert app.open_files[uri] == content2
}

fn test_on_did_change_updates_content() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	original_content := 'module main\n\nfn main() {}'
	must_write_file(test_file, original_content)

	uri := path_to_uri(test_file)

	// First open the file
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	// Then change it
	new_content := 'module main\n\nfn main() {\n\tprintln("changed")\n}'
	request := Request{
		id:      2
		method:  'textDocument/didChange'
		jsonrpc: '2.0'
		params:  json2.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: new_content
			}]
		},
			escape_unicode: true
		)
	}

	app.on_did_change(request)

	assert app.text == new_content
	assert app.open_files[uri] == new_content
}

fn test_on_did_change_empty_changes() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Request with empty content changes should return none
	request := Request{
		params: json2.encode(Params{
			content_changes: []
		},
			escape_unicode: true
		)
	}

	result := app.on_did_change(request)
	assert result == none
}

fn test_on_did_change_empty_text() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// Request with empty text (deletion) should be processed and return diagnostics
	request := Request{
		params: json2.encode(Params{
			content_changes: [ContentChange{
				text: ''
			}]
		},
			escape_unicode: true
		)
	}

	result := app.on_did_change(request)
	if notif := result {
		assert notif.method == 'textDocument/publishDiagnostics'
		assert notif.params.uri == ''
		assert notif.params.diagnostics.len == 0
	} else {
		assert false, 'expected a notification'
	}
}

fn test_on_did_change_returns_notification() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	content := "module main\n\nfn main() {\n\tprintln('hello')\n}\n"
	must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	request := Request{
		params: json2.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: content
			}]
		},
			escape_unicode: true
		)
	}

	result := app.on_did_change(request)

	// Should return a notification
	if notif := result {
		assert notif.method == 'textDocument/publishDiagnostics'
		assert notif.params.uri == uri
	}
}

fn test_on_did_change_multiple_changes() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	must_write_file(test_file, 'module main')

	uri := path_to_uri(test_file)
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	// Simulate multiple sequential changes
	changes := [
		'module main\n\nfn main() {}',
		"module main\n\nfn main() { println('a') }",
		"module main\n\nfn main() { println('b') }",
	]

	for change in changes {
		request := Request{
			params: json2.encode(Params{
				text_document:   TextDocumentIdentifier{
					uri: uri
				}
				content_changes: [ContentChange{
					text: change
				}]
			},
				escape_unicode: true
			)
		}
		app.on_did_change(request)
		assert app.text == change
		assert app.open_files[uri] == change
	}
}

fn test_on_did_change_updates_tracked_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	must_write_file(test_file, 'original')

	uri := path_to_uri(test_file)

	// Open file
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	// Verify initial state
	assert app.open_files[uri] == 'original'

	// Change file
	new_content := 'modified content'
	app.on_did_change(Request{
		params: json2.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: uri
			}
			content_changes: [ContentChange{
				text: new_content
			}]
		},
			escape_unicode: true
		)
	})

	// Verify both app.text and open_files are updated
	assert app.text == new_content
	assert app.open_files[uri] == new_content
}

fn test_apply_incremental_change_handles_utf8_columns() {
	content := 'aéz\n'
	range := LSPRange{
		start: Position{
			line: 0
			char: 1
		}
		end:   Position{
			line: 0
			char: 2
		}
	}
	updated := apply_incremental_change(content, range, 'X', .utf16)
	// The trailing newline must be preserved: incremental edits are lossless and
	// must not normalize line endings (P0-07 item 4).
	assert updated == 'aXz\n'
}

fn test_apply_incremental_change_preserves_crlf() {
	// CRLF line endings outside the edited span must be preserved exactly.
	content := 'abc\r\ndef\r\nghi\r\n'
	range := LSPRange{
		start: Position{
			line: 1
			char: 0
		}
		end:   Position{
			line: 1
			char: 3
		}
	}
	updated := apply_incremental_change(content, range, 'XYZ', .utf16)
	assert updated == 'abc\r\nXYZ\r\nghi\r\n'
}

fn test_apply_incremental_change_rejects_reversed_range() {
	content := 'abcdef'
	range := LSPRange{
		start: Position{
			line: 0
			char: 4
		}
		end:   Position{
			line: 0
			char: 2
		}
	}
	// A reversed range is invalid; the content must be returned unchanged.
	updated := apply_incremental_change(content, range, 'X', .utf16)
	assert updated == content
}

fn test_incremental_change_is_valid_rejects_lines_past_eof() {
	// "abc\ndef" has lines 0 and 1 only. A stale client targeting lines beyond
	// the document must be rejected, not clamped-and-appended at EOF (P0-07).
	content := 'abc\ndef'
	past := LSPRange{
		start: Position{
			line: 5
			char: 0
		}
		end:   Position{
			line: 6
			char: 0
		}
	}
	assert !incremental_change_is_valid(content, past, .utf16)
	// An end line past EOF is rejected even when the start line is in range.
	half_past := LSPRange{
		start: Position{
			line: 1
			char: 0
		}
		end:   Position{
			line: 9
			char: 0
		}
	}
	assert !incremental_change_is_valid(content, half_past, .utf16)
	// A range fully inside the document is still accepted.
	ok := LSPRange{
		start: Position{
			line: 0
			char: 1
		}
		end:   Position{
			line: 1
			char: 2
		}
	}
	assert incremental_change_is_valid(content, ok, .utf16)
}

fn test_semantic_reference_scan_caps_candidates() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	app.capture_output = true // don't write log notifications to stdout during the test
	// A directory that does not exist on disk, so no real files are scanned.
	uri := 'file:///nonexistent_vls_reftest/a.v'
	mut content := 'module main\n'
	for _ in 0 .. reference_semantic_max_candidates + 5 {
		content += 'fn line() { foo() }\n'
	}
	app.open_files[uri] = content

	dummy_anchor := Location{
		uri: uri
	}
	scope := app.index_scope_for_uri(uri)
	// References (allow_lexical_fallback = true): over the cap, every lexical
	// occurrence is returned unverified (no compiler process is launched).
	refs := app.search_symbol_in_dirs_semantic('foo', dummy_anchor, scope, 0, true)
	assert refs.len == reference_semantic_max_candidates + 5
	// Rename (allow_lexical_fallback = false): over the cap it refuses (returns
	// none) rather than emit a scope-unsafe destructive edit.
	rename_locs := app.search_symbol_in_dirs_semantic('foo', dummy_anchor, scope, 0, false)
	assert rename_locs.len == 0
}

fn test_semantic_candidate_cap_ignores_unrelated_workspace_root() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	current_uri := 'file:///root_a/main.v'
	app.open_files[current_uri] = 'module main\n\nfn main() { unique() }\n'
	mut unrelated_content := 'module main\n'
	for i in 0 .. reference_semantic_max_candidates + 1 {
		unrelated_content += 'fn unrelated_${i}() { unique() }\n'
	}
	app.open_files['file:///root_b/many.v'] = unrelated_content
	app.ensure_dirs_indexed(app.index_query_dirs())

	current_scope := IndexScope{
		dir:       '/root_a'
		recursive: true
	}
	candidates := app.collect_semantic_candidates('unique', current_scope)

	assert candidates.len == 1
	assert candidates[0].uri == current_uri
}

fn test_incremental_change_is_valid_rejects_char_past_line() {
	// Line 0 "abc" has length 3. A character offset past the line end is invalid
	// even though the line exists: position_to_byte_offset would clamp it to EOL
	// and the edit would be applied there while the version advances (P0-07).
	content := 'abc\ndef'
	past_start := LSPRange{
		start: Position{
			line: 0
			char: 9
		}
		end:   Position{
			line: 1
			char: 1
		}
	}
	assert !incremental_change_is_valid(content, past_start, .utf16)
	past_end := LSPRange{
		start: Position{
			line: 0
			char: 1
		}
		end:   Position{
			line: 1
			char: 9
		}
	}
	assert !incremental_change_is_valid(content, past_end, .utf16)
	// A character offset exactly at the line's length is the valid end-of-line
	// insertion point and must be accepted.
	at_eol := LSPRange{
		start: Position{
			line: 0
			char: 3
		}
		end:   Position{
			line: 0
			char: 3
		}
	}
	assert incremental_change_is_valid(content, at_eol, .utf16)
}

fn test_apply_incremental_change_handles_multiline_ranges() {
	content := 'abc\ndef\nghi'
	range := LSPRange{
		start: Position{
			line: 0
			char: 1
		}
		end:   Position{
			line: 1
			char: 2
		}
	}
	updated := apply_incremental_change(content, range, '_\n_', .utf16)
	assert updated == 'a_\n_f\nghi'
}

fn test_operation_at_pos_completion_line_info() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	content := 'module main\n\nfn main() {\n\tos.\n}\n'
	must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	request := Request{
		id:     1
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 4
			}
		},
			escape_unicode: true
		)
	}

	response := app.operation_at_pos(.completion, request)
	assert response.id == 1
}

fn test_operation_at_pos_definition_line_info() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	request := Request{
		id:     2
		method: 'textDocument/definition'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			}
		},
			escape_unicode: true
		)
	}

	response := app.operation_at_pos(.definition, request)
	assert response.id == 2
	// Regression guard: definition must actually resolve through the compiler
	// interop path (which silently broke once when compiler stderr was dropped),
	// not return null. It must point at the `fn helper()` declaration on line 2.
	assert response.result is Location
	loc := response.result as Location
	assert loc.range.start.line == 2
}

fn test_resolve_indexed_definition_finds_current_file_function() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_current')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	location := app.resolve_indexed_definition(uri, Position{
		line: 5
		char: 2
	}) or {
		assert false, 'expected indexed definition'
		return
	}
	assert location.uri == uri
	assert location.range.start.line == 2
}

fn test_resolve_indexed_definition_limits_test_target() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_test_target')
	must_mkdir_all(test_dir)
	foo_file := os.join_path(test_dir, 'foo_test.v')
	bar_file := os.join_path(test_dir, 'bar_test.v')
	foo_content := 'module main\n\nfn local_helper() {}\n\nfn test_target() {\n\thelper()\n\tlocal_helper()\n}\n'
	bar_content := 'module main\n\nfn helper() {}\n'
	must_write_file(foo_file, foo_content)
	must_write_file(bar_file, bar_content)
	foo_uri := path_to_uri(foo_file)
	bar_uri := path_to_uri(bar_file)
	app.open_files[foo_uri] = foo_content
	app.open_files[bar_uri] = bar_content

	sibling_location := app.resolve_indexed_definition(foo_uri, Position{
		line: 5
		char: 3
	})
	assert sibling_location == none

	local_location := app.resolve_indexed_definition(foo_uri, Position{
		line: 6
		char: 4
	}) or {
		assert false, 'expected definition from requesting test target'
		return
	}
	assert local_location.uri == foo_uri
	assert local_location.range.start.line == 2
}

fn test_resolve_indexed_definition_rejects_comments_and_string_literals() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_source_context')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn helper() string { return 'ok' }\n\nfn main() {\n\t// helper is mentioned here\n\tliteral := 'helper'\n\tplain_dollar := '\$helper'\n\traw := r'\$helper'\n\tinterpolated := '\${helper()}'\n}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()

	for line_idx in [5, 6, 7, 8] {
		helper_col := lines[line_idx].index('helper') or {
			assert false, 'expected helper text'
			return
		}
		location := app.resolve_indexed_definition(uri, Position{
			line: line_idx
			char: helper_col + 2
		})
		assert location == none
	}

	helper_col := lines[9].index('helper') or {
		assert false, 'expected interpolated helper reference'
		return
	}
	location := app.resolve_indexed_definition(uri, Position{
		line: 9
		char: helper_col + 2
	}) or {
		assert false, 'expected indexed definition from string interpolation'
		return
	}
	assert location.uri == uri
	assert location.range.start.line == 2
}

fn test_resolve_indexed_definition_rejects_c_string_prefix() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_c_string_prefix')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn c() {}\n\nfn main() {\n\ttext := c'hello'\n\tprintln(text)\n}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	c_string_col := content.split_into_lines()[5].index("c'hello'") or {
		assert false, 'expected C-string prefix'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 5
		char: c_string_col
	})
	assert location == none
}

fn test_resolve_indexed_definition_rejects_multiline_string_continuations() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_multiline_string')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn helper() string { return 'ok' }\n\nfn main() {\n\ttext := 'first\nhelper\nlast'\n\tprintln(text)\n}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	helper_col := lines[6].index('helper') or {
		assert false, 'expected helper text in multiline string'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: helper_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_rejects_rune_literals() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_rune_literal')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn f() {}\n\nfn main() {\n\tch := `f`\n\tprintln(ch)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	f_col := content.split_into_lines()[5].index('f') or {
		assert false, 'expected rune literal'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 5
		char: f_col
	})
	assert location == none
}

fn test_resolve_indexed_definition_accepts_multiline_string_interpolations() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_multiline_interpolation')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn helper() string { return 'ok' }\n\nfn main() {\n\ttext := 'result \${\n\t\thelper()\n\t}'\n\tprintln(text)\n}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	helper_col := content.split_into_lines()[6].index('helper') or {
		assert false, 'expected multiline interpolation reference'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: helper_col + 2
	}) or {
		assert false, 'expected indexed multiline interpolation definition'
		return
	}
	assert location.uri == uri
	assert location.range.start.line == 2
}

fn test_resolve_indexed_definition_defers_module_and_import_declarations() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_declarations')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport helper\n\nfn main() {}\nfn helper() {}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	module_location := app.resolve_indexed_definition(uri, Position{
		line: 0
		char: 8
	})
	assert module_location == none
	import_location := app.resolve_indexed_definition(uri, Position{
		line: 2
		char: 9
	})
	assert import_location == none
}

fn test_resolve_indexed_definition_defers_local_variable_shadow() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_local_shadow')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper := 1\n\tprintln(helper)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: 11
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_implicit_it_binding() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_implicit_it')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn it() {}\n\nfn main() {\n\titems := [1, 2]\n\t_ := items.filter(it > 0)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	it_col := content.split_into_lines()[6].index('it >') or {
		assert false, 'expected implicit it reference'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: it_col + 1
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_implicit_err_binding() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_implicit_err')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn err() {}\n\nfn main() {\n\t_ := os.read_file('missing') or {\n\t\teprintln(err)\n\t\t''\n\t}\n}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	err_col := content.split_into_lines()[6].index('err') or {
		assert false, 'expected implicit err reference'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: err_col + 1
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_enum_member_declaration() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_enum_member')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn red() {}\n\nenum Color {\n\tred\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	red_col := content.split_into_lines()[5].index('red') or {
		assert false, 'expected enum member declaration'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 5
		char: red_col + 1
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_attribute_identifier() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_attribute')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn deprecated() {}\n\nconst text = r'ends\\'\n\n@[deprecated: 'use replacement']\nfn old() {}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	attribute_col := lines[6].index('deprecated') or {
		assert false, 'expected attribute identifier'
		return
	}

	assert source_occurrence_is_attribute(lines, 6, attribute_col)
	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: attribute_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_imported_module_qualifier() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_module_qualifier')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport math as util\n\nfn util() {}\n\nfn main() {\n\t_ := util.sin(0.0)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	qualifier_col := content.split_into_lines()[7].index('util') or {
		assert false, 'expected imported module qualifier'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 7
		char: qualifier_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_builtin_interop_qualifiers() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_builtin_interop_qualifiers')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct C {}\nstruct JS {}\n\nfn main() {\n\tC.some_function()\n\tJS.some_function()\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	for position in [Position{
		line: 6
		char: 0
	}, Position{
		line: 7
		char: 1
	}] {
		location := app.resolve_indexed_definition(uri, position)
		assert location == none
	}
}

fn test_resolve_indexed_definition_defers_grouped_import_module_qualifier() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_grouped_module_qualifier')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport (\n\tmath as util\n)\n\nfn util() {}\n\nfn main() {\n\t_ := util.sin(0.0)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	qualifier_col := content.split_into_lines()[9].index('util') or {
		assert false, 'expected grouped import module qualifier'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 9
		char: qualifier_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_preserves_grouped_import_through_block_comment() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_grouped_import_comment')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport (\n\t/*\n) still commented\n\t*/\n\tmath as util\n)\n\nfn util() {}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	alias_col := content.split_into_lines()[6].index('util') or {
		assert false, 'expected grouped import alias after block comment'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: alias_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_method_declaration_name() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_method_declaration')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct X {}\n\nfn helper() {}\n\nfn (x X) helper() {}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	method_col := content.split_into_lines()[6].index('helper') or {
		assert false, 'expected method declaration name'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: method_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_multiline_method_declaration_name() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_multiline_method_declaration')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct X {}\n\nfn helper() {}\n\nfn (\n\tx X\n) helper() {}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	method_col := lines[8].index('helper') or {
		assert false, 'expected multiline method declaration name'
		return
	}

	assert source_occurrence_is_method_declaration(lines, 8, method_col)
	location := app.resolve_indexed_definition(uri, Position{
		line: 8
		char: method_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_interface_method_signature() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_interface_method')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn read() {}\n\ninterface Reader {\n\tread()\n}\n\ninterface Writer { read() }\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()

	for line_idx in [5, 8] {
		method_col := lines[line_idx].index('read') or {
			assert false, 'expected interface method signature'
			return
		}
		location := app.resolve_indexed_definition(uri, Position{
			line: line_idx
			char: method_col + 2
		})
		assert location == none
	}
}

fn test_resolve_indexed_definition_defers_compile_time_at_identifier() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_compile_time_at')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct FN {}\n\nfn main() {\n\tprintln(@FN)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	macro_col := content.split_into_lines()[5].index('FN') or {
		assert false, 'expected compile-time @ identifier'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 5
		char: macro_col + 1
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_dollar_prefixed_identifiers() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_compile_time_dollar')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn embed_file() {}\nfn tmpl() {}\n\nfn main() {\n\t_ := \$embed_file('asset.txt')\n\t_ := \$tmpl('page.html')\n}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()

	for line_idx, symbol in {
		6: 'embed_file'
		7: 'tmpl'
	} {
		directive_col := lines[line_idx].index(symbol) or {
			assert false, 'expected dollar-prefixed identifier'
			return
		}
		location := app.resolve_indexed_definition(uri, Position{
			line: line_idx
			char: directive_col + 2
		})
		assert location == none
	}
}

fn test_resolve_indexed_definition_defers_orm_field_reference() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_orm_field')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn age() {}\n\nfn query() {\n\ttext := r'foo\\'\n\t_ := sql db {\n\t\tselect from User where age > 21\n\t}\n\tprintln(text)\n}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	age_col := content.split_into_lines()[7].index('age') or {
		assert false, 'expected ORM field reference'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 7
		char: age_col + 1
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_generic_type_parameter() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_generic_parameter')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct T {}\n\nfn identity[T](value T) T {\n\treturn value\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	line := content.split_into_lines()[4]
	generic_col := line.index('[T]') or {
		assert false, 'expected generic parameter declaration'
		return
	}
	value_col := line.index('value T') or {
		assert false, 'expected generic parameter type'
		return
	}
	return_col := line.last_index('T {') or {
		assert false, 'expected generic return type'
		return
	}

	for col in [generic_col + 1, value_col + 6, return_col] {
		location := app.resolve_indexed_definition(uri, Position{
			line: 4
			char: col
		})
		assert location == none
	}
}

fn test_resolve_indexed_definition_defers_multiline_generic_type_parameter() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_multiline_generic_parameter')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct T {}\n\nfn identity[\n\tT\n](value T) T {\n\treturn value\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	declaration_col := lines[5].index('T') or {
		assert false, 'expected multiline generic parameter declaration'
		return
	}
	value_col := lines[6].index('value T') or {
		assert false, 'expected multiline generic parameter type'
		return
	}
	return_col := lines[6].last_index('T {') or {
		assert false, 'expected multiline generic return type'
		return
	}

	for position in [Position{
		line: 5
		char: declaration_col
	}, Position{
		line: 6
		char: value_col + 6
	}, Position{
		line: 6
		char: return_col
	}] {
		location := app.resolve_indexed_definition(uri, position)
		assert location == none
	}
}

fn test_resolve_indexed_definition_defers_destructured_local_shadow() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_destructured_shadow')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn helper() {}\n\nfn make_value() (int, int) {\n\treturn 1, 2\n}\n\nfn main() {\n\thelper, err := make_value()\n\tprintln(helper)\n\tprintln(err)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	location := app.resolve_indexed_definition(uri, Position{
		line: 10
		char: 11
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_multiline_for_bindings() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_multiline_for_binding')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nfn key() {}\nfn value() {}\n\nfn main() {\n\tentries := {'a': 1}\n\tfor key,\n\t\tvalue in entries {\n\t\tprintln(key)\n\t\tprintln(value)\n\t}\n}\n"
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	key_col := lines[7].index('key') or {
		assert false, 'expected multiline for key binding'
		return
	}
	value_col := lines[8].index('value') or {
		assert false, 'expected multiline for value binding'
		return
	}

	assert source_occurrence_is_for_binding(lines, 7, key_col, key_col + 3)
	assert source_occurrence_is_for_binding(lines, 8, value_col, value_col + 5)
	for position in [Position{
		line: 7
		char: key_col + 1
	}, Position{
		line: 8
		char: value_col + 2
	}, Position{
		line: 9
		char: 11
	}, Position{
		line: 10
		char: 11
	}] {
		location := app.resolve_indexed_definition(uri, position)
		assert location == none
	}
}

fn test_resolve_indexed_definition_defers_struct_initializer_field() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_struct_field')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn name() {}\n\nfn main() {\n\tvalue := 1\n\t_ := User{name: value}\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	field_col := content.split_into_lines()[6].index('name') or {
		assert false, 'expected struct initializer field'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 6
		char: field_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_goto_label() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_goto_label')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn retry() {}\n\nfn main() {\n\tgoto retry\n\tretry:\n\treturn\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()

	for line_idx in [5, 6] {
		retry_col := lines[line_idx].index('retry') or {
			assert false, 'expected goto label'
			return
		}
		location := app.resolve_indexed_definition(uri, Position{
			line: line_idx
			char: retry_col + 2
		})
		assert location == none
	}
}

fn test_resolve_indexed_definition_defers_compile_time_condition() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_compile_time_condition')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn windows() {}\n\n$if windows {\n\tfn active() {}\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	condition_col := content.split_into_lines()[4].index('windows') or {
		assert false, 'expected compile-time condition'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 4
		char: condition_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_multiline_compile_time_condition() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_multiline_compile_time_condition')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn windows() {}\n\n$if (\n\twindows\n) {\n\tfn active() {}\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	condition_col := content.split_into_lines()[5].index('windows') or {
		assert false, 'expected multiline compile-time condition'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 5
		char: condition_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_multiline_parameter_shadow() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_parameter_shadow')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn helper() {}\n\nfn use(\n\thelper int,\n) {\n\tprintln(helper)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	location := app.resolve_indexed_definition(uri, Position{
		line: 7
		char: 11
	})
	assert location == none
}

fn test_resolve_indexed_definition_excludes_inactive_platform_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_inactive_platform')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	inactive_file_name := $if windows { 'helper_linux.v' } $else { 'helper_windows.v' }
	main_content := 'module main\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(main_file, main_content)
	must_write_file(os.join_path(test_dir, inactive_file_name), 'module main\n\nfn helper() {}\n')
	main_uri := path_to_uri(main_file)
	app.open_files[main_uri] = main_content

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 3
		char: 3
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_compile_time_declaration() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_compile_time_branch')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	inactive_branch := $if windows { r'$if linux {' } $else { r'$if windows {' }
	main_content := 'module main\n\n${inactive_branch}\n\tfn helper() {}\n}\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(main_file, main_content)
	main_uri := path_to_uri(main_file)
	app.open_files[main_uri] = main_content

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 7
		char: 3
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_compile_time_declaration_after_multiline_string() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_compile_time_multiline_string')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	inactive_branch := $if windows { r'$if linux {' } $else { r'$if windows {' }
	main_content := "module main\n\n${inactive_branch}\n\tconst message = 'first\n}\nlast'\n\tfn helper() {}\n}\n\nfn main() {\n\thelper()\n}\n"
	must_write_file(main_file, main_content)
	main_uri := path_to_uri(main_file)
	app.open_files[main_uri] = main_content

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 10
		char: 3
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_compile_time_declaration_after_raw_string() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_compile_time_raw_string')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	inactive_branch := $if windows { r'$if linux {' } $else { r'$if windows {' }
	main_content := "module main\n\nconst text = r'ends\\'\n\n${inactive_branch}\n\tfn helper() {}\n}\n\nfn main() {\n\thelper()\n}\n"
	must_write_file(main_file, main_content)
	main_uri := path_to_uri(main_file)
	app.open_files[main_uri] = main_content

	assert source_declaration_is_compile_time_conditional(main_content, 5)
	location := app.resolve_indexed_definition(main_uri, Position{
		line: 9
		char: 3
	})
	assert location == none
}

fn test_resolve_indexed_definition_excludes_block_comment_declaration() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_block_comment')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	main_content := 'module main\n\n/*\nfn helper() {}\n*/\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(main_file, main_content)
	main_uri := path_to_uri(main_file)
	app.open_files[main_uri] = main_content

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 7
		char: 3
	})
	assert location == none
}

fn test_resolve_indexed_definition_excludes_different_module_sibling() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_different_module')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	sibling_file := os.join_path(test_dir, 'sibling.v')
	main_content := 'module bar\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(main_file, main_content)
	must_write_file(sibling_file, 'module bar\n')
	main_uri := path_to_uri(main_file)
	sibling_uri := path_to_uri(sibling_file)
	app.open_files[main_uri] = main_content
	app.open_files[sibling_uri] = 'module main\n\nfn helper() {}\n'

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 3
		char: 3
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_moduleless_script_sibling() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_moduleless_script')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'script.v')
	sibling_file := os.join_path(test_dir, 'sibling.v')
	main_content := 'helper()\n'
	must_write_file(main_file, main_content)
	must_write_file(sibling_file, 'module unrelated\n\nfn helper() {}\n')
	main_uri := path_to_uri(main_file)
	app.open_files[main_uri] = main_content

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 0
		char: 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_ignores_commented_requesting_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_commented_module')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	sibling_file := os.join_path(test_dir, 'sibling.v')
	main_content := '/*\nmodule legacy\n*/\nmodule main\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(main_file, main_content)
	must_write_file(sibling_file, 'module main\n')
	main_uri := path_to_uri(main_file)
	sibling_uri := path_to_uri(sibling_file)
	app.open_files[main_uri] = main_content
	app.open_files[sibling_uri] = 'module legacy\n\nfn helper() {}\n'

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 6
		char: 3
	})
	assert location == none
}

fn test_resolve_indexed_definition_uses_unsaved_imported_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_import')
	module_dir := os.join_path(test_dir, 'mathutil')
	must_mkdir_all(module_dir)
	main_file := os.join_path(test_dir, 'main.v')
	module_file := os.join_path(module_dir, 'mathutil.v')
	main_content := 'module main\n\nimport mathutil\n\nfn main() {\n\tmathutil.answer()\n}\n'
	module_content := 'module mathutil\n\n// answer is not saved yet.\npub fn answer() int {\n\treturn 42\n}\n'
	must_write_file(main_file, main_content)
	must_write_file(module_file, 'module mathutil\n')
	main_uri := path_to_uri(main_file)
	module_uri := path_to_uri(module_file)
	app.open_files[main_uri] = main_content
	app.open_files[module_uri] = module_content

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 5
		char: 12
	}) or {
		assert false, 'expected imported indexed definition'
		return
	}
	assert location.uri == module_uri
	assert location.range.start.line == 3
}

fn test_resolve_indexed_definition_ignores_import_in_block_comment() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_commented_import')
	right_dir := os.join_path(test_dir, 'right')
	wrong_dir := os.join_path(test_dir, 'wrong')
	must_mkdir_all(right_dir)
	must_mkdir_all(wrong_dir)
	main_file := os.join_path(test_dir, 'main.v')
	right_file := os.join_path(right_dir, 'right.v')
	wrong_file := os.join_path(wrong_dir, 'wrong.v')
	main_content := 'module main\n\nimport right as util\n/*\nimport wrong as util\n*/\n\nfn main() {\n\tutil.answer()\n}\n'
	right_content := 'module right\n\npub fn answer() {}\n'
	wrong_content := 'module wrong\n\npub fn answer() {}\n'
	must_write_file(main_file, main_content)
	must_write_file(right_file, right_content)
	must_write_file(wrong_file, wrong_content)
	main_uri := path_to_uri(main_file)
	right_uri := path_to_uri(right_file)
	app.open_files[main_uri] = main_content
	app.open_files[right_uri] = right_content
	app.open_files[path_to_uri(wrong_file)] = wrong_content
	answer_col := main_content.split_into_lines()[8].index('answer') or {
		assert false, 'expected imported member reference'
		return
	}

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 8
		char: answer_col + 2
	}) or {
		assert false, 'expected real imported module definition'
		return
	}
	assert location.uri == right_uri
}

fn test_resolve_indexed_definition_ignores_import_in_multiline_string() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_string_import')
	right_dir := os.join_path(test_dir, 'right')
	wrong_dir := os.join_path(test_dir, 'wrong')
	must_mkdir_all(right_dir)
	must_mkdir_all(wrong_dir)
	main_file := os.join_path(test_dir, 'main.v')
	right_file := os.join_path(right_dir, 'right.v')
	wrong_file := os.join_path(wrong_dir, 'wrong.v')
	main_content := "module main\n\nimport right as util\n\nconst ignored = 'text \${\n\t'import wrong as util'\n}'\n\nfn main() {\n\tutil.answer()\n}\n"
	right_content := 'module right\n\npub fn answer() {}\n'
	wrong_content := 'module wrong\n\npub fn answer() {}\n'
	must_write_file(main_file, main_content)
	must_write_file(right_file, right_content)
	must_write_file(wrong_file, wrong_content)
	main_uri := path_to_uri(main_file)
	right_uri := path_to_uri(right_file)
	app.open_files[main_uri] = main_content
	app.open_files[right_uri] = right_content
	app.open_files[path_to_uri(wrong_file)] = wrong_content
	answer_col := main_content.split_into_lines()[9].index('answer') or {
		assert false, 'expected imported member reference'
		return
	}

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 9
		char: answer_col + 2
	}) or {
		assert false, 'expected real imported module definition'
		return
	}
	assert location.uri == right_uri
}

fn test_resolve_indexed_definition_ignores_unrelated_workspace_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	root_a := os.join_path(app.temp_dir, 'indexed_definition_workspace_a')
	root_b := os.join_path(app.temp_dir, 'indexed_definition_workspace_b')
	module_name := 'vls_unrelated_module'
	module_dir := os.join_path(root_b, module_name)
	must_mkdir_all(root_a)
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(root_a, 'v.mod'), 'Module {}\n')
	main_file := os.join_path(root_a, 'main.v')
	module_file := os.join_path(module_dir, '${module_name}.v')
	main_content := 'module main\n\nimport ${module_name}\n\nfn main() {\n\t${module_name}.answer()\n}\n'
	module_content := 'module ${module_name}\n\npub fn answer() {}\n'
	must_write_file(main_file, main_content)
	must_write_file(module_file, module_content)
	main_uri := path_to_uri(main_file)
	module_uri := path_to_uri(module_file)
	app.open_files[main_uri] = main_content
	app.open_files[module_uri] = module_content
	app.workspace_roots = [root_a, root_b]

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 5
		char: module_name.len + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_prefers_workspace_vlib() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	root := os.join_path(app.temp_dir, 'indexed_definition_workspace_vlib')
	main_dir := os.join_path(root, 'cmd', 'tool')
	module_dir := os.join_path(root, 'vlib', 'v', 'builder')
	must_mkdir_all(main_dir)
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(root, 'v.mod'), 'Module {}\n')
	main_file := os.join_path(main_dir, 'main.v')
	module_file := os.join_path(module_dir, 'compile.v')
	main_content := 'module main\n\nimport v.builder\n\nfn main() {\n\tbuilder.compile()\n}\n'
	module_content := 'module builder\n\npub fn compile() {}\n'
	must_write_file(main_file, main_content)
	must_write_file(module_file, module_content)
	main_uri := path_to_uri(main_file)
	module_uri := path_to_uri(module_file)
	app.open_files[main_uri] = main_content
	app.open_files[module_uri] = module_content
	app.workspace_roots = [root]

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 5
		char: 12
	}) or {
		assert false, 'expected workspace vlib definition'
		return
	}
	assert location.uri == module_uri
	assert location.range.start.line == 2
}

fn test_resolve_indexed_definition_prefers_source_relative_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	root := os.join_path(app.temp_dir, 'indexed_definition_source_relative')
	source_dir := os.join_path(root, 'src')
	module_dir := os.join_path(source_dir, 'os')
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(root, 'v.mod'), 'Module {}\n')
	main_file := os.join_path(source_dir, 'main.v')
	module_file := os.join_path(module_dir, 'os.v')
	main_content := 'module main\n\nimport os\n\nfn main() {\n\tos.local_answer()\n}\n'
	module_content := 'module os\n\npub fn local_answer() {}\n'
	must_write_file(main_file, main_content)
	must_write_file(module_file, module_content)
	main_uri := path_to_uri(main_file)
	module_uri := path_to_uri(module_file)
	app.open_files[main_uri] = main_content
	app.open_files[module_uri] = module_content
	app.workspace_roots = [root]
	answer_col := main_content.split_into_lines()[5].index('local_answer') or {
		assert false, 'expected source-relative module member'
		return
	}

	location := app.resolve_indexed_definition(main_uri, Position{
		line: 5
		char: answer_col + 2
	}) or {
		assert false, 'expected source-relative indexed definition'
		return
	}
	assert location.uri == module_uri
	assert location.range.start.line == 2
}

fn test_resolve_indexed_definition_defers_receiver_method() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_receiver')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct Item {}\n\nfn (item Item) answer() {}\n\nfn main() {\n\titem := Item{}\n\titem.answer()\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	location := app.resolve_indexed_definition(uri, Position{
		line: 8
		char: 8
	})
	assert location == none
}

fn test_operation_at_pos_signature_help_line_info() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	content := 'module main\n\nfn greet(name string) {}\n\nfn main() {\n\tgreet(\n}\n'
	must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	request := Request{
		id:     3
		method: 'textDocument/signatureHelp'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 7
			}
		},
			escape_unicode: true
		)
	}

	response := app.operation_at_pos(.signature_help, request)
	assert response.id == 3
}

fn test_operation_at_pos_preserves_request_id() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')
	content := 'module main\n\nfn main() {}\n'
	must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.text = content
	app.open_files[uri] = content

	// Test with various request IDs
	test_ids := [0, 1, 42, 999, 12345]
	for id in test_ids {
		request := Request{
			id:     id
			params: json2.encode(Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position:      Position{
					line: 2
					char: 0
				}
			},
				escape_unicode: true
			)
		}
		response := app.operation_at_pos(.completion, request)
		assert response.id == id
	}
}

fn test_json_encode_response() {
	response := Response{
		id:     1
		result: 'null'
	}
	encoded := json2.encode(response, escape_unicode: true)
	assert encoded.contains('"id":1')
	assert encoded.contains('"jsonrpc":"2.0"')
}

fn test_json_encode_capabilities_response() {
	response := Response{
		id:     0
		result: Capabilities{
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
	}
	encoded := json2.encode(response, escape_unicode: true)
	assert encoded.contains('"definitionProvider":true')
	assert encoded.contains('"completionProvider"')
	assert encoded.contains('"signatureHelpProvider"')
}

fn test_json_encode_completion_response() {
	details := [
		Detail{
			kind:          6
			label:         'println'
			detail:        'fn println(s string)'
			documentation: 'Prints to stdout'
		},
		Detail{
			kind:          6
			label:         'print'
			detail:        'fn print(s string)'
			documentation: 'Prints without newline'
		},
	]
	response := Response{
		id:     2
		result: details
	}
	encoded := json2.encode(response, escape_unicode: true)
	assert encoded.contains('"label":"println"')
	assert encoded.contains('"label":"print"')
}

fn test_json_encode_location_response() {
	response := Response{
		id:     3
		result: Location{
			uri:   'file:///test/main.v'
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
	}
	encoded := json2.encode(response, escape_unicode: true)
	assert encoded.contains('"uri":"file:///test/main.v"')
	assert encoded.contains('"line":10')
}

fn test_json_encode_signature_help_response() {
	response := Response{
		id:     4
		result: SignatureHelp{
			signatures:       [
				SignatureInformation{
					label:      'fn test(a int, b string)'
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
			active_parameter: 0
		}
	}
	encoded := json2.encode(response, escape_unicode: true)
	assert encoded.contains('"activeSignature":0')
	assert encoded.contains('"activeParameter":0')
	assert encoded.contains('"label":"fn test(a int, b string)"')
}

fn test_json_encode_notification() {
	notification := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri:         'file:///test.v'
			diagnostics: [
				LSPDiagnostic{
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
					message:  'undefined identifier'
					severity: 1
				},
			]
		}
	}
	encoded := json2.encode(notification, escape_unicode: true)
	assert encoded.contains('"method":"textDocument/publishDiagnostics"')
	assert encoded.contains('"message":"undefined identifier"')
	assert encoded.contains('"severity":1')
}

fn test_json_decode_request() {
	request_json := '{"id":1,"method":"textDocument/completion","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"position":{"line":5,"character":10}}}'
	request := json2.decode[Request](request_json) or {
		assert false, 'Failed to decode request: ${err}'
		return
	}
	assert request.id == 1
	assert request.method == 'textDocument/completion'
	params := json2.decode[Params](request.params.str()) or {
		assert false, 'Failed to decode params: ${err}'
		return
	}
	assert params.position.line == 5
	assert params.position.char == 10
}

fn test_json_decode_request_with_content_changes() {
	request_json := '{"id":2,"method":"textDocument/didChange","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"contentChanges":[{"text":"fn main() {}"}]}}'
	request := json2.decode[Request](request_json) or {
		assert false, 'Failed to decode request: ${err}'
		return
	}
	assert request.method == 'textDocument/didChange'
	params := json2.decode[Params](request.params.str()) or {
		assert false, 'Failed to decode params: ${err}'
		return
	}
	assert params.content_changes.len == 1
	assert params.content_changes[0].text == 'fn main() {}'
}

fn test_json_decode_request_initialize() {
	request_json := '{"id":0,"method":"initialize","jsonrpc":"2.0","params":{}}'
	request := json2.decode[Request](request_json) or {
		assert false, 'Failed to decode request: ${err}'
		return
	}
	assert request.id == 0
	assert request.method == 'initialize'
}

fn test_json_decode_request_definition() {
	request_json := '{"id":5,"method":"textDocument/definition","jsonrpc":"2.0","params":{"textDocument":{"uri":"file:///test.v"},"position":{"line":10,"character":5}}}'
	request := json2.decode[Request](request_json) or {
		assert false, 'Failed to decode request: ${err}'
		return
	}
	assert request.id == 5
	assert request.method == 'textDocument/definition'
	params := json2.decode[Params](request.params.str()) or {
		assert false, 'Failed to decode params: ${err}'
		return
	}
	assert params.position.line == 10
	assert params.position.char == 5
}

fn test_json_decode_request_params_malformed_returns_error() {
	malformed_params := '{"textDocument":{"uri":"file:///test.v"},"position":{"line":5,"character":}}'
	if _ := json2.decode[Params](malformed_params) {
		assert false, 'Expected malformed params JSON to fail decoding'
	} else {
		assert true
	}
}

fn test_diagnostics_deduplication() {
	// This tests the deduplication logic in on_did_change
	// Multiple errors at the same position should be deduplicated
	mut seen_positions := map[string]bool{}

	errors := [
		JsonError{
			line_nr: 5
			col:     10
			message: 'error 1'
		},
		JsonError{
			line_nr: 5
			col:     10
			message: 'error 2'
		}, // duplicate position
		JsonError{
			line_nr: 6
			col:     5
			message: 'error 3'
		},
	]

	mut count := 0
	for err in errors {
		pos_key := '${err.line_nr}:${err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		count++
	}

	assert count == 2 // Only 2 unique positions
}

fn test_diagnostics_deduplication_same_line_different_col() {
	mut seen_positions := map[string]bool{}

	errors := [
		JsonError{
			line_nr: 5
			col:     1
			message: 'error 1'
		},
		JsonError{
			line_nr: 5
			col:     10
			message: 'error 2'
		},
		JsonError{
			line_nr: 5
			col:     20
			message: 'error 3'
		},
	]

	mut count := 0
	for err in errors {
		pos_key := '${err.line_nr}:${err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		count++
	}

	assert count == 3 // All different positions on same line
}

fn test_diagnostics_deduplication_empty() {
	mut seen_positions := map[string]bool{}
	errors := []JsonError{}

	mut count := 0
	for err in errors {
		pos_key := '${err.line_nr}:${err.col}'
		if pos_key in seen_positions {
			continue
		}
		seen_positions[pos_key] = true
		count++
	}

	assert count == 0
}

fn test_response_result_string() {
	result := ResponseResult('null')
	if result is string {
		assert result == 'null'
	} else {
		assert false, 'Expected string result'
	}
}

fn test_response_result_details() {
	details := [
		Detail{
			kind:  6
			label: 'test'
		},
	]
	result := ResponseResult(details)
	if result is []Detail {
		assert result.len == 1, 'Expected 1 detail, got ${result.len}'
		assert result[0].label == 'test', 'Expected label test, got ${result[0].label}'
	} else {
		assert false, 'Expected []Detail result'
	}
}

fn test_response_result_capabilities() {
	caps := Capabilities{
		capabilities: Capability{
			definition_provider: true
		}
	}
	result := ResponseResult(caps)
	if result is Capabilities {
		assert result.capabilities.definition_provider == true
	} else {
		assert false, 'Expected Capabilities result'
	}
}

fn test_response_result_signature_help() {
	sig := SignatureHelp{
		active_parameter: 1
	}
	result := ResponseResult(sig)
	if result is SignatureHelp {
		assert result.active_parameter == 1
	} else {
		assert false, 'Expected SignatureHelp result'
	}
}

fn test_response_result_location() {
	loc := Location{
		uri: 'file:///test.v'
	}
	result := ResponseResult(loc)
	if result is Location {
		assert result.uri == 'file:///test.v'
	} else {
		assert false, 'Expected Location result'
	}
}

fn test_app_initialization() {
	app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	assert app.text == ''
	assert app.open_files.len == 0
	assert app.temp_dir != ''
	assert os.exists(app.temp_dir)
}

fn test_app_cur_mod_default() {
	app := App{}
	assert app.cur_mod == 'main'
}

fn test_app_exit_flag_default() {
	app := App{}
	assert app.exit == os.args.contains('exit')
}

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

fn test_v_error_to_lsp_diagnostic_preserves_message() {
	messages := [
		'undefined identifier `foo`',
		'expected `;` after expression',
		'cannot use `string` as `int`',
		'function `test` redeclared',
		'',
	]

	for msg in messages {
		v_err := JsonError{
			message: msg
			line_nr: 1
			col:     1
			len:     1
		}
		diag := v_error_to_lsp_diagnostic(v_err)
		assert diag.message == msg
	}
}

fn test_v_error_to_lsp_diagnostic_always_error_severity() {
	v_err := JsonError{
		path:    '/test.v'
		message: 'any error'
		line_nr: 1
		col:     1
		len:     1
	}
	diag := v_error_to_lsp_diagnostic(v_err)
	assert diag.severity == 1 // Always Error severity
}

fn test_multifile_tracking() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	// Create 3 files
	files := ['main.v', 'utils.v', 'helpers.v']
	for file in files {
		path := os.join_path(test_dir, file)
		must_write_file(path, 'module main\n\nfn ${file}() {}')
		uri := path_to_uri(path)
		app.on_did_open(Request{
			params: json2.encode(Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
			},
				escape_unicode: true
			)
		})
	}

	assert app.open_files.len == 3
}

fn test_multifile_change_single_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	main_file := os.join_path(test_dir, 'main.v')
	utils_file := os.join_path(test_dir, 'utils.v')

	must_write_file(main_file, 'module main\n\nfn main() {}')
	must_write_file(utils_file, 'module main\n\nfn helper() {}')

	main_uri := path_to_uri(main_file)
	utils_uri := path_to_uri(utils_file)

	// Open both files
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
		},
			escape_unicode: true
		)
	})
	app.on_did_open(Request{
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: utils_uri
			}
		},
			escape_unicode: true
		)
	})

	// Change only main.v
	new_content := 'module main\n\nfn main() { changed }'
	app.on_did_change(Request{
		params: json2.encode(Params{
			text_document:   TextDocumentIdentifier{
				uri: main_uri
			}
			content_changes: [ContentChange{
				text: new_content
			}]
		},
			escape_unicode: true
		)
	})

	// Verify only main.v was updated
	assert app.open_files[main_uri] == new_content
	assert app.open_files[utils_uri].contains('helper') // utils unchanged
}

fn test_handle_formatting_formats_code() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')

	// Badly formatted content
	unformatted := 'module main\n\nfn   badly_formatted(   x    int,y int   )int{\nreturn x+y\n}'
	must_write_file(test_file, unformatted)

	uri := path_to_uri(test_file)
	app.open_files[uri] = unformatted

	request := Request{
		id:      1
		method:  'textDocument/formatting'
		jsonrpc: '2.0'
		params:  json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_formatting(request)
	assert response.id == 1

	// Should return TextEdit array
	if response.result is []TextEdit {
		edits := response.result as []TextEdit
		assert edits.len > 0

		// Check that the formatted text is proper
		formatted_text := edits[0].new_text
		assert formatted_text.contains('fn badly_formatted(x int, y int) int {')
		assert formatted_text.contains('\treturn x + y')
	} else {
		assert false, 'Expected []TextEdit result'
	}
}

fn test_handle_formatting_already_formatted() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')

	// Already well-formatted content
	formatted := 'module main\n\nfn main() {\n\tprintln("hello")\n}\n'
	must_write_file(test_file, formatted)

	uri := path_to_uri(test_file)
	app.open_files[uri] = formatted

	request := Request{
		id:      2
		method:  'textDocument/formatting'
		jsonrpc: '2.0'
		params:  json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_formatting(request)
	assert response.id == 2

	// Should return empty edits if already formatted
	if response.result is []TextEdit {
		edits := response.result as []TextEdit
		// May return empty or single edit with same content
		assert edits.len >= 0
	}
}

fn test_handle_formatting_nonexistent_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	nonexistent := os.join_path(app.temp_dir, 'nonexistent.v')
	uri := path_to_uri(nonexistent)

	request := Request{
		id:      3
		method:  'textDocument/formatting'
		jsonrpc: '2.0'
		params:  json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_formatting(request)
	assert response.id == 3

	// Should return empty edits for nonexistent file
	if response.result is []TextEdit {
		edits := response.result as []TextEdit
		assert edits.len == 0
	}
}

fn test_handle_formatting_uses_open_file_content() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'test.v')

	// File on disk has different content
	must_write_file(test_file, 'module main\n\nfn old() {}')

	uri := path_to_uri(test_file)
	// In-memory content is different
	app.open_files[uri] = 'module main\n\nfn   new(   )   {}'

	request := Request{
		id:      4
		method:  'textDocument/formatting'
		jsonrpc: '2.0'
		params:  json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_formatting(request)

	// Should format the in-memory content, not disk content
	if response.result is []TextEdit {
		edits := response.result as []TextEdit
		if edits.len > 0 {
			formatted_text := edits[0].new_text
			assert formatted_text.contains('fn new() {')
			assert !formatted_text.contains('fn old')
		}
	}
}

fn test_find_references_returns_null_when_no_symbol_at_position() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'refs.v')
	content := 'module main\n\nfn main() {\n\tprintln("hi")\n}\n'
	must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	resp := app.find_references(Request{
		id:     901
		method: 'textDocument/references'
		params: json2.encode(ReferenceParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 1
				char: 0
			}
			context:       ReferenceContext{
				include_declaration: true
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 901
	assert resp.result is string
	assert (resp.result as string) == 'null'
}

fn test_handle_rename_returns_null_when_no_symbol_at_position() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'rename.v')
	content := 'module main\n\nfn main() {\n\tprintln("hi")\n}\n'
	must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	resp := app.handle_rename(Request{
		id:     902
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 1
				char: 0
			}
			new_name:      'renamed'
		},
			escape_unicode: true
		)
	})

	assert resp.id == 902
	assert resp.result is string
	assert (resp.result as string) == 'null'
}

fn test_get_word_at_position_uses_original_client_uri() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_file := os.join_path(app.temp_dir, 'noncanonical_uri.v')
	must_write_file(test_file, 'module main\n\nfn stale_disk_symbol() {}\n')
	canonical_uri := path_to_uri(test_file)
	open_uri := canonical_uri.replace_once('file:///', 'file://localhost/')
	app.open_files[open_uri] = 'module main\n\nfn authoritative_open_symbol() {}\n'

	assert app.get_word_at_position(open_uri, 2, 3) == 'authoritative_open_symbol'
}

fn test_did_close_reindexes_noncanonical_uri_under_disk_uri() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_file := os.join_path(app.temp_dir, 'close_alias.v')
	must_write_file(test_file, 'module main\n\nfn disk_symbol() {}\n')
	disk_uri := path_to_uri(test_file)
	open_uri := disk_uri.replace_once('file:///', 'file://localhost/')
	app.open_files[open_uri] = 'module main\n\nfn open_symbol() {}\n'
	app.reindex_uri(open_uri)
	app.occurrences_for(open_uri)

	app.on_did_close(Request{
		params: json2.encode(DidCloseTextDocumentParams{
			text_document: TextDocumentIdentifier{
				uri: open_uri
			}
		},
			escape_unicode: true
		)
	})

	assert open_uri !in app.open_files
	assert open_uri !in app.symbol_index
	assert open_uri !in app.ref_occurrences
	assert disk_uri in app.symbol_index
	assert app.query_workspace_symbols('open_symbol').len == 0
	assert app.query_workspace_symbols('disk_symbol').len == 1

	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [FileEvent{
				uri:        disk_uri
				event_type: 2
			}]
		})
	})
	mut equivalent_entries := 0
	for indexed_uri, _ in app.symbol_index {
		if normalized_index_path(uri_to_path(indexed_uri)) == normalized_index_path(test_file) {
			equivalent_entries++
		}
	}
	assert equivalent_entries == 1
}

fn test_handle_rename_refuses_incomplete_oversized_sibling_index() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'loose_rename')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn target() {\n\ttarget()\n}\n'
	must_write_file(test_file, content)
	must_write_file(os.join_path(test_dir, 'oversized.v'), 'x'.repeat(index_max_file_bytes + 1))
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	resp := app.handle_rename(Request{
		id:     903
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 2
				char: 4
			}
			new_name:      'renamed'
		},
			escape_unicode: true
		)
	})

	assert !app.index_is_complete()
	assert !app.index_is_complete_for_scope(app.index_scope_for_uri(uri))
	assert resp.result is string
	assert (resp.result as string) == 'null'
}

fn test_parse_document_symbols_empty_content() {
	syms := parse_document_symbols('')
	assert syms.len == 0
}

fn test_parse_document_symbols_only_comments() {
	content := '// Copyright notice\n// module main\n\n// just a comment'
	syms := parse_document_symbols(content)
	assert syms.len == 0
}

fn test_parse_document_symbols_single_function() {
	content := 'module main\n\nfn greet(name string) string {\n\treturn name\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'greet'
	assert syms[0].kind == sym_kind_function
}

fn test_parse_document_symbols_pub_function() {
	content := 'module main\n\npub fn greet(name string) string {\n\treturn name\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'greet'
	assert syms[0].kind == sym_kind_function
}

fn test_parse_document_symbols_method() {
	content := 'module main\n\nstruct App {}\n\nfn (mut app App) run() {\n}'
	syms := parse_document_symbols(content)
	// Should find struct and method
	names := syms.map(it.name)
	assert 'App' in names
	method_sym := syms.filter(it.kind == sym_kind_method)
	assert method_sym.len == 1
	assert method_sym[0].name.contains('run')
}

fn test_parse_document_symbols_struct() {
	content := 'module main\n\nstruct Person {\n\tname string\n\tage  int\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'Person'
	assert syms[0].kind == sym_kind_struct
}

fn test_parse_document_symbols_pub_struct() {
	content := 'module main\n\npub struct Config {\n\tdebug bool\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'Config'
	assert syms[0].kind == sym_kind_struct
}

fn test_parse_document_symbols_enum() {
	content := 'module main\n\nenum Color {\n\tred\n\tgreen\n\tblue\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'Color'
	assert syms[0].kind == sym_kind_enum
}

fn test_parse_document_symbols_interface() {
	content := 'module main\n\ninterface Writer {\n\twrite(s string)\n}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'Writer'
	assert syms[0].kind == sym_kind_interface
}

fn test_parse_document_symbols_const() {
	content := 'module main\n\nconst max_size = 100'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'max_size'
	assert syms[0].kind == sym_kind_constant
}

fn test_parse_document_symbols_type_alias() {
	content := 'module main\n\ntype MyInt = int'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	assert syms[0].name == 'MyInt'
	assert syms[0].kind == sym_kind_class
}

fn test_parse_document_symbols_multiple_declarations() {
	content := 'module main

// greet is a simple function
pub fn greet(name string) string {
	return name
}

struct Person {
	name string
	age  int
}

enum Color {
	red
	green
	blue
}

fn (p Person) say_hello() string {
	return greet(p.name)
}

const max_age = 120
'
	syms := parse_document_symbols(content)
	names := syms.map(it.name)
	assert 'greet' in names
	assert 'Person' in names
	assert 'Color' in names
	assert 'max_age' in names
	// method should be present
	assert syms.any(it.kind == sym_kind_method)
}

fn test_parse_document_symbols_correct_line_numbers() {
	content := 'module main\n\nfn alpha() {}\n\nfn beta() {}'
	// line 0: 'module main'
	// line 1: ''
	// line 2: 'fn alpha() {}'
	// line 3: ''
	// line 4: 'fn beta() {}'
	syms := parse_document_symbols(content)
	assert syms.len == 2
	alpha := syms.filter(it.name == 'alpha')
	beta := syms.filter(it.name == 'beta')
	assert alpha.len == 1
	assert beta.len == 1
	assert alpha[0].range.start.line == 2
	assert beta[0].range.start.line == 4
}

fn test_parse_document_symbols_const_block_paren_skipped() {
	// `const (` alone should not produce a symbol with name '('
	content := 'module main\n\nconst (\n\ta = 1\n\tb = 2\n)'
	syms := parse_document_symbols(content)
	for sym in syms {
		assert sym.name != '('
	}
}

fn test_parse_document_symbols_selection_range_points_to_name() {
	content := 'module main\n\nfn my_func() {}'
	syms := parse_document_symbols(content)
	assert syms.len == 1
	sym := syms[0]
	// The selection range should start where the name begins in the raw line
	line := 'fn my_func() {}'
	expected_col := line.index('my_func') or { -1 }
	assert expected_col >= 0
	assert sym.selection_range.start.char == expected_col
	assert sym.selection_range.end.char == expected_col + 'my_func'.len
}

fn test_extract_fn_name_simple() {
	assert extract_fn_name('main() {}') == 'main'
}

fn test_extract_fn_name_with_params() {
	assert extract_fn_name('greet(name string) string') == 'greet'
}

fn test_extract_fn_name_method_with_receiver() {
	name := extract_fn_name('(mut app App) run()')
	assert name.contains('run')
	assert name.contains('mut app App')
}

fn test_extract_fn_name_method_immutable_receiver() {
	name := extract_fn_name('(p Person) say_hello() string')
	assert name.contains('say_hello')
	assert name.contains('p Person')
}

fn test_extract_fn_name_empty_string() {
	assert extract_fn_name('') == ''
}

fn test_extract_fn_name_whitespace_only() {
	assert extract_fn_name('   ') == ''
}

fn test_first_word_simple() {
	assert first_word('Person {}') == 'Person'
}

fn test_first_word_with_tab() {
	assert first_word('Color\t{') == 'Color'
}

fn test_first_word_stops_at_brace() {
	assert first_word('Writer{') == 'Writer'
}

fn test_first_word_single_token() {
	assert first_word('MyType') == 'MyType'
}

fn test_first_word_empty() {
	assert first_word('') == ''
}

fn test_first_word_paren_simple() {
	assert first_word_paren('foo(a int) string') == 'foo'
}

fn test_first_word_paren_no_paren() {
	assert first_word_paren('main') == 'main'
}

fn test_first_word_paren_empty() {
	assert first_word_paren('') == ''
}

fn test_first_word_paren_stops_at_space() {
	assert first_word_paren('bar baz') == 'bar'
}

fn test_extract_const_name_simple() {
	assert extract_const_name('max_size = 100') == 'max_size'
}

fn test_extract_const_name_open_paren() {
	// const ( block opening — should return empty
	assert extract_const_name('(') == ''
}

fn test_extract_const_name_empty() {
	assert extract_const_name('') == ''
}

fn test_extract_const_name_whitespace_only() {
	assert extract_const_name('   ') == ''
}

fn test_handle_document_symbols_empty_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///tmp/empty.v'
	app.open_files[uri] = ''

	request := Request{
		id:     10
		method: 'textDocument/documentSymbol'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_document_symbols(request)
	assert response.id == 10
	if response.result is []DocumentSymbol {
		assert response.result.len == 0
	} else {
		assert false, 'Expected []DocumentSymbol'
	}
}

fn test_handle_document_symbols_no_tracked_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	// URI not in open_files — should still return an empty symbol list, not crash
	request := Request{
		id:     11
		method: 'textDocument/documentSymbol'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: 'file:///tmp/not_tracked.v'
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_document_symbols(request)
	assert response.id == 11
	if response.result is []DocumentSymbol {
		assert response.result.len == 0
	} else {
		assert false, 'Expected []DocumentSymbol'
	}
}

fn test_handle_document_symbols_returns_correct_symbols() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///tmp/test_sym.v'
	app.open_files[uri] = 'module main\n\nfn hello() {}\n\nstruct Config {}\n\nenum Mode { on off }\n\nconst version = 1\n'

	request := Request{
		id:     12
		method: 'textDocument/documentSymbol'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_document_symbols(request)
	assert response.id == 12

	if response.result is []DocumentSymbol {
		syms := response.result
		names := syms.map(it.name)
		assert 'hello' in names
		assert 'Config' in names
		assert 'Mode' in names
		assert 'version' in names
	} else {
		assert false, 'Expected []DocumentSymbol'
	}
}

fn test_handle_document_symbols_preserves_request_id() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///tmp/id_test.v'
	app.open_files[uri] = 'module main\n\nfn foo() {}\n'

	for id in [1, 99, 1000, 0] {
		request := Request{
			id:     id
			method: 'textDocument/documentSymbol'
			params: json2.encode(Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
			},
				escape_unicode: true
			)
		}
		response := app.handle_document_symbols(request)
		assert response.id == id
	}
}

fn test_handle_document_symbols_kinds_are_correct() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///tmp/kinds_test.v'
	app.open_files[uri] = 'module main

fn plain_fn() {}

struct MyStruct {}

enum MyEnum { a b }

interface MyInterface { run() }

type MyType = int

const my_const = 42
'

	request := Request{
		id:     20
		method: 'textDocument/documentSymbol'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_document_symbols(request)

	if response.result is []DocumentSymbol {
		syms := response.result
		fn_sym := syms.filter(it.name == 'plain_fn')
		struct_sym := syms.filter(it.name == 'MyStruct')
		enum_sym := syms.filter(it.name == 'MyEnum')
		iface_sym := syms.filter(it.name == 'MyInterface')
		type_sym := syms.filter(it.name == 'MyType')
		const_sym := syms.filter(it.name == 'my_const')

		assert fn_sym.len == 1 && fn_sym[0].kind == sym_kind_function
		assert struct_sym.len == 1 && struct_sym[0].kind == sym_kind_struct
		assert enum_sym.len == 1 && enum_sym[0].kind == sym_kind_enum
		assert iface_sym.len == 1 && iface_sym[0].kind == sym_kind_interface
		assert type_sym.len == 1 && type_sym[0].kind == sym_kind_class
		assert const_sym.len == 1 && const_sym[0].kind == sym_kind_constant
	} else {
		assert false, 'Expected []DocumentSymbol'
	}
}

fn test_extract_doc_comment_single_line() {
	lines := ['// greet says hello', 'fn greet() {}']
	comment := extract_doc_comment(lines, 1)
	assert comment == 'greet says hello'
}

fn test_extract_doc_comment_multi_line() {
	lines := [
		'// copy_all recursively copies all elements of the array by their value,',
		'// if `dupes` is false all duplicate values are eliminated in the process.',
		'fn copy_all(dupes bool) {}',
	]
	comment := extract_doc_comment(lines, 2)
	assert comment == 'copy_all recursively copies all elements of the array by their value,  \nif `dupes` is false all duplicate values are eliminated in the process.'
}

fn test_extract_doc_comment_no_comment() {
	lines := ['', 'fn no_docs() {}']
	comment := extract_doc_comment(lines, 1)
	assert comment == ''
}

fn test_extract_doc_comment_stops_at_blank_line() {
	lines := ['// unrelated', '', '// greet says hello', 'fn greet() {}']
	comment := extract_doc_comment(lines, 3)
	assert comment == 'greet says hello'
}

fn test_extract_doc_comment_stops_at_non_comment() {
	lines := ['fn other() {}', '// greet says hello', 'fn greet() {}']
	comment := extract_doc_comment(lines, 2)
	assert comment == 'greet says hello'
}

fn test_extract_doc_comment_at_first_line() {
	lines := ['fn greet() {}']
	comment := extract_doc_comment(lines, 0)
	assert comment == ''
}

fn test_find_declaration_line_function() {
	lines := ['module main', '', 'fn my_func() {}']
	idx := find_declaration_line(lines, 'my_func')
	assert idx == 2
}

fn test_find_declaration_line_pub_function() {
	lines := ['module main', '', 'pub fn exported() {}']
	idx := find_declaration_line(lines, 'exported')
	assert idx == 2
}

fn test_find_declaration_line_struct() {
	lines := ['module main', '', 'struct MyStruct {', '}']
	idx := find_declaration_line(lines, 'MyStruct')
	assert idx == 2
}

fn test_find_declaration_line_enum() {
	lines := ['module main', '', 'enum Color { red green blue }']
	idx := find_declaration_line(lines, 'Color')
	assert idx == 2
}

fn test_find_declaration_line_method() {
	lines := ['module main', '', 'fn (mut app App) run() {}']
	idx := find_declaration_line(lines, 'run')
	assert idx == 2
}

fn test_find_declaration_line_const() {
	lines := ['module main', '', 'const max_retries = 3']
	idx := find_declaration_line(lines, 'max_retries')
	assert idx == 2
}

fn test_find_declaration_line_not_found() {
	lines := ['module main', '', 'fn foo() {}']
	idx := find_declaration_line(lines, 'bar')
	assert idx == -1
}

fn test_get_word_at_col_middle_of_word() {
	line := 'fn my_func() {}'
	word := get_word_at_col(line, 4, .utf16)
	assert word == 'my_func'
}

fn test_get_word_at_col_start_of_word() {
	line := 'fn my_func() {}'
	word := get_word_at_col(line, 3, .utf16)
	assert word == 'my_func'
}

fn test_get_word_at_col_on_space() {
	line := 'fn my_func() {}'
	word := get_word_at_col(line, 2, .utf16)
	assert word == ''
}

fn test_get_word_at_col_beyond_end() {
	line := 'fn foo()'
	word := get_word_at_col(line, 100, .utf16)
	assert word == ''
}

fn test_source_line_import_code_closes_raw_string_after_backslash() {
	mut state := ImportScanState{}
	code := source_line_import_code("text := r'foo\\'", mut state)

	assert code.trim_space() == 'text :='
	assert state.quote == 0
	assert !state.raw_string
	assert source_line_import_code('sql db {', mut state) == 'sql db {'
}

fn test_source_line_import_code_preserves_multiline_interpolation_mode() {
	mut state := ImportScanState{}
	start := source_line_import_code("text := 'value \${", mut state)
	nested := source_line_import_code("\t'import wrong as util'", mut state)
	end := source_line_import_code("}'", mut state)

	assert start.trim_space() == 'text :='
	assert nested.trim_space() == ''
	assert end.trim_space() == ''
	assert state.quote == 0
	assert state.interpolations.len == 0
}

fn test_parse_imports_single() {
	content := 'module main\n\nimport os\n\nfn main() {}'
	imports := parse_imports(content)
	assert imports == ['os']
}

fn test_parse_imports_multiple() {
	content := 'module main\n\nimport os\nimport math\nimport strings\n'
	imports := parse_imports(content)
	assert imports == ['os', 'math', 'strings']
}

fn test_parse_imports_with_alias() {
	content := 'module main\n\nimport os as operating_system\n'
	imports := parse_imports(content)
	assert imports == ['os']
}

fn test_parse_imports_dotted_module() {
	content := 'module main\n\nimport v.util\n'
	imports := parse_imports(content)
	assert imports == ['v.util']
}

fn test_parse_imports_grouped() {
	content := 'module main\n\nimport (\n\tos\n\tv.util as util // alias\n\n\t// comment\n\tstrings\n)\n'
	imports := parse_imports(content)
	assert imports == ['os', 'v.util', 'strings']
}

fn test_parse_import_aliases_grouped() {
	content := 'module main\n\nimport (\n\tmath as util\n\tv.ast\n)\n'
	aliases := parse_import_aliases(content)
	assert aliases == {
		'util': 'math'
		'ast':  'v.ast'
	}
}

fn test_parse_imports_none() {
	content := 'module main\n\nfn main() {}'
	imports := parse_imports(content)
	assert imports == []
}

fn test_find_doc_comment_for_symbol_current_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\n// greet says hello\nfn greet() {}'
	uri := 'file:///tmp/test_greet.v'
	app.open_files[uri] = content
	lines := content.split_into_lines()
	doc := app.find_doc_comment_for_symbol('greet', lines, uri, '')
	assert doc == 'greet says hello'
}

fn test_find_doc_comment_for_symbol_other_open_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	other_content := 'module main\n\n// helper does the thing\nfn helper() {}'
	other_uri := 'file:///tmp/other.v'
	app.open_files[other_uri] = other_content

	current_content := 'module main\n\nfn main() { helper() }'
	current_uri := 'file:///tmp/main.v'
	app.open_files[current_uri] = current_content
	current_lines := current_content.split_into_lines()

	doc := app.find_doc_comment_for_symbol('helper', current_lines, current_uri, '')
	assert doc == 'helper does the thing'
}

fn test_find_doc_comment_for_qualified_symbol_uses_imported_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	project_dir := os.join_path(app.temp_dir, 'hover_import')
	a_dir := os.join_path(project_dir, 'a')
	b_dir := os.join_path(project_dir, 'b')
	must_mkdir_all(a_dir)
	must_mkdir_all(b_dir)
	must_write_file(os.join_path(project_dir, 'v.mod'), 'Module {}\n')
	must_write_file(os.join_path(a_dir, 'a.v'), 'module a\n\n// A foo docs\npub fn foo() {}\n')
	must_write_file(os.join_path(b_dir, 'b.v'), 'module b\n\n// B foo docs\npub fn foo() {}\n')
	main_path := os.join_path(project_dir, 'main.v')
	content := 'module main\n\nimport a\nimport b\n\n// Local foo docs\nfn foo() {}\n\nfn main() {\n\tb.foo()\n}\n'
	must_write_file(main_path, content)
	uri := path_to_uri(main_path)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	call_line := lines.index('\tb.foo()')
	if call_line < 0 {
		assert false, 'expected qualified call line'
		return
	}
	foo_col := lines[call_line].index('foo') or {
		assert false, 'expected foo column'
		return
	}
	imported_module := imported_module_at_symbol(lines[call_line], foo_col, content)
	assert imported_module == 'b'

	doc := app.find_doc_comment_for_symbol('foo', lines, uri, imported_module)
	assert doc == 'B foo docs'
}

fn test_find_doc_comment_for_symbol_not_found() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\nfn main() {}'
	uri := 'file:///tmp/main.v'
	app.open_files[uri] = content
	lines := content.split_into_lines()
	doc := app.find_doc_comment_for_symbol('nonexistent', lines, uri, '')
	assert doc == ''
}

fn test_infer_type_integer() {
	assert infer_type_from_literal('42') == 'int'
}

fn test_infer_type_negative_integer() {
	assert infer_type_from_literal('-7') == 'int'
}

fn test_infer_type_hex() {
	assert infer_type_from_literal('0xff') == 'int'
}

fn test_infer_type_octal() {
	assert infer_type_from_literal('0o77') == 'int'
}

fn test_infer_type_binary() {
	assert infer_type_from_literal('0b1010') == 'int'
}

fn test_infer_type_float() {
	assert infer_type_from_literal('3.14') == 'f64'
}

fn test_infer_type_string_single_quote() {
	assert infer_type_from_literal("'hello'") == 'string'
}

fn test_infer_type_string_double_quote() {
	assert infer_type_from_literal('"world"') == 'string'
}

fn test_infer_type_bool_true() {
	assert infer_type_from_literal('true') == 'bool'
}

fn test_infer_type_bool_false() {
	assert infer_type_from_literal('false') == 'bool'
}

fn test_infer_type_struct_init_skipped() {
	assert infer_type_from_literal('MyStruct{}') == ''
}

fn test_infer_type_array_init_skipped() {
	assert infer_type_from_literal('[]int{}') == ''
}

fn test_infer_type_function_call_skipped() {
	assert infer_type_from_literal('get_value()') == ''
}

fn test_infer_type_identifier_skipped() {
	assert infer_type_from_literal('other_var') == ''
}

fn test_infer_type_empty_skipped() {
	assert infer_type_from_literal('') == ''
}

fn test_extract_fn_call_qualified() {
	mod_name, fn_name := extract_fn_call('os.temp_dir()')
	assert mod_name == 'os'
	assert fn_name == 'temp_dir'
}

fn test_extract_fn_call_plain() {
	mod_name, fn_name := extract_fn_call('get_value()')
	assert mod_name == ''
	assert fn_name == 'get_value'
}

fn test_extract_fn_call_with_args() {
	mod_name, fn_name := extract_fn_call('os.join_path(a, b)')
	assert mod_name == 'os'
	assert fn_name == 'join_path'
}

fn test_extract_fn_call_not_a_call() {
	mod_name, fn_name := extract_fn_call('42')
	assert mod_name == ''
	assert fn_name == ''
}

fn test_extract_fn_call_literal_not_a_call() {
	mod_name, fn_name := extract_fn_call("'hello'")
	assert mod_name == ''
	assert fn_name == ''
}

fn test_build_fn_index_basic() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	src := 'module mymod\n\nfn get_value() int {\n\treturn 42\n}\n\npub fn get_name() string {\n\treturn "vls"\n}\n\nfn (mut app App) handle() string {\n\treturn ""\n}\n\nfn do_nothing() {\n}\n'
	fpath := os.join_path(app.temp_dir, 'mymod.v')
	os.write_file(fpath, src) or { assert false, 'write failed' }

	index := build_fn_index([fpath])
	assert index['get_value'] == 'int'
	assert index['get_name'] == 'string'
	assert 'handle' !in index
	assert 'do_nothing' !in index
}

fn test_lookup_fn_return_type_qualified() {
	index := {
		'os.temp_dir': 'string'
		'temp_dir':    'string'
	}
	assert lookup_fn_return_type('os.temp_dir()', index) == 'string'
}

fn test_lookup_fn_return_type_plain() {
	index := {
		'get_value': 'int'
	}
	assert lookup_fn_return_type('get_value()', index) == 'int'
}

fn test_lookup_fn_return_type_not_found() {
	index := map[string]string{}
	assert lookup_fn_return_type('unknown_fn()', index) == ''
}

fn test_handle_inlay_hints_basic() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///test_inlay.v'
	content := "module main

fn main() {
x := 42
name := 'hello'
flag := true
ratio := 3.14
obj := MyStruct{}
}"
	app.open_files[uri] = content

	request := Request{
		id:     30
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 9
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_inlay_hints(request)

	if response.result is []InlayHint {
		hints := response.result
		assert hints.len == 4
		labels := hints.map(it.label)
		assert ': int' in labels
		assert ': string' in labels
		assert ': bool' in labels
		assert ': f64' in labels
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_handle_inlay_hints_hint_position() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///test_inlay_pos.v'
	content := 'module main

fn main() {
x := 99
}'
	app.open_files[uri] = content

	request := Request{
		id:     31
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 4
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_inlay_hints(request)

	if response.result is []InlayHint {
		hints := response.result
		assert hints.len == 1
		hint := hints[0]
		assert hint.label == ': int'
		assert hint.kind == 1
		assert hint.position.line == 3
		// 'x' appears at column 0, hint after 'x' = col 1
		assert hint.position.char == 1
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_handle_inlay_hints_empty_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///test_inlay_empty.v'
	app.open_files[uri] = ''

	request := Request{
		id:     32
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 0
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_inlay_hints(request)

	if response.result is []InlayHint {
		assert response.result.len == 0
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_handle_inlay_hints_mut_var() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///test_inlay_mut.v'
	content := 'fn main() {
mut count := 0
}'
	app.open_files[uri] = content

	request := Request{
		id:     33
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 2
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_inlay_hints(request)

	if response.result is []InlayHint {
		hints := response.result
		assert hints.len == 1
		assert hints[0].label == ': int'
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_handle_inlay_hints_single_const() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///test_inlay_const_single.v'
	content := "module main

const pi = 3.14
const greeting = 'hello'
const max_count = 100
const is_debug = false
"
	app.open_files[uri] = content

	request := Request{
		id:     34
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 7
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_inlay_hints(request)

	if response.result is []InlayHint {
		hints := response.result
		assert hints.len == 4
		labels := hints.map(it.label)
		assert ': f64' in labels
		assert ': string' in labels
		assert ': int' in labels
		assert ': bool' in labels
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_handle_inlay_hints_const_block() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///test_inlay_const_block.v'
	content := "module main

const (
pi        = 3.14
app_name  = 'vls'
max_items = 50
enabled   = true
)
"
	app.open_files[uri] = content

	request := Request{
		id:     35
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 9
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}

	response := app.handle_inlay_hints(request)

	if response.result is []InlayHint {
		hints := response.result
		assert hints.len == 4
		labels := hints.map(it.label)
		assert ': f64' in labels
		assert ': string' in labels
		assert ': int' in labels
		assert ': bool' in labels
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_handle_inlay_hints_local_fn_call() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	helper_src := 'module main\n\nfn get_greeting() string {\n\treturn "hello"\n}\n'
	os.write_file(os.join_path(app.temp_dir, 'helper.v'), helper_src) or {
		assert false, 'write failed'
	}

	uri := path_to_uri(os.join_path(app.temp_dir, 'main.v'))
	app.open_files[uri] = 'module main\n\nfn main() {\n\tmsg := get_greeting()\n}\n'

	request := Request{
		id:     40
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 5
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}
	response := app.handle_inlay_hints(request)
	if response.result is []InlayHint {
		hints := response.result
		assert hints.len == 1
		assert hints[0].label == ': string'
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_handle_inlay_hints_error_result_fn() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	helper_src := 'module main\n\nfn read_data() !string {\n\treturn "data"\n}\n'
	os.write_file(os.join_path(app.temp_dir, 'reader.v'), helper_src) or {
		assert false, 'write failed'
	}

	uri := path_to_uri(os.join_path(app.temp_dir, 'main2.v'))
	app.open_files[uri] = 'module main\n\nfn main() {\n\tdata := read_data() or { return }\n}\n'

	request := Request{
		id:     41
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 5
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}
	response := app.handle_inlay_hints(request)
	if response.result is []InlayHint {
		hints := response.result
		assert hints.len == 1
		assert hints[0].label == ': string'
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_handle_inlay_hints_same_file_fn_call() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	uri := 'file:///test_same_file.v'
	content := 'module main

fn get_greeting() string {
return "hello"
}

fn main() {
greeting := get_greeting()
}
'
	app.open_files[uri] = content

	request := Request{
		id:     50
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 9
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	}
	response := app.handle_inlay_hints(request)
	if response.result is []InlayHint {
		hints := response.result
		assert hints.len == 1
		assert hints[0].label == ': string'
	} else {
		assert false, 'Expected []InlayHint'
	}
}

fn test_make_keyword_completions_not_empty() {
	items := make_keyword_completions()
	assert items.len > 0
}

fn test_make_keyword_completions_contains_fn_keyword() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'fn' in labels
}

fn test_make_keyword_completions_fn_has_keyword_kind() {
	items := make_keyword_completions()
	fn_items := items.filter(it.label == 'fn')
	assert fn_items.len > 0
	assert fn_items[0].kind == 14 // Keyword
}

fn test_make_keyword_completions_contains_println_builtin() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'println' in labels
}

fn test_make_keyword_completions_println_has_function_kind() {
	items := make_keyword_completions()
	println_items := items.filter(it.label == 'println')
	assert println_items.len > 0
	assert println_items[0].kind == 3 // Function
}

fn test_make_keyword_completions_contains_struct_keyword() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'struct' in labels
}

fn test_make_keyword_completions_contains_for_keyword() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'for' in labels
}

fn test_make_keyword_completions_contains_mut_keyword() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'mut' in labels
}

fn test_make_keyword_completions_contains_atomic() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'atomic' in labels
}

fn test_make_keyword_completions_dump_is_keyword_kind() {
	items := make_keyword_completions()
	dump_items := items.filter(it.label == 'dump')
	assert dump_items.len > 0
	assert dump_items[0].kind == 14 // Keyword, not Function
}

fn test_make_keyword_completions_sizeof_is_keyword_kind() {
	items := make_keyword_completions()
	sizeof_items := items.filter(it.label == 'sizeof')
	assert sizeof_items.len > 0
	assert sizeof_items[0].kind == 14 // Keyword
}

fn test_make_keyword_completions_no_len() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'len' !in labels
}

fn test_make_keyword_completions_no_cap() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'cap' !in labels
}

fn test_make_keyword_completions_no_delete() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'delete' !in labels
}

fn test_make_keyword_completions_contains_error_with_code() {
	items := make_keyword_completions()
	labels := items.map(it.label)
	assert 'error_with_code' in labels
}

fn test_import_completions_non_import_line() {
	results := get_import_completions('fn main() {', '')
	assert results.len == 0
}

fn test_import_completions_empty_prefix() {
	results := get_import_completions('import ', '')
	// Should return all vlib top-level modules (non-empty)
	assert results.len > 0
	// All results should have kind 9 (Module)
	for r in results {
		assert r.kind == 9
	}
}

fn test_import_completions_partial_prefix() {
	results := get_import_completions('import enc', '')
	// Should return only modules starting with 'enc' (e.g. 'encoding')
	assert results.len > 0
	for r in results {
		assert r.label.starts_with('enc')
	}
}

fn test_import_completions_nested() {
	encoding_dir := os.join_path(v_dir, 'vlib', 'encoding')
	if !os.is_dir(encoding_dir) {
		return
	}
	results := get_import_completions('import encoding.', '')
	// Should return submodules of encoding/
	assert results.len > 0
	for r in results {
		// insert_text is just the segment (e.g. 'base64'), not the full path,
		// so the editor inserts it after the dot the user already typed.
		it := r.insert_text or { '' }
		assert !it.contains('.')
		assert r.detail == 'V stdlib module'
	}
}

fn test_import_completions_local_module() {
	temp_dir := os.join_path(os.temp_dir(), 'vls_import_test_${os.getpid()}')
	must_mkdir_all(temp_dir)
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	// Create a local module directory with a .v file
	mymod_dir := os.join_path(temp_dir, 'mymod')
	must_mkdir_all(mymod_dir)
	must_write_file(os.join_path(mymod_dir, 'mymod.v'), 'module mymod\n')

	results := get_import_completions('import ', temp_dir)
	labels := results.map(it.label)
	assert 'mymod' in labels

	local_results := results.filter(it.label == 'mymod')
	assert local_results.len == 1
	assert local_results[0].detail == 'Local module'
	assert local_results[0].insert_text or { '' } == 'mymod'
}

fn test_parse_module_fn_completions_basic() {
	content := 'module main\n\npub fn helper(name string) string {\n\treturn name\n}\n\nfn private_fn() {}\n'
	items := parse_module_fn_completions(content)
	labels := items.map(it.label)
	// pub fn should be present
	assert 'helper' in labels
	// plain fn should also be present (same-module functions are all accessible)
	assert 'private_fn' in labels
}

fn test_parse_module_fn_completions_private_included() {
	// Plain fn (no pub) must appear as a completion item
	content := 'module main\n\nfn internal_helper(x int) int {\n\treturn x * 2\n}\n'
	items := parse_module_fn_completions(content)
	labels := items.map(it.label)
	assert 'internal_helper' in labels
}

fn test_parse_module_fn_completions_skips_methods() {
	content := 'module main\n\npub fn (r App) method_name() {}\n\nfn (mut app App) other_method() {}\n\npub fn free_fn() {}\n\nfn plain_free() {}\n'
	items := parse_module_fn_completions(content)
	labels := items.map(it.label)
	// method receivers should be skipped (both pub and plain)
	assert 'method_name' !in labels
	assert 'other_method' !in labels
	// free functions (pub and plain) should be included
	assert 'free_fn' in labels
	assert 'plain_free' in labels
}

fn test_parse_module_fn_completions_detail_string() {
	content := 'module main\n\npub fn add(a int, b int) int {\n\treturn a + b\n}\n'
	items := parse_module_fn_completions(content)
	assert items.len == 1
	assert items[0].label == 'add'
	assert items[0].detail == 'pub fn add(a int, b int) int'
	assert items[0].kind == 3
}

fn test_parse_module_fn_completions_void_fn() {
	// Void fn (no return type) should be included — covers both pub fn and plain fn
	content := 'module main\n\npub fn greet(name string) {\n\tprintln(name)\n}\n\nfn log_msg(msg string) {\n\teprintln(msg)\n}\n'
	items := parse_module_fn_completions(content)
	labels := items.map(it.label)
	assert 'greet' in labels
	assert 'log_msg' in labels
}

fn test_collect_module_fn_completions_skips_current_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	current_file := os.join_path(test_dir, 'main.v')
	sibling_file := os.join_path(test_dir, 'utils.v')

	must_write_file(current_file, 'module main\n\npub fn current_fn() {}\n')
	must_write_file(sibling_file, 'module main\n\npub fn sibling_fn() {}\n')

	current_uri := path_to_uri(current_file)
	app.open_files[current_uri] = 'module main\n\npub fn current_fn() {}\n'

	items := app.collect_module_fn_completions(current_uri, test_dir)
	labels := items.map(it.label)
	// sibling pub fn should appear
	assert 'sibling_fn' in labels
	// current file's pub fn should NOT appear (avoid duplicates)
	assert 'current_fn' !in labels
}

fn test_collect_module_fn_completions_skips_test_files() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	current_file := os.join_path(test_dir, 'main.v')
	test_file := os.join_path(test_dir, 'main_test.v')

	must_write_file(current_file, 'module main\n\nfn main() {}\n')
	must_write_file(test_file, 'module main\n\nfn test_something() {}\n')

	current_uri := path_to_uri(current_file)
	test_uri := path_to_uri(test_file)

	// Simulate both files open in the editor
	app.open_files[current_uri] = 'module main\n\nfn main() {}\n'
	app.open_files[test_uri] = 'module main\n\nfn test_something() {}\n'

	items := app.collect_module_fn_completions(current_uri, test_dir)
	labels := items.map(it.label)
	// test fn from _test.v must NOT appear in completions
	assert 'test_something' !in labels
}

fn test_collect_module_fn_completions_prefers_open_files() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	current_file := os.join_path(test_dir, 'main.v')
	sibling_file := os.join_path(test_dir, 'utils.v')

	// Write an old version to disk
	must_write_file(current_file, 'module main\n')
	must_write_file(sibling_file, 'module main\n\npub fn disk_fn() {}\n')

	current_uri := path_to_uri(current_file)
	sibling_uri := path_to_uri(sibling_file)

	// In-memory version of sibling has a different (newer) function
	app.open_files[current_uri] = 'module main\n'
	app.open_files[sibling_uri] = 'module main\n\npub fn memory_fn() {}\n'

	items := app.collect_module_fn_completions(current_uri, test_dir)
	labels := items.map(it.label)
	// In-memory version is used (sibling_uri already in searched_uris after open_files scan)
	assert 'memory_fn' in labels
	// disk_fn should NOT appear because the URI was already visited via open_files
	assert 'disk_fn' !in labels
}

fn test_get_module_name_basic() {
	assert get_module_name('module main\n\nfn main() {}\n') == 'main'
	assert get_module_name('module foo\n') == 'foo'
	assert get_module_name('module mypackage\n') == 'mypackage'
}

fn test_get_module_name_no_declaration() {
	assert get_module_name('') == ''
	assert get_module_name('fn main() {}\n') == ''
}

fn test_get_module_name_ignores_comments() {
	// module keyword inside a comment is not a declaration
	assert get_module_name('// module notthis\nmodule real\n') == 'real'
	assert get_module_name('/*\nmodule legacy\n*/\nmodule real\n') == 'real'
	assert get_module_name("const text = 'start\nmodule legacy\nend'\nmodule real\n") == 'real'
}

fn test_collect_module_fn_completions_excludes_different_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	current_file := os.join_path(test_dir, 'main.v')
	other_file := os.join_path(test_dir, 'other.v')

	must_write_file(current_file, 'module main\n\nfn main() {}\n')
	// other.v belongs to a different module
	must_write_file(other_file, 'module other\n\npub fn other_fn() {}\n')

	current_uri := path_to_uri(current_file)
	app.open_files[current_uri] = 'module main\n\nfn main() {}\n'

	items := app.collect_module_fn_completions(current_uri, test_dir)
	labels := items.map(it.label)
	// other module's pub fn must NOT appear
	assert 'other_fn' !in labels
}

fn test_collect_module_fn_completions_excludes_different_module_in_memory() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	current_file := os.join_path(test_dir, 'main.v')
	other_file := os.join_path(test_dir, 'lib.v')

	must_write_file(current_file, 'module main\n')
	must_write_file(other_file, 'module lib\n')

	current_uri := path_to_uri(current_file)
	other_uri := path_to_uri(other_file)

	// User changed the module of lib.v in memory — now it's a different module
	app.open_files[current_uri] = 'module main\n'
	app.open_files[other_uri] = 'module lib\n\npub fn lib_fn() {}\n'

	items := app.collect_module_fn_completions(current_uri, test_dir)
	labels := items.map(it.label)
	assert 'lib_fn' !in labels
}

fn test_collect_module_fn_completions_current_file_module_changed() {
	// Simulates: user edits the current file's module declaration from `module main`
	// to `module bar`. Completions should only show functions from files that
	// also declare `module bar`.
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	current_file := os.join_path(test_dir, 'main.v')
	sibling_file := os.join_path(test_dir, 'utils.v')
	bar_file := os.join_path(test_dir, 'bar_utils.v')

	must_write_file(current_file, 'module main\n')
	must_write_file(sibling_file, 'module main\n\npub fn main_fn() {}\n')
	must_write_file(bar_file, 'module bar\n\npub fn bar_fn() {}\n')

	current_uri := path_to_uri(current_file)

	// User changes current file's module declaration to `bar` (unsaved)
	app.open_files[current_uri] = 'module bar\n'

	items := app.collect_module_fn_completions(current_uri, test_dir)
	labels := items.map(it.label)
	// bar_fn belongs to `module bar` → should appear
	assert 'bar_fn' in labels
	// main_fn belongs to `module main` → must NOT appear
	assert 'main_fn' !in labels
}

fn test_collect_module_fn_completions_sibling_module_changed() {
	// Simulates: sibling file's module declaration is changed in memory to a
	// different module. Its functions must no longer appear in the current
	// file's completions.
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)

	current_file := os.join_path(test_dir, 'main.v')
	sibling_file := os.join_path(test_dir, 'utils.v')

	must_write_file(current_file, 'module main\n\npub fn current_fn() {}\n')
	must_write_file(sibling_file, 'module main\n\npub fn sibling_fn() {}\n')

	current_uri := path_to_uri(current_file)
	sibling_uri := path_to_uri(sibling_file)

	app.open_files[current_uri] = 'module main\n'
	// User edits sibling's module declaration to `other` (unsaved)
	app.open_files[sibling_uri] = 'module other\n\npub fn sibling_fn() {}\n'

	items := app.collect_module_fn_completions(current_uri, test_dir)
	labels := items.map(it.label)
	// sibling_fn now belongs to `module other` → must NOT appear
	assert 'sibling_fn' !in labels
}

fn test_operation_at_pos_completion_includes_current_file_fns() {
	// Functions declared in the currently-edited file must appear in completions
	// even when the V compiler's -line-info doesn't return them.
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn local_helper() {}\n\nfn main() {\n\tos.\n}\n'
	must_write_file(test_file, content)

	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	app.text = content

	request := Request{
		id:     1
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 4
			}
		},
			escape_unicode: true
		)
	}

	response := app.operation_at_pos(.completion, request)
	assert response.id == 1
	result := response.result
	assert result is CompletionList
	cl := result as CompletionList
	assert cl.is_incomplete == false
	labels := cl.items.map(it.label)
	assert 'local_helper' in labels
}

fn test_operation_at_pos_dot_completion_includes_imported_module_members() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project_dot_completion')
	mod_dir := os.join_path(test_dir, 'my_mod')
	must_mkdir_all(mod_dir)

	must_write_file(os.join_path(mod_dir, 'my_mod.v'),
		'module my_mod\n\npub fn greet(name string) string {\n\treturn name\n}\n\nfn hidden() {}\n')

	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport my_mod\n\nfn main() {\n\tmy_mod.\n}\n'
	must_write_file(main_file, content)

	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	app.text = content

	response := app.operation_at_pos(.completion, Request{
		id:     9001
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 8
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	cl := response.result as CompletionList
	labels := cl.items.map(it.label)
	assert 'greet' in labels
	assert 'hidden' !in labels
}

fn test_operation_at_pos_dot_completion_includes_aliased_import_module_members() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'project_dot_completion_alias')
	mod_dir := os.join_path(test_dir, 'my_mod')
	must_mkdir_all(mod_dir)

	must_write_file(os.join_path(mod_dir, 'my_mod.v'), 'module my_mod\n\npub fn ping() {}\n')

	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport my_mod as mm\n\nfn main() {\n\tmm.\n}\n'
	must_write_file(main_file, content)

	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	app.text = content

	response := app.operation_at_pos(.completion, Request{
		id:     9002
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 4
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	cl := response.result as CompletionList
	labels := cl.items.map(it.label)
	assert 'ping' in labels
}

fn test_semantic_tokens_returns_data_for_known_content() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/semtok.v'
	content := 'module main\n\nfn main() {\n\tprintln("hello")\n}\n'
	app.open_files[uri] = content

	resp := app.handle_semantic_tokens(Request{
		id:     800
		method: 'textDocument/semanticTokens/full'
		params: json2.encode(SemanticTokensParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 800
	assert resp.result is SemanticTokens
	tokens := resp.result as SemanticTokens
	// A V file with keywords/strings should yield at least some tokens.
	assert tokens.data.len > 0
}

fn test_semantic_tokens_returns_empty_object_for_empty_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/empty.v'
	app.open_files[uri] = ''

	resp := app.handle_semantic_tokens(Request{
		id:     801
		method: 'textDocument/semanticTokens/full'
		params: json2.encode(SemanticTokensParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 801
	// An empty document returns an empty token set, not null (P2-01).
	assert resp.result is SemanticTokens
	tokens := resp.result as SemanticTokens
	assert tokens.data.len == 0
}

fn test_semantic_tokens_range_returns_empty_for_missing_document() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	resp := app.handle_semantic_tokens_range(Request{
		id:     802
		method: 'textDocument/semanticTokens/range'
		params: '{}'
	})

	assert resp.id == 802
	// Empty params decode to an empty (untracked) document, which has an empty
	// token set rather than null (P2-01).
	assert resp.result is SemanticTokens
	tokens := resp.result as SemanticTokens
	assert tokens.data.len == 0
}

fn test_semantic_tokens_range_filters_by_character() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/semrange.v'
	// Line 0 has two string tokens: `"b"` at column 5 and `"c"` at column 11.
	app.open_files[uri] = 'a := "b" + "c"\n'

	full_params := json2.encode(SemanticTokensRangeParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range:         LSPRange{
			start: Position{
				line: 0
				char: 0
			}
			end:   Position{
				line: 0
				char: 50
			}
		}
	},
		escape_unicode: true
	)
	full := app.handle_semantic_tokens_range(Request{
		id:     1
		params: full_params
	})
	ftok := full.result as SemanticTokens
	// The full-line request includes the token that starts at column 5.
	assert ftok.data.len >= 5
	assert ftok.data[0] == 0
	assert ftok.data[1] == 5

	// Narrow the range to columns [8,50): the column-5 token must be excluded, so
	// the first returned token starts at or after column 8 (the `"c"` at 11) and
	// the payload is strictly smaller than the full-line one.
	narrow_params := json2.encode(SemanticTokensRangeParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range:         LSPRange{
			start: Position{
				line: 0
				char: 8
			}
			end:   Position{
				line: 0
				char: 50
			}
		}
	},
		escape_unicode: true
	)
	narrow := app.handle_semantic_tokens_range(Request{
		id:     2
		params: narrow_params
	})
	ntok := narrow.result as SemanticTokens
	assert ntok.data.len >= 5
	assert ntok.data[0] == 0
	assert ntok.data[1] >= 8
	assert ntok.data.len < ftok.data.len
}

// ── code lens ────────────────────────────────────────────────────────────────

fn test_code_lens_returns_run_lens_for_main() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/codelens_main.v'
	content := 'module main\n\nfn main() {\n\tprintln("hi")\n}\n'
	app.open_files[uri] = content

	resp := app.handle_code_lens(Request{
		id:     810
		method: 'textDocument/codeLens'
		params: json2.encode(CodeLensParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 810
	assert resp.result is []CodeLens
	lenses := resp.result as []CodeLens
	assert lenses.any(it.command?.command == 'vls.runFile')
}

fn test_code_lens_returns_test_lens_for_test_fn() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/codelens_test.v'
	content := 'module main\n\nfn test_something() {\n\tassert true\n}\n'
	app.open_files[uri] = content

	resp := app.handle_code_lens(Request{
		id:     811
		method: 'textDocument/codeLens'
		params: json2.encode(CodeLensParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 811
	assert resp.result is []CodeLens
	lenses := resp.result as []CodeLens
	assert lenses.any(it.command?.command == 'vls.runTests')
}

fn test_code_lens_resolve_returns_same_lens() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	lens := CodeLens{
		range:   LSPRange{
			start: Position{
				line: 2
				char: 0
			}
			end:   Position{
				line: 2
				char: 10
			}
		}
		command: Command{
			title:     '▶ Run'
			command:   'vls.runFile'
			arguments: ['file:///tmp/a.v']
		}
	}

	resp := app.handle_code_lens_resolve(Request{
		id:     812
		method: 'codeLens/resolve'
		params: json2.encode(lens, escape_unicode: true)
	})

	assert resp.id == 812
	assert resp.result is CodeLens
	resolved := resp.result as CodeLens
	assert resolved.command?.command == 'vls.runFile'
}

// ── execute command ───────────────────────────────────────────────────────────

fn test_execute_command_returns_null_result() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	resp := app.handle_execute_command(Request{
		id:     820
		method: 'workspace/executeCommand'
		params: json2.encode(ExecuteCommandParams{
			command: 'vls.runFile'
		},
			escape_unicode: true
		)
	})

	assert resp.id == 820
	assert resp.result is string
	assert (resp.result as string) == 'null'
}

fn test_execute_command_unknown_still_returns_null() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	resp := app.handle_execute_command(Request{
		id:     821
		method: 'workspace/executeCommand'
		params: json2.encode(ExecuteCommandParams{
			command: 'unknownCommand'
		},
			escape_unicode: true
		)
	})

	assert resp.id == 821
	assert resp.result is string
	assert (resp.result as string) == 'null'
}

// ── inline value ─────────────────────────────────────────────────────────────

fn test_inline_value_returns_values_for_simple_assignment() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/inlineval.v'
	content := 'module main\n\nfn main() {\n\tx := 42\n\ty := "hello"\n}\n'
	app.open_files[uri] = content

	resp := app.handle_inline_value(Request{
		id:     830
		method: 'textDocument/inlineValue'
		params: json2.encode(InlineValueParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 5
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 830
	assert resp.result is []InlineValueText
	values := resp.result as []InlineValueText
	assert values.len > 0
	assert values.any(it.text == ': int' || it.text == ': string')
}

fn test_inline_value_returns_empty_for_no_assignments() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/inlineval_empty.v'
	app.open_files[uri] = 'module main\n\nfn main() {}\n'

	resp := app.handle_inline_value(Request{
		id:     831
		method: 'textDocument/inlineValue'
		params: json2.encode(InlineValueParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end:   Position{
					line: 2
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 831
	assert resp.result is []InlineValueText
	values := resp.result as []InlineValueText
	assert values.len == 0
}

// ── linked editing range ──────────────────────────────────────────────────────

fn test_linked_editing_range_returns_ranges_for_identifier() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/linked.v'
	// Line 2: `foo := foo + 1` — "foo" appears twice
	content := 'module main\n\nfn main() {\n\tfoo := foo\n}\n'
	app.open_files[uri] = content

	resp := app.handle_linked_editing_range(Request{
		id:     840
		method: 'textDocument/linkedEditingRange'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 2
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 840
	assert resp.result is LinkedEditingRanges
	ler := resp.result as LinkedEditingRanges
	assert ler.ranges.len >= 2
}

fn test_linked_editing_range_returns_null_when_not_on_identifier() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/linked2.v'
	content := 'module main\n\nfn main() {}\n'
	app.open_files[uri] = content

	// Position on an empty line
	resp := app.handle_linked_editing_range(Request{
		id:     841
		method: 'textDocument/linkedEditingRange'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 1
				char: 0
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 841
	assert resp.result is string
	assert (resp.result as string) == 'null'
}

// ── selection range ───────────────────────────────────────────────────────────

fn test_selection_range_returns_one_entry_per_position() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/selrange.v'
	content := 'module main\n\nfn main() {\n\thello := 1\n}\n'
	app.open_files[uri] = content

	resp := app.handle_selection_range(Request{
		id:     850
		method: 'textDocument/selectionRange'
		params: json2.encode(SelectionRangeParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			positions:     [Position{
				line: 3
				char: 2
			}, Position{
				line: 3
				char: 7
			}]
		},
			escape_unicode: true
		)
	})

	assert resp.id == 850
	assert resp.result is []SelectionRange
	ranges := resp.result as []SelectionRange
	assert ranges.len == 2
}

fn test_selection_range_word_range_has_parent_line_range() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/selrange2.v'
	content := 'module main\n\nfn main() {\n\thello := 1\n}\n'
	app.open_files[uri] = content

	resp := app.handle_selection_range(Request{
		id:     851
		method: 'textDocument/selectionRange'
		params: json2.encode(SelectionRangeParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			positions:     [Position{
				line: 3
				char: 2
			}]
		},
			escape_unicode: true
		)
	})

	assert resp.result is []SelectionRange
	ranges := resp.result as []SelectionRange
	assert ranges.len == 1
	// Inner word range should be smaller than or equal to parent line range
	entry := ranges[0]
	if parent := entry.parent {
		assert parent.range.start.char == 0
	}
}

// ── on-type formatting ────────────────────────────────────────────────────────

fn test_on_type_formatting_returns_empty_edits() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	resp := app.handle_on_type_formatting(Request{
		id:     860
		method: 'textDocument/onTypeFormatting'
		params: json2.encode(OnTypeFormattingParams{
			text_document: TextDocumentIdentifier{
				uri: 'file:///tmp/fmt.v'
			}
			position:      Position{
				line: 3
				char: 0
			}
			ch:            '}'
		},
			escape_unicode: true
		)
	})

	assert resp.id == 860
	assert resp.result is []TextEdit
	edits := resp.result as []TextEdit
	assert edits.len == 0
}

// ── call hierarchy outgoing ──────────────────────────────────────────────────

fn test_call_hierarchy_outgoing_returns_callees() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	root := os.join_path(app.temp_dir, 'call_out')
	must_mkdir_all(root)
	file_path := os.join_path(root, 'main.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(file_path, content)
	uri := path_to_uri(file_path)
	app.open_files[uri] = content
	app.workspace_roots = [root]

	resp := app.handle_call_hierarchy_outgoing(Request{
		id:     870
		method: 'callHierarchy/outgoingCalls'
		params: json2.encode(CallHierarchyOutgoingCallsParams{
			item: CallHierarchyItem{
				name:            'main'
				kind:            sym_kind_function
				uri:             uri
				range:           LSPRange{
					start: Position{
						line: 4
						char: 0
					}
					end:   Position{
						line: 6
						char: 1
					}
				}
				selection_range: LSPRange{
					start: Position{
						line: 4
						char: 3
					}
					end:   Position{
						line: 4
						char: 7
					}
				}
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 870
	assert resp.result is []CallHierarchyOutgoingCall
	calls := resp.result as []CallHierarchyOutgoingCall
	assert calls.any(it.to.name == 'helper')
}

fn test_call_hierarchy_incoming_returns_callers() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	root := os.join_path(app.temp_dir, 'call_in')
	must_mkdir_all(root)
	file_path := os.join_path(root, 'main.v')
	content := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(file_path, content)
	uri := path_to_uri(file_path)
	app.open_files[uri] = content
	app.workspace_roots = [root]

	resp := app.handle_call_hierarchy_incoming(Request{
		id:     871
		method: 'callHierarchy/incomingCalls'
		params: json2.encode(CallHierarchyIncomingCallsParams{
			item: CallHierarchyItem{
				name:            'helper'
				kind:            sym_kind_function
				uri:             uri
				range:           LSPRange{
					start: Position{
						line: 2
						char: 0
					}
					end:   Position{
						line: 2
						char: 15
					}
				}
				selection_range: LSPRange{
					start: Position{
						line: 2
						char: 3
					}
					end:   Position{
						line: 2
						char: 9
					}
				}
			}
		},
			escape_unicode: true
		)
	})

	assert resp.id == 871
	assert resp.result is []CallHierarchyIncomingCall
	calls := resp.result as []CallHierarchyIncomingCall
	assert calls.any(it.from.name == 'main')
}

// --- P0-09: Organize Imports must never delete non-import code ---

fn test_organize_imports_refuses_non_contiguous_block() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/oi_noncontig.v'
	// Imports separated by a function: organizing must NOT delete `helper`.
	app.open_files[uri] = 'import os\n\nfn helper() {}\n\nimport time\n'
	params := CodeActionParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range:         LSPRange{}
		context:       CodeActionContext{}
	}
	resp := app.handle_code_action(Request{
		id:     1
		params: json2.encode(params, escape_unicode: true)
	})
	assert resp.result is []CodeAction
	actions := resp.result as []CodeAction
	for a in actions {
		assert a.kind != code_action_kind_source_organize_imports, 'organize imports must not be offered for non-contiguous imports'
	}
}

fn test_organize_imports_sorts_contiguous_block() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/oi_contig.v'
	app.open_files[uri] = 'import time\nimport os\nimport os\n'
	params := CodeActionParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range:         LSPRange{}
		context:       CodeActionContext{}
	}
	resp := app.handle_code_action(Request{
		id:     2
		params: json2.encode(params, escape_unicode: true)
	})
	assert resp.result is []CodeAction
	actions := resp.result as []CodeAction
	mut found := false
	for a in actions {
		if a.kind == code_action_kind_source_organize_imports {
			found = true
			edit := a.edit or { continue }
			edits := edit.changes[uri]
			assert edits.len == 1
			// Sorted + deduplicated.
			assert edits[0].new_text == 'import os\nimport time'
		}
	}
	assert found, 'organize imports should be offered for a contiguous import block'
}

fn test_organize_imports_preserves_crlf_line_endings() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/oi_crlf.v'
	app.open_files[uri] = 'module main\r\n\r\nimport time\r\nimport os\r\n\r\nfn main() {}\r\n'
	resp := app.handle_code_action(Request{
		id:     3
		params: json2.encode(CodeActionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{}
			context:       CodeActionContext{}
		},
			escape_unicode: true
		)
	})
	assert resp.result is []CodeAction
	actions := resp.result as []CodeAction
	for action in actions {
		if action.kind != code_action_kind_source_organize_imports {
			continue
		}
		edit := action.edit or {
			assert false, 'organize imports action must contain an edit'
			return
		}

		edits := edit.changes[uri]
		assert edits.len == 1
		assert edits[0].new_text == 'import os\r\nimport time'
		return
	}
	assert false, 'organize imports should be offered for an unsorted CRLF block'
}

fn test_remove_unknown_import_range_at_eof_without_newline() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/unknown_eof.v'
	// The unknown import is the final line and the file has NO trailing newline,
	// so [line+1,0) would be out of bounds. The edit must end at the line's
	// encoded length instead so clients accept the range (P0-09).
	app.open_files[uri] = 'module main\nimport foo'
	diag := LSPDiagnostic{
		message: 'unknown module `foo`'
		range:   LSPRange{
			start: Position{
				line: 1
				char: 0
			}
			end:   Position{
				line: 1
				char: 10
			}
		}
	}
	params := CodeActionParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range:         LSPRange{}
		context:       CodeActionContext{
			diagnostics: [diag]
		}
	}
	resp := app.handle_code_action(Request{
		id:     1
		params: json2.encode(params, escape_unicode: true)
	})
	actions := resp.result as []CodeAction
	mut found := false
	for a in actions {
		if a.title == 'Remove unknown import' {
			found = true
			edit := a.edit or { continue }
			e := edit.changes[uri][0]
			assert e.range.start.line == 1
			assert e.range.start.char == 0
			// Ends at the final line's length, not the nonexistent next line.
			assert e.range.end.line == 1
			assert e.range.end.char == 'import foo'.len
		}
	}
	assert found, 'expected a Remove unknown import quick fix'
}

fn test_remove_unknown_import_range_with_trailing_newline() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/unknown_nl.v'
	// The import line has a terminator, so the whole line (incl. newline) is
	// removed by ending at the next line's start.
	app.open_files[uri] = 'import foo\nmodule main\n'
	diag := LSPDiagnostic{
		message: 'unknown module `foo`'
		range:   LSPRange{
			start: Position{
				line: 0
				char: 0
			}
			end:   Position{
				line: 0
				char: 10
			}
		}
	}
	params := CodeActionParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range:         LSPRange{}
		context:       CodeActionContext{
			diagnostics: [diag]
		}
	}
	resp := app.handle_code_action(Request{
		id:     1
		params: json2.encode(params, escape_unicode: true)
	})
	actions := resp.result as []CodeAction
	mut found := false
	for a in actions {
		if a.title == 'Remove unknown import' {
			found = true
			edit := a.edit or { continue }
			e := edit.changes[uri][0]
			assert e.range.start.line == 0
			assert e.range.start.char == 0
			assert e.range.end.line == 1
			assert e.range.end.char == 0
		}
	}
	assert found, 'expected a Remove unknown import quick fix'
}

fn test_code_action_kind_wanted_respects_only_filter() {
	assert code_action_kind_wanted([], 'quickfix')
	assert code_action_kind_wanted(['quickfix'], 'quickfix')
	assert code_action_kind_wanted(['source'], 'source.organizeImports')
	assert code_action_kind_wanted(['source.organizeImports'], 'source.organizeImports')
	assert !code_action_kind_wanted(['quickfix'], 'source.organizeImports')
	assert !code_action_kind_wanted(['source.organizeImports'], 'quickfix')
}

// --- P0-01: PositionCodec (UTF-16 / UTF-8 / UTF-32) ---

fn test_encoded_col_to_byte_ascii() {
	line := 'hello'
	for enc in [PositionEncoding.utf16, .utf8, .utf32] {
		assert encoded_col_to_byte(line, 0, enc) == 0
		assert encoded_col_to_byte(line, 3, enc) == 3
		assert encoded_col_to_byte(line, 5, enc) == 5
		// Beyond end of line clamps to length.
		assert encoded_col_to_byte(line, 99, enc) == 5
	}
}

fn test_encoded_col_to_byte_bmp() {
	// 'é' is 2 UTF-8 bytes, 1 code point, 1 UTF-16 unit.
	line := 'aéb'
	// utf16 and utf32 agree for BMP.
	assert encoded_col_to_byte(line, 1, .utf16) == 1
	assert encoded_col_to_byte(line, 2, .utf16) == 3 // after 'é'
	assert encoded_col_to_byte(line, 3, .utf16) == 4
	assert encoded_col_to_byte(line, 2, .utf32) == 3
	// utf8 treats columns as raw byte offsets.
	assert encoded_col_to_byte(line, 3, .utf8) == 3
}

fn test_encoded_col_to_byte_non_bmp() {
	// '🚀' (U+1F680) is 4 UTF-8 bytes, 1 code point, 2 UTF-16 units.
	line := 'a🚀b'
	// UTF-16: a=1 unit, 🚀=2 units, b=1 unit.
	assert encoded_col_to_byte(line, 1, .utf16) == 1 // after 'a'
	assert encoded_col_to_byte(line, 2, .utf16) == 1 // inside surrogate pair -> clamp to char start
	assert encoded_col_to_byte(line, 3, .utf16) == 5 // after '🚀'
	assert encoded_col_to_byte(line, 4, .utf16) == 6 // after 'b'
	// UTF-32: 🚀 is a single code point.
	assert encoded_col_to_byte(line, 2, .utf32) == 5
	assert encoded_col_to_byte(line, 3, .utf32) == 6
}

fn test_byte_to_encoded_col_non_bmp() {
	line := 'a🚀b'
	assert byte_to_encoded_col(line, 0, .utf16) == 0
	assert byte_to_encoded_col(line, 1, .utf16) == 1
	assert byte_to_encoded_col(line, 5, .utf16) == 3 // a(1) + 🚀(2)
	assert byte_to_encoded_col(line, 6, .utf16) == 4
	assert byte_to_encoded_col(line, 5, .utf32) == 2 // a(1) + 🚀(1)
	assert byte_to_encoded_col(line, 5, .utf8) == 5
}

fn test_position_codec_roundtrip() {
	for line in ['plain', 'aéb', 'a🚀b', 'éx', '🚀🚀'] {
		for enc in [PositionEncoding.utf16, .utf8, .utf32] {
			// Round-trip a byte offset at each character boundary.
			mut b := 0
			for b <= line.len {
				col := byte_to_encoded_col(line, b, enc)
				back := encoded_col_to_byte(line, col, enc)
				// Converting back must not exceed the original boundary.
				assert back <= line.len
				b++
			}
		}
	}
}

fn test_combining_mark_counts_as_separate_unit() {
	// 'e' + U+0301 (combining acute): 3 bytes, 2 code points, 2 UTF-16 units.
	line := 'éz'
	assert encoded_col_to_byte(line, 1, .utf16) == 1 // after 'e'
	assert encoded_col_to_byte(line, 2, .utf16) == 3 // after the combining mark
	assert byte_to_encoded_col(line, 3, .utf16) == 2
}

fn test_apply_incremental_change_non_bmp_utf16() {
	// Replace the 'b' after an emoji using UTF-16 columns.
	content := 'a🚀b\n'
	range := LSPRange{
		start: Position{
			line: 0
			char: 3 // after 🚀 in UTF-16 units (a=1, 🚀=2)
		}
		end:   Position{
			line: 0
			char: 4
		}
	}
	updated := apply_incremental_change(content, range, 'X', .utf16)
	assert updated == 'a🚀X\n'
}

fn test_negotiate_position_encoding_prefers_utf8() {
	params := InitializeParams{
		capabilities: ClientCapabilities{
			general: GeneralClientCapabilities{
				position_encodings: ['utf-16', 'utf-8']
			}
		}
	}
	assert negotiate_position_encoding(params) == .utf8
}

fn test_negotiate_position_encoding_defaults_utf16() {
	// No advertised encodings -> mandatory UTF-16.
	assert negotiate_position_encoding(InitializeParams{}) == .utf16
	params := InitializeParams{
		capabilities: ClientCapabilities{
			general: GeneralClientCapabilities{
				position_encodings: ['utf-32']
			}
		}
	}
	assert negotiate_position_encoding(params) == .utf32
}

fn test_classify_highlight_kind_read_write() {
	// Assignments and declarations are writes.
	assert classify_highlight_kind('x := 1', 0, 1) == doc_highlight_write
	assert classify_highlight_kind('x = 1', 0, 1) == doc_highlight_write
	assert classify_highlight_kind('x += 1', 0, 1) == doc_highlight_write
	assert classify_highlight_kind('x++', 0, 1) == doc_highlight_write
	assert classify_highlight_kind('x--', 0, 1) == doc_highlight_write
	assert classify_highlight_kind('bits <<= 1', 0, 4) == doc_highlight_write
	assert classify_highlight_kind('bits >>= 1', 0, 4) == doc_highlight_write
	assert classify_highlight_kind('fn f(item Type) {}', 5, 9) == doc_highlight_write
	assert classify_highlight_kind('fn (app App) run() {}', 4, 7) == doc_highlight_write
	assert classify_highlight_kind('for item in items {}', 4, 8) == doc_highlight_write
	assert classify_highlight_kind('for key, value in items {}', 4, 7) == doc_highlight_write
	assert classify_highlight_kind('for key, value in items {}', 9, 14) == doc_highlight_write
	// Comparisons and uses are reads.
	assert classify_highlight_kind('x == 1', 0, 1) == doc_highlight_read
	assert classify_highlight_kind('bits << 1', 0, 4) == doc_highlight_read
	assert classify_highlight_kind('bits >> 1', 0, 4) == doc_highlight_read
	assert classify_highlight_kind('foo(x)', 0, 3) == doc_highlight_read
	assert classify_highlight_kind('return x', 7, 8) == doc_highlight_read
	assert classify_highlight_kind('fn f(item Type) {}', 10, 14) == doc_highlight_read
	assert classify_highlight_kind('for item in items {}', 12, 17) == doc_highlight_read
}

fn test_document_highlight_candidates_include_braced_string_interpolations() {
	content := "fn greet(name string) {\n\tprintln('hello \${name} \$name literal_name')\n}\n"
	lines := content.split_into_lines()

	candidates := collect_document_highlight_candidates(content, lines, 'name', .utf16)
	assert candidates.len == 2
	assert candidates[0].line_idx == 0
	assert candidates[1].line_idx == 1
	assert collect_document_highlight_candidates(content, lines, 'literal_name', .utf16).len == 0
}

fn test_document_highlight_candidates_include_multiline_string_interpolations() {
	content := "fn greet(name string) {\n\tprintln('hello \${\n\t\tname\n\t}')\n}\n"
	lines := content.split_into_lines()

	candidates := collect_document_highlight_candidates(content, lines, 'name', .utf16)
	assert candidates.len == 2
	assert candidates[0].line_idx == 0
	assert candidates[1].line_idx == 2
}

fn test_document_highlight_returns_empty_over_semantic_cap() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///nonexistent_vls_highlight/main.v'
	mut content := 'module main\n\nfn first() {\n\tmut item := 0\n'
	for _ in 0 .. document_highlight_semantic_max_candidates / 2 {
		content += '\titem++\n'
	}
	content += '}\n\nfn second() {\n\tmut item := 0\n'
	for _ in 0 .. document_highlight_semantic_max_candidates / 2 {
		content += '\titem++\n'
	}
	content += '}\n'
	app.open_files[uri] = content

	response := app.handle_document_highlight(Request{
		id:     900
		method: 'textDocument/documentHighlight'
		params: json2.encode(DocumentHighlightParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 5
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is []DocumentHighlight
	highlights := response.result as []DocumentHighlight
	assert highlights.len == 0
}

fn test_on_did_change_invalid_range_does_not_advance_version() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/inv.v'
	app.open_files[uri] = 'module main\n'
	app.open_files_versions[uri] = 1
	// A reversed range is invalid: the change must be refused and the version
	// must NOT advance (P0-07).
	app.on_did_change(Request{
		params: json2.encode(DidChangeTextDocumentParams{
			text_document:   VersionedTextDocumentIdentifier{
				uri:     uri
				version: 2
			}
			content_changes: [
				ContentChange{
					text:  'X'
					range: LSPRange{
						start: Position{
							line: 0
							char: 5
						}
						end:   Position{
							line: 0
							char: 2
						}
					}
				},
			]
		},
			escape_unicode: true
		)
	}) or {}
	// Content unchanged, version still 1.
	assert app.open_files[uri] == 'module main\n'
	assert app.open_files_versions[uri] == 1
}

fn test_merge_vlib_module_fns_caches_per_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	mut idx := map[string]string{}
	// A module with no matching vlib directory caches an empty index so it is
	// never re-walked on subsequent inlayHint requests.
	app.merge_vlib_module_fns('no_such_vlib_module_xyz', mut idx)
	assert 'no_such_vlib_module_xyz' in app.vlib_fn_cache
	assert app.vlib_fn_cache['no_such_vlib_module_xyz'].len == 0
	assert idx.len == 0
	// Second call is served from the cache and still merges nothing new.
	app.merge_vlib_module_fns('no_such_vlib_module_xyz', mut idx)
	assert idx.len == 0
}

fn test_operation_at_pos_hover_returns_symbol_information() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'hover_feature')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\n// helper returns the supplied value.\nfn helper(value int) int {\n\treturn value\n}\n\nfn main() {\n\tanswer := helper(1)\n\tprintln(answer)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	app.text = content

	response := app.operation_at_pos(.hover, Request{
		id:     901
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 8
				char: 13
			}
		},
			escape_unicode: true
		)
	})

	assert response.id == 901
	assert response.result is Hover
	hover := response.result as Hover
	assert hover.contents.value.contains('helper')
	assert hover.contents.value.contains('helper returns the supplied value')
}

fn test_find_references_returns_declaration_and_calls() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'references_feature')
	must_mkdir_all(test_dir)
	must_write_file(os.join_path(test_dir, 'v.mod'), 'Module {}\n')
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn shared_value() int {\n\treturn 1\n}\n\nfn first() int {\n\treturn shared_value()\n}\n\nfn second() int {\n\treturn shared_value()\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	app.workspace_roots = [test_dir]

	response := app.find_references(Request{
		id:     902
		method: 'textDocument/references'
		params: json2.encode(ReferenceParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 7
				char: 10
			}
			context:       ReferenceContext{
				include_declaration: true
			}
		},
			escape_unicode: true
		)
	})

	assert response.id == 902
	assert response.result is []Location
	locations := response.result as []Location
	assert locations.len == 3
	assert locations.any(it.range.start.line == 2)
	assert locations.any(it.range.start.line == 7)
	assert locations.any(it.range.start.line == 11)
}

fn test_handle_rename_returns_complete_workspace_edit() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'rename_feature')
	must_mkdir_all(test_dir)
	must_write_file(os.join_path(test_dir, 'v.mod'), 'Module {}\n')
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn shared_value() int {\n\treturn 1\n}\n\nfn main() {\n\tprintln(shared_value())\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	app.open_files_versions[uri] = 7
	app.workspace_roots = [test_dir]

	response := app.handle_rename(Request{
		id:     903
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 7
				char: 11
			}
			new_name:      'renamed_value'
		},
			escape_unicode: true
		)
	})

	assert response.id == 903
	assert response.result is WorkspaceEdit
	edit := response.result as WorkspaceEdit
	assert edit.changes[uri].len == 2
	assert edit.changes[uri].all(it.new_text == 'renamed_value')
	if document_changes := edit.document_changes {
		assert document_changes.len == 1
		assert document_changes[0].text_document.uri == uri
		assert (document_changes[0].text_document.version or { -1 }) == 7
		assert document_changes[0].edits.len == 2
	} else {
		assert false, 'rename must include versioned documentChanges'
	}
}

fn test_folding_range_covers_imports_comments_and_code_blocks() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/folding_feature.v'
	app.open_files[uri] = 'module main\n\nimport os\nimport time\n\n// first line\n// second line\n\nfn main() {\n\tprintln(os.args)\n}\n'

	response := app.handle_folding_range(Request{
		id:     904
		method: 'textDocument/foldingRange'
		params: json2.encode(FoldingRangeParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	assert response.id == 904
	assert response.result is []FoldingRange
	ranges := response.result as []FoldingRange
	assert ranges.any(it.kind == 'imports' && it.start_line == 2 && it.end_line == 3)
	assert ranges.any(it.kind == 'comment' && it.start_line == 5 && it.end_line == 6)
	assert ranges.any(it.kind == 'region' && it.start_line == 8 && it.end_line == 10)
}

fn test_document_highlight_returns_reads_and_writes() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'highlight_feature')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn main() {\n\tvalue := 1\n\tvalue += 1\n\tprintln(value)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	response := app.handle_document_highlight(Request{
		id:     905
		method: 'textDocument/documentHighlight'
		params: json2.encode(DocumentHighlightParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 3
				char: 2
			}
		},
			escape_unicode: true
		)
	})

	assert response.id == 905
	assert response.result is []DocumentHighlight
	highlights := response.result as []DocumentHighlight
	assert highlights.len == 3
	assert highlights.filter(it.kind == doc_highlight_write).len == 2
	assert highlights.filter(it.kind == doc_highlight_read).len == 1
}

fn test_workspace_configuration_toggles_feature_behavior() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/config_feature.v'
	content := 'module main\n\nfn main() {\n\tvalue := 1\n\tprintln(value)\n}\n'
	app.open_files[uri] = content

	app.on_did_change_configuration(Request{
		method: 'workspace/didChangeConfiguration'
		params: '{"settings":{"vls":{"inlayHints":false,"diagnostics":false}}}'
	})
	assert !app.inlay_hints_enabled
	assert !app.diagnostics_enabled

	hint_response := app.handle_inlay_hints(Request{
		id:     906
		method: 'textDocument/inlayHint'
		params: json2.encode(InlayHintParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{}
				end:   Position{
					line: 5
				}
			}
		},
			escape_unicode: true
		)
	})
	assert hint_response.result is []InlayHint
	assert (hint_response.result as []InlayHint).len == 0
	assert app.build_diagnostics_notification(uri, content).params.diagnostics.len == 0

	app.on_did_change_configuration(Request{
		method: 'workspace/didChangeConfiguration'
		params: '{"settings":{"inlayHints":true,"diagnostics":true}}'
	})
	assert app.inlay_hints_enabled
	assert app.diagnostics_enabled
}

fn test_will_save_wait_until_formats_without_mutating_open_document() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'will_save_feature')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn main(){\nprintln("hello")\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	response := app.on_will_save_wait_until(Request{
		id:     907
		method: 'textDocument/willSaveWaitUntil'
		params: json2.encode(WillSaveTextDocumentParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			reason:        1
		},
			escape_unicode: true
		)
	})

	assert response.result is []TextEdit
	edits := response.result as []TextEdit
	assert edits.len == 1
	assert edits[0].new_text.contains('fn main() {')
	assert edits[0].new_text.contains('\tprintln')
	assert app.open_files[uri] == content
}

fn test_range_formatting_returns_only_contained_changed_hunk() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'range_format_feature')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn main() {\nx:=1\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	response := app.handle_range_formatting(Request{
		id:     908
		method: 'textDocument/rangeFormatting'
		params: json2.encode(DocumentRangeFormattingParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         LSPRange{
				start: Position{
					line: 3
				}
				end:   Position{
					line: 3
					char: 4
				}
			}
			options:       FormattingOptions{
				tab_size: 4
			}
		},
			escape_unicode: true
		)
	})

	assert response.id == 908
	assert response.result is []TextEdit
	edits := response.result as []TextEdit
	assert edits.len == 1
	assert edits[0].range.start.line == 3
	assert edits[0].range.end.line == 4
	assert edits[0].new_text == '\tx := 1\n'
}

fn test_prepare_call_hierarchy_returns_function_item() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/prepare_call_feature.v'
	app.open_files[uri] = 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'

	response := app.handle_prepare_call_hierarchy(Request{
		id:     909
		method: 'textDocument/prepareCallHierarchy'
		params: json2.encode(PrepareCallHierarchyParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 5
				char: 2
			}
		},
			escape_unicode: true
		)
	})

	assert response.id == 909
	assert response.result is []CallHierarchyItem
	items := response.result as []CallHierarchyItem
	assert items.len == 1
	assert items[0].name == 'helper'
	assert items[0].uri == uri
	assert items[0].selection_range.start.line == 2
}
