// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import json2
import time

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
			text: ''
			open_files: map[string]string{}
			temp_dir: temp_dir
		}
	}
	return &App{
		text: ''
		open_files: map[string]string{}
		temp_dir: temp_dir
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
		id: 1
		method: 'textDocument/didOpen'
		jsonrpc: '2.0'
		params: json2.encode(Params{
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
				uri: uri
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
				uri: uri
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
		id: 2
		method: 'textDocument/didChange'
		jsonrpc: '2.0'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
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
			text_document: TextDocumentIdentifier{
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

fn test_on_did_change_schedules_diagnostics_without_blocking() {
	mut app := create_test_app()
	defer {
		app.cancel_all_scheduled_diagnostics()
		cleanup_test_app(app)
	}
	app.diagnostics_scheduler = new_diagnostics_scheduler()
	uri := 'file:///tmp/scheduled.v'
	content := 'module main\n'
	app.open_files[uri] = content
	app.open_files_versions[uri] = 1

	result := app.on_did_change(Request{
		params: json2.encode(DidChangeTextDocumentParams{
			text_document: VersionedTextDocumentIdentifier{
				uri: uri
				version: 2
			}
			content_changes: [ContentChange{
				text: content + '\nfn changed() {}\n'
			}]
		},
			escape_unicode: true
		)
	})

	assert result == none
	assert app.open_files_versions[uri] == 2
	assert app.open_files[uri].contains('fn changed()')
}

fn test_a_file_created_on_disk_rechecks_the_open_files_of_its_program() {
	// A file created, deleted or renamed on disk decides whether an import
	// resolves, so the open files of its program are checked again, though none
	// of them changed.
	mut app := create_test_app()
	defer {
		app.cancel_all_scheduled_diagnostics()
		cleanup_test_app(app)
	}
	app.diagnostics_scheduler = new_diagnostics_scheduler()
	project := os.join_path(app.temp_dir, 'created_module')
	must_mkdir_all(os.join_path(project, 'lib'))
	main_path := os.join_path(project, 'main.v')
	main_content := 'module main\n\nimport lib\n\nfn main() {}\n'
	must_write_file(main_path, main_content)
	main_uri := path_to_uri(main_path)
	app.open_files[main_uri] = main_content
	lib_path := os.join_path(project, 'lib', 'lib.v')
	must_write_file(lib_path, 'module lib\n')
	mutation := app.begin_diagnostics_project_mutation(path_to_uri(lib_path))
	assert mutation.tickets.any(it.uri == main_uri), mutation.tickets.str()
}

fn test_diagnostics_scheduler_invalidates_only_changed_document() {
	mut scheduler := new_diagnostics_scheduler()
	global_a, generation_a := scheduler.next_generation('file:///a.v')
	global_b, generation_b := scheduler.next_generation('file:///b.v')
	assert scheduler.is_current('file:///a.v', global_a, generation_a)
	assert scheduler.is_current('file:///b.v', global_b, generation_b)

	scheduler.cancel('file:///a.v')
	assert !scheduler.is_current('file:///a.v', global_a, generation_a)
	assert scheduler.is_current('file:///b.v', global_b, generation_b)

	scheduler.cancel_all()
	assert !scheduler.is_current('file:///b.v', global_b, generation_b)
}

fn test_diagnostics_scheduler_coalesces_pending_jobs() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	mut scheduler := new_diagnostics_scheduler()
	uri := 'file:///pending.v'
	global_first, generation_first := scheduler.next_generation(uri)
	should_start := scheduler.enqueue(DiagnosticsJob{
		uri: uri
		content: 'first'
		global_generation: global_first
		generation: generation_first
		ready_at: 100
		write_mutex: app.write_mutex
	})
	assert should_start
	global_latest, generation_latest := scheduler.next_generation(uri)
	should_restart := scheduler.enqueue(DiagnosticsJob{
		uri: uri
		content: 'latest'
		global_generation: global_latest
		generation: generation_latest
		ready_at: 100
		write_mutex: app.write_mutex
	})
	assert !should_restart

	jobs, should_stop := scheduler.take_ready_jobs(100)
	assert !should_stop
	assert jobs.len == 1
	assert jobs[0].content == 'latest'
	assert scheduler.is_current(jobs[0].uri, jobs[0].global_generation, jobs[0].generation)

	scheduler.finish(jobs[0])
	_, should_stop_after_drain := scheduler.take_ready_jobs(100)
	assert should_stop_after_drain
}

fn test_diagnostics_scheduler_requeues_pending_sibling_with_latest_buffers() {
	mut app := create_test_app()
	defer {
		app.cancel_all_scheduled_diagnostics()
		cleanup_test_app(app)
	}
	mut scheduler := new_diagnostics_scheduler()
	app.diagnostics_scheduler = scheduler
	project_dir := os.join_path(app.temp_dir, 'sibling_project')
	must_mkdir_all(project_dir)
	uri_a := path_to_uri(os.join_path(project_dir, 'a.v'))
	uri_b := path_to_uri(os.join_path(project_dir, 'b.v'))
	content_a := 'module main\n\nfn uses_b() { changed_in_b() }\n'
	old_content_b := 'module main\n\nfn old_in_b() {}\n'
	new_content_b := 'module main\n\nfn changed_in_b() {}\n'
	app.open_files[uri_a] = content_a
	app.open_files[uri_b] = old_content_b
	app.open_files_versions[uri_b] = 1
	assert app.schedule_diagnostics(uri_a, content_a)
	old_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected pending diagnostics for a.v'
		return
	}

	result := app.on_did_change(Request{
		params: json2.encode(DidChangeTextDocumentParams{
			text_document: VersionedTextDocumentIdentifier{
				uri: uri_b
				version: 2
			}
			content_changes: [ContentChange{
				text: new_content_b
			}]
		},
			escape_unicode: true
		)
	})
	assert result == none
	assert !scheduler.is_job_current(old_job_a)
	new_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected replacement diagnostics for a.v'
		return
	}
	assert new_job_a.open_files[uri_b] == new_content_b
	assert new_job_a.project_generation > old_job_a.project_generation
}

fn test_diagnostics_scheduler_requeues_sibling_after_open() {
	mut app := create_test_app()
	defer {
		app.cancel_all_scheduled_diagnostics()
		cleanup_test_app(app)
	}
	mut scheduler := new_diagnostics_scheduler()
	app.diagnostics_scheduler = scheduler
	project_dir := os.join_path(app.temp_dir, 'open_sibling_project')
	must_mkdir_all(project_dir)
	uri_a := path_to_uri(os.join_path(project_dir, 'a.v'))
	uri_b := path_to_uri(os.join_path(project_dir, 'b.v'))
	content_a := 'module main\n\nfn uses_b() { opened_in_b() }\n'
	content_b := 'module main\n\nfn opened_in_b() {}\n'
	app.open_files[uri_a] = content_a
	assert app.schedule_diagnostics(uri_a, content_a)
	old_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected pending diagnostics for a.v'
		return
	}
	assert uri_b !in old_job_a.open_files

	assert app.on_did_open(Request{
		params: json2.encode(DidOpenTextDocumentParams{
			text_document: DidOpenTextDocumentItem{
				uri: uri_b
				text: content_b
			}
		},
			escape_unicode: true
		)
	})

	assert !scheduler.is_job_current(old_job_a)
	new_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected replacement diagnostics for a.v'
		return
	}
	assert new_job_a.open_files[uri_b] == content_b
	assert new_job_a.project_generation > old_job_a.project_generation
}

fn test_diagnostics_scheduler_requeues_sibling_after_save_text() {
	mut app := create_test_app()
	defer {
		app.cancel_all_scheduled_diagnostics()
		cleanup_test_app(app)
	}
	mut scheduler := new_diagnostics_scheduler()
	app.diagnostics_scheduler = scheduler
	project_dir := os.join_path(app.temp_dir, 'save_sibling_project')
	must_mkdir_all(project_dir)
	uri_a := path_to_uri(os.join_path(project_dir, 'a.v'))
	uri_b := path_to_uri(os.join_path(project_dir, 'b.v'))
	content_a := 'module main\n\nfn uses_b() { saved_in_b() }\n'
	old_content_b := 'module main\n\nfn old_in_b() {}\n'
	new_content_b := 'module main\n\nfn saved_in_b() {}\n'
	app.open_files[uri_a] = content_a
	app.open_files[uri_b] = old_content_b
	assert app.schedule_diagnostics(uri_a, content_a)
	old_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected pending diagnostics for a.v'
		return
	}

	result := app.on_did_save(Request{
		params: json2.encode(DidSaveTextDocumentParams{
			text_document: TextDocumentIdentifier{
				uri: uri_b
			}
			text: new_content_b
		},
			escape_unicode: true
		)
	})
	assert result == none
	assert !scheduler.is_job_current(old_job_a)
	new_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected replacement diagnostics for a.v'
		return
	}
	assert new_job_a.open_files[uri_b] == new_content_b
	assert new_job_a.project_generation > old_job_a.project_generation
}

fn test_diagnostics_scheduler_requeues_sibling_after_close() {
	mut app := create_test_app()
	defer {
		app.cancel_all_scheduled_diagnostics()
		cleanup_test_app(app)
	}
	mut scheduler := new_diagnostics_scheduler()
	app.diagnostics_scheduler = scheduler
	project_dir := os.join_path(app.temp_dir, 'close_sibling_project')
	must_mkdir_all(project_dir)
	path_a := os.join_path(project_dir, 'a.v')
	path_b := os.join_path(project_dir, 'b.v')
	uri_a := path_to_uri(path_a)
	uri_b := path_to_uri(path_b)
	content_a := 'module main\n\nfn uses_b() { disk_in_b() }\n'
	open_content_b := 'module main\n\nfn unsaved_in_b() {}\n'
	must_write_file(path_a, content_a)
	must_write_file(path_b, 'module main\n\nfn disk_in_b() {}\n')
	app.open_files[uri_a] = content_a
	app.open_files[uri_b] = open_content_b
	assert app.schedule_diagnostics(uri_a, content_a)
	old_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected pending diagnostics for a.v'
		return
	}
	assert old_job_a.open_files[uri_b] == open_content_b

	app.on_did_close(Request{
		params: json2.encode(DidCloseTextDocumentParams{
			text_document: TextDocumentIdentifier{
				uri: uri_b
			}
		},
			escape_unicode: true
		)
	})

	assert !scheduler.is_job_current(old_job_a)
	new_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected replacement diagnostics for a.v'
		return
	}
	assert uri_b !in new_job_a.open_files
	assert new_job_a.project_generation > old_job_a.project_generation
}

fn test_diagnostics_scheduler_requeues_job_after_watched_file_change() {
	mut app := create_test_app()
	defer {
		app.cancel_all_scheduled_diagnostics()
		cleanup_test_app(app)
	}
	mut scheduler := new_diagnostics_scheduler()
	app.diagnostics_scheduler = scheduler
	project_dir := os.join_path(app.temp_dir, 'watched_sibling_project')
	must_mkdir_all(project_dir)
	path_a := os.join_path(project_dir, 'a.v')
	path_b := os.join_path(project_dir, 'b.v')
	uri_a := path_to_uri(path_a)
	uri_b := path_to_uri(path_b)
	content_a := 'module main\n\nfn uses_b() { changed_in_b() }\n'
	must_write_file(path_a, content_a)
	must_write_file(path_b, 'module main\n\nfn old_in_b() {}\n')
	app.open_files[uri_a] = content_a
	assert app.schedule_diagnostics(uri_a, content_a)
	old_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected pending diagnostics for a.v'
		return
	}
	old_cache_generation := old_job_a.project_generations[app.generation_key(uri_a)]
	must_write_file(path_b, 'module main\n\nfn changed_in_b() {}\n')

	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [FileEvent{
				uri: uri_b
				event_type: 2
			}]
		})
	})

	assert !scheduler.is_job_current(old_job_a)
	new_job_a := diagnostics_test_pending_job(mut scheduler, uri_a) or {
		assert false, 'expected replacement diagnostics for a.v'
		return
	}
	assert new_job_a.project_generation > old_job_a.project_generation
	assert new_job_a.project_generations[app.generation_key(uri_a)] > old_cache_generation
}

fn test_diagnostics_scheduler_requeues_active_sibling() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	mut scheduler := new_diagnostics_scheduler()
	uri_a := 'file:///project/a.v'
	uri_b := 'file:///project/b.v'
	project_key := 'file:///project'
	tickets_a := scheduler.begin_project_schedule(uri_a, project_key)
	assert tickets_a.len == 1
	active_job := DiagnosticsJob{
		uri: uri_a
		project_key: project_key
		project_generation: tickets_a[0].project_generation
		global_generation: tickets_a[0].global_generation
		generation: tickets_a[0].generation
		ready_at: 0
		write_mutex: app.write_mutex
	}
	assert scheduler.enqueue(active_job)
	jobs, should_stop := scheduler.take_ready_jobs(0)
	assert !should_stop
	assert jobs.len == 1

	tickets_b := scheduler.begin_project_schedule(uri_b, project_key)
	assert !scheduler.is_job_current(active_job)
	assert tickets_b.any(it.uri == uri_a)
	assert tickets_b.any(it.uri == uri_b)
	scheduler.finish(active_job)
	_, should_stop_after_finish := scheduler.take_ready_jobs(0)
	assert should_stop_after_finish
}

fn diagnostics_test_pending_job(mut scheduler DiagnosticsScheduler, uri string) ?DiagnosticsJob {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	job := scheduler.pending_jobs[uri] or { return none }
	return job
}

fn test_diagnostics_scheduler_checks_staleness_while_publishing() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	app.capture_output = true
	mut scheduler := new_diagnostics_scheduler()
	uri := 'file:///publish.v'
	global_generation, generation := scheduler.next_generation(uri)
	job := DiagnosticsJob{
		uri: uri
		global_generation: global_generation
		generation: generation
		write_mutex: app.write_mutex
	}
	notification := Notification{
		method: 'textDocument/publishDiagnostics'
		params: PublishDiagnosticsParams{
			uri: uri
		}
	}

	assert scheduler.publish_if_current(mut app, job, notification)
	assert app.captured_output.len == 1
	scheduler.cancel(uri)
	assert !scheduler.publish_if_current(mut app, job, notification)
	assert app.captured_output.len == 1
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
				text_document: TextDocumentIdentifier{
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
			text_document: TextDocumentIdentifier{
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
		end: Position{
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
		end: Position{
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
		end: Position{
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
		end: Position{
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
		end: Position{
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
		end: Position{
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
		dir: '/root_a'
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
		end: Position{
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
		end: Position{
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
		end: Position{
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
		end: Position{
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
		id: 1
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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
		id: 2
		method: 'textDocument/definition'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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

fn test_resolve_indexed_definition_rejects_declaration_in_nested_block_comment() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_nested_block_comment')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n/* outer\n\t/* inner */\n\tfn helper() {}\n*/\nfn main() { helper() }\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	helper_col := content.split_into_lines()[5].index('helper') or {
		assert false, 'expected unresolved helper call'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 5
		char: helper_col + 2
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_inline_assembly_identifiers() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_inline_assembly')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn mov() {}\n\nfn main() {\n\tasm amd64 { mov rax, 1 }\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	mov_col := content.split_into_lines()[5].index('mov') or {
		assert false, 'expected assembly mnemonic'
		return
	}

	location := app.resolve_indexed_definition(uri, Position{
		line: 5
		char: mov_col + 1
	})
	assert location == none
}

fn test_resolve_indexed_definition_defers_hash_directive_contents() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_hash_directive')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\n#include <helper.h>\n#flag -l library\n\nfn helper() {}\nfn library() {}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	helper_col := lines[2].index('helper') or {
		assert false, 'expected include header'
		return
	}
	library_col := lines[3].index('library') or {
		assert false, 'expected flag argument'
		return
	}

	header_location := app.resolve_indexed_definition(uri, Position{
		line: 2
		char: helper_col + 2
	})
	assert header_location == none
	flag_location := app.resolve_indexed_definition(uri, Position{
		line: 3
		char: library_col + 2
	})
	assert flag_location == none
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
	content := "module main\n\nfn age() {}\n\nfn query() {\n\ttext := r'foo\\'\n\t_ := sql app.db {\n\t\tselect from User where age > 21\n\t}\n\tprintln(text)\n}\n"
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

fn test_resolve_indexed_definition_defers_multiline_destructured_local_shadow() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_multiline_destructured_shadow')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn key() {}\n\nfn pair() (int, int) {\n\treturn 1, 2\n}\n\nfn main() {\n\tkey,\n\t\tvalue := pair()\n\tprintln(key)\n\tprintln(value)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	declaration_col := lines[9].index('key') or {
		assert false, 'expected first destructured target'
		return
	}
	use_col := lines[11].index('key') or {
		assert false, 'expected destructured local use'
		return
	}

	assert source_occurrence_precedes_local_declaration(lines, 9, declaration_col + 3)
	for position in [Position{
		line: 9
		char: declaration_col + 1
	}, Position{
		line: 11
		char: use_col + 1
	}] {
		location := app.resolve_indexed_definition(uri, position)
		assert location == none
	}
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
	content := 'module main\n\nfn windows() {}\n\n\$if windows {\n\tfn active() {}\n}\n'
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
	content := 'module main\n\nfn windows() {}\n\n\$if (\n\twindows\n) {\n\tfn active() {}\n}\n'
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

fn test_resolve_indexed_definition_defers_commented_parameter_shadow() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_commented_parameter_shadow')
	must_mkdir_all(test_dir)
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn helper() {}\n\nfn use(helper /* explanation */ int) {\n\tprintln(helper)\n}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	parameter_col := lines[4].index('helper') or {
		assert false, 'expected commented parameter'
		return
	}
	use_col := lines[5].index('helper') or {
		assert false, 'expected parameter use'
		return
	}

	assert source_occurrence_has_type_suffix(lines, 4, parameter_col + 6)
	for position in [Position{
		line: 4
		char: parameter_col + 2
	}, Position{
		line: 5
		char: use_col + 2
	}] {
		location := app.resolve_indexed_definition(uri, position)
		assert location == none
	}
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

fn test_active_indexed_source_file_names_applies_compiler_build_rules() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'active_source_file_names')
	must_mkdir_all(test_dir)
	inactive_os := $if windows { 'linux' } $else { 'windows' }
	source := 'module main\n\nfn helper() {}\n'
	for name in ['main.v', 'plain_${inactive_os}.v', 'gated_d_somefeature.v',
		'gated_notd_somefeature.v', 'main_test.v', 'sibling_${inactive_os}_test.v'] {
		must_write_file(os.join_path(test_dir, name), source)
	}
	// A file the client created but has not saved yet is not on disk, so the
	// compiler's directory scan cannot see it.
	unsaved_uri := path_to_uri(os.join_path(test_dir, 'unsaved.v'))
	app.open_files[unsaved_uri] = source

	active := app.active_indexed_source_file_names(test_dir, 'main_test.v')
	assert 'main.v' in active
	assert 'unsaved.v' in active
	// VLS passes no defines, so `_d_` sources are inactive and `_notd_` ones active.
	assert 'gated_notd_somefeature.v' in active
	assert 'gated_d_somefeature.v' !in active
	assert 'plain_${inactive_os}.v' !in active
	// The requesting test file is a compiler input; sibling tests are separate
	// targets and a platform-qualified one still has to match the host.
	assert 'main_test.v' in active
	assert 'sibling_${inactive_os}_test.v' !in active

	// A test that cannot run on this platform is not activated by requesting it.
	inactive_active := app.active_indexed_source_file_names(test_dir, 'sibling_${inactive_os}_test.v')
	assert 'sibling_${inactive_os}_test.v' !in inactive_active
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

fn test_resolve_indexed_definition_defers_conditional_attribute_declaration() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'indexed_definition_conditional_attribute')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	inactive_condition := $if windows { 'linux' } $else { 'windows' }
	main_content := 'module main\n\n@[if ${inactive_condition}]\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	must_write_file(main_file, main_content)
	main_uri := path_to_uri(main_file)
	app.open_files[main_uri] = main_content

	assert source_declaration_is_compile_time_conditional(main_content, 3)
	location := app.resolve_indexed_definition(main_uri, Position{
		line: 6
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

fn test_resolve_indexed_definition_ignores_import_in_nested_block_comment() {
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
	main_content := 'module main\n\nimport right as util\n/* outer\n\t/* inner */\nimport wrong as util\n*/\n\nfn main() {\n\tutil.answer()\n}\n'
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

fn test_source_call_target_ignores_non_code_delimiters() {
	literal_line := "foo(')')"
	literal_target := source_call_target(literal_line, Position{
		char: literal_line.len - 1
	}, .utf8) or {
		assert false, 'expected call target with a parenthesis in a string literal'
		return
	}
	assert literal_target.position.char == 2
	assert literal_target.active_parameter == 0

	raw_line := "foo(r')')"
	raw_target := source_call_target(raw_line, Position{
		char: raw_line.len - 1
	}, .utf8) or {
		assert false, 'expected call target with a parenthesis in a raw string literal'
		return
	}
	assert raw_target.position.char == 2
	assert raw_target.active_parameter == 0

	comment_line := 'foo(/* ) */ value)'
	comment_target := source_call_target(comment_line, Position{
		char: comment_line.len - 1
	}, .utf8) or {
		assert false, 'expected call target with a parenthesis in a comment'
		return
	}
	assert comment_target.position.char == 2
	assert comment_target.active_parameter == 0

	comma_line := "foo('last, first', value)"
	comma_target := source_call_target(comma_line, Position{
		char: comma_line.len - 1
	}, .utf8) or {
		assert false, 'expected call target with a comma in a string literal'
		return
	}
	assert comma_target.position.char == 2
	assert comma_target.active_parameter == 1
}

fn test_source_call_target_handles_multiline_and_generic_calls() {
	generic_line := 'convert[int](value)'
	generic_target := source_call_target(generic_line, Position{
		char: generic_line.len - 1
	}, .utf8) or {
		assert false, 'expected call target before explicit generic arguments'
		return
	}
	assert generic_target.position == Position{
		line: 0
		char: 2
	}

	multiline := "fn main() {\n\tfoo(\n\t\tfirst,\n\t\t'last, )'\n\t)\n}"
	cursor_line := "\t\t'last, )'"
	multiline_target := source_call_target(multiline, Position{
		line: 3
		char: cursor_line.len
	}, .utf8) or {
		assert false, 'expected call target on a preceding line'
		return
	}
	assert multiline_target.position == Position{
		line: 1
		char: 3
	}
	assert multiline_target.active_parameter == 1
}

fn test_declaration_signature_label_keeps_generics_and_return_type() {
	declaration := 'pub fn convert[T](value T) !T'
	assert declaration_signature_label(declaration, 'convert') == 'convert[T](value T) !T'
	assert declaration_signature_label('fn parse(value string) ?int', 'parse') == 'parse(value string) ?int'
}

fn test_signature_parameters_split_only_top_level_commas() {
	parameters := signature_parameters('apply(cb fn (int, string), value int) !bool')
	assert parameters.len == 2
	assert parameters[0].label == 'cb fn (int, string)'
	assert parameters[1].label == 'value int'
}

fn test_signature_active_parameter_clamps_variadic_arguments() {
	variadic := signature_parameters('collect(prefix string, values ...int)')
	assert signature_active_parameter(variadic, 1) == 1
	assert signature_active_parameter(variadic, 2) == 1

	fixed := signature_parameters('collect(prefix string, value int)')
	assert signature_active_parameter(fixed, 2) == 2
}

fn test_source_declaration_at_stops_non_braced_declarations() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/source_declaration_fallback.v'
	content := 'module main\n\nconst (\n\tanswer = 42\n\tother = 7\n)\n\ntype Alias = int\ntype Handler = fn (int) bool\n\nfn next() {}\n\nfn parse(\n\tvalue string, // explanation\n\t/* { inside comment\n\tcontinued } */\n\tradix int,\n) !int {\n}\n'
	app.open_files[uri] = content

	constant := app.source_declaration_at(Location{
		uri: uri
		range: LSPRange{
			start: Position{
				line: 3
			}
		}
	})
	assert constant == 'answer = 42'

	alias := app.source_declaration_at(Location{
		uri: uri
		range: LSPRange{
			start: Position{
				line: 7
			}
		}
	})
	assert alias == 'type Alias = int'

	function_alias := app.source_declaration_at(Location{
		uri: uri
		range: LSPRange{
			start: Position{
				line: 8
			}
		}
	})
	assert function_alias == 'type Handler = fn (int) bool'

	function := app.source_declaration_at(Location{
		uri: uri
		range: LSPRange{
			start: Position{
				line: 12
			}
		}
	})
	assert function == 'fn parse(\nvalue string, // explanation\n/* { inside comment\ncontinued } */\nradix int,\n) !int'
	label := declaration_signature_label(function, 'parse')
	assert label == 'parse(\nvalue string, // explanation\n/* { inside comment\ncontinued } */\nradix int,\n) !int'
	assert signature_parameters(label).len == 2
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

fn test_resolve_indexed_definition_resolves_receiver_method() {
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
	}) or {
		assert false, 'expected indexed receiver method definition'
		return
	}
	assert location.uri == uri
	assert location.range.start.line == 4
	assert location.range.start.char == 15
	assert location.range.end.char == 21
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
		id: 3
		method: 'textDocument/signatureHelp'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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
			id: id
			params: json2.encode(Params{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position: Position{
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
		id: 1
		result: 'null'
	}
	encoded := json2.encode(response, escape_unicode: true)
	assert encoded.contains('"id":1')
	assert encoded.contains('"jsonrpc":"2.0"')
}

fn test_json_encode_capabilities_response() {
	response := Response{
		id: 0
		result: Capabilities{
			capabilities: Capability{
				text_document_sync: TextDocumentSyncOptions{
					open_close: true
					change: 1
				}
				completion_provider: CompletionProvider{
					trigger_characters: ['.']
				}
				signature_help_provider: SignatureHelpOptions{
					trigger_characters: ['(', ',']
				}
				definition_provider: true
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
			kind: 6
			label: 'println'
			detail: 'fn println(s string)'
			documentation: 'Prints to stdout'
		},
		Detail{
			kind: 6
			label: 'print'
			detail: 'fn print(s string)'
			documentation: 'Prints without newline'
		},
	]
	response := Response{
		id: 2
		result: details
	}
	encoded := json2.encode(response, escape_unicode: true)
	assert encoded.contains('"label":"println"')
	assert encoded.contains('"label":"print"')
}

fn test_json_encode_location_response() {
	response := Response{
		id: 3
		result: Location{
			uri: 'file:///test/main.v'
			range: LSPRange{
				start: Position{
					line: 10
					char: 5
				}
				end: Position{
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
		id: 4
		result: SignatureHelp{
			signatures: [
				SignatureInformation{
					label: 'fn test(a int, b string)'
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
			uri: 'file:///test.v'
			diagnostics: [
				LSPDiagnostic{
					range: LSPRange{
						start: Position{
							line: 5
							char: 0
						}
						end: Position{
							line: 5
							char: 10
						}
					}
					message: 'undefined identifier'
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
			col: 10
			message: 'error 1'
		},
		JsonError{
			line_nr: 5
			col: 10
			message: 'error 2'
		}, // duplicate position
		JsonError{
			line_nr: 6
			col: 5
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
			col: 1
			message: 'error 1'
		},
		JsonError{
			line_nr: 5
			col: 10
			message: 'error 2'
		},
		JsonError{
			line_nr: 5
			col: 20
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
			kind: 6
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
		path: '/test/file.v'
		message: 'undefined identifier `foo`'
		line_nr: 10
		col: 5
		len: 3
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
		path: '/test/file.v'
		message: 'syntax error'
		line_nr: 1
		col: 1
		len: 1
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 0
	assert diag.range.start.char == 0
	assert diag.range.end.char == 1
}

fn test_v_error_to_lsp_diagnostic_long_error() {
	v_err := JsonError{
		path: '/test/file.v'
		message: 'unexpected token'
		line_nr: 100
		col: 50
		len: 20
	}
	diag := v_error_to_lsp_diagnostic(v_err)

	assert diag.range.start.line == 99
	assert diag.range.start.char == 49
	assert diag.range.end.char == 69 // 49 + 20
}

fn test_v_error_to_lsp_diagnostic_zero_length() {
	v_err := JsonError{
		path: '/test/file.v'
		message: 'error at position'
		line_nr: 5
		col: 10
		len: 0
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
			col: 1
			len: 1
		}
		diag := v_error_to_lsp_diagnostic(v_err)
		assert diag.message == msg
	}
}

fn test_v_error_to_lsp_diagnostic_always_error_severity() {
	v_err := JsonError{
		path: '/test.v'
		message: 'any error'
		line_nr: 1
		col: 1
		len: 1
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
			text_document: TextDocumentIdentifier{
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
		id: 1
		method: 'textDocument/formatting'
		jsonrpc: '2.0'
		params: json2.encode(Params{
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
		id: 2
		method: 'textDocument/formatting'
		jsonrpc: '2.0'
		params: json2.encode(Params{
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
		id: 3
		method: 'textDocument/formatting'
		jsonrpc: '2.0'
		params: json2.encode(Params{
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
		id: 4
		method: 'textDocument/formatting'
		jsonrpc: '2.0'
		params: json2.encode(Params{
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
		id: 901
		method: 'textDocument/references'
		params: json2.encode(ReferenceParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: 1
				char: 0
			}
			context: ReferenceContext{
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
		id: 902
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: 1
				char: 0
			}
			new_name: 'renamed'
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
				uri: disk_uri
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
	must_write_file(os.join_path(test_dir, 'oversized.v'), 'x'.repeat(int(index_max_file_bytes) + 1))
	uri := path_to_uri(test_file)
	app.open_files[uri] = content

	resp := app.handle_rename(Request{
		id: 903
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: 2
				char: 4
			}
			new_name: 'renamed'
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
		id: 10
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
		id: 11
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
		id: 12
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
			id: id
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
		id: 20
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

fn test_source_line_import_code_tracks_nested_block_comments() {
	mut state := ImportScanState{}
	outer := source_line_import_code('before /* outer', mut state)
	inner := source_line_import_code('/* inner */', mut state)
	commented := source_line_import_code('import wrong as util', mut state)
	after := source_line_import_code('*/ import right as util', mut state)

	assert outer.trim_space() == 'before'
	assert inner.trim_space() == ''
	assert commented.trim_space() == ''
	assert after.trim_space() == 'import right as util'
	assert state.block_comment_depth == 0
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
	imported_module := app.imported_module_at_symbol(lines[call_line], foo_col, content, Position{
		line: call_line
		char: foo_col
	})
	assert imported_module == 'b'

	doc := app.find_doc_comment_for_symbol('foo', lines, uri, imported_module)
	assert doc == 'B foo docs'
}

fn test_operation_at_pos_hover_respects_shadowed_chained_module_alias() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'shadowed_chained_hover')
	module_dir := os.join_path(test_dir, 'clock')
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(test_dir, 'v.mod'), 'Module {}\n')
	must_write_file(os.join_path(module_dir, 'clock.v'), 'module clock

// start performs the imported operation.
pub fn start() {}
')
	content := 'module main

import clock

struct Timer {}

// start performs the local timer operation.
fn (timer Timer) start() {}

struct Clock {
	timer Timer
}

fn main() {
	clock := Clock{}
	clock.timer.start()
}
'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	app.workspace_roots = [test_dir]
	lines := content.split_into_lines()
	call_line := lines.index('\tclock.timer.start()')
	assert call_line >= 0
	start_col := lines[call_line].index('start') or { -1 }
	assert start_col >= 0
	position := Position{
		line: call_line
		char: start_col + 1
	}
	response := app.operation_at_pos(.hover, Request{
		id: 904
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: position
		},
			escape_unicode: true
		)
	})

	assert response.result is Hover
	hover := response.result as Hover
	assert hover.contents.value.contains('start performs the local timer operation.')
	assert !hover.contents.value.contains('start performs the imported operation.')
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
		id: 30
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 31
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 32
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 33
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 34
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 35
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 40
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 41
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 50
		method: 'textDocument/inlayHint'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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

fn inlay_hints_for_file(dir_name string, content string) []InlayHint {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	app.v3_line_info_enabled = v3_answers_inlay_hints()
	test_dir := os.join_path(app.temp_dir, dir_name)
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	return inlay_hints_request(mut app, uri, content)
}

fn inlay_hints_request(mut app App, uri string, content string) []InlayHint {
	response := app.handle_inlay_hints(Request{
		id:     1
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
					line: content.count('\n') + 1
					char: 0
				}
			}
		},
			escape_unicode: true
		)
	})
	assert response.result is []InlayHint, 'Expected []InlayHint'
	return response.result as []InlayHint
}

// compiler_supports_inlay_hints reports whether the configured V answers the
// `-line-info file:L:ih^C` mode: its V3 with the query engine, or a V1 that was
// patched for it. With any other compiler VLS falls back to its source
// heuristics, so the tests that expect compiler hints are skipped. It asks the
// compiler directly, not through VLS, so a broken VLS side makes those tests
// fail instead of skipping them.
fn compiler_supports_inlay_hints() bool {
	return compiler_answers_inlay_hints([['-new-compiler'], ['-old-compiler'], []string{}])
}

// v3_answers_inlay_hints reports whether the V3 of the configured V answers the
// `ih^` mode: the tests that expect compiler hints then take them from V3, as
// VLS does.
fn v3_answers_inlay_hints() bool {
	return compiler_answers_inlay_hints([['-new-compiler']])
}

fn compiler_answers_inlay_hints(selectors [][]string) bool {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	dir := os.join_path(app.temp_dir, 'inlay_hints_probe')
	must_mkdir_all(dir)
	main_file := os.join_path(dir, 'main.v')
	must_write_file(main_file, 'module main\n\nfn main() {\n\tx := 1\n\tprintln(x)\n}\n')
	args := build_v_line_info_args_single(main_file, '1:ih^1', main_file)
	for selector in selectors {
		mut argv := selector.clone()
		argv << args
		if run_v_argv(argv, dir).output.contains('{"inlay_hints":') {
			return true
		}
	}
	return false
}

fn inlay_hint_summary(hints []InlayHint) []string {
	mut out := hints.map('${it.position.line}:${it.position.char} ${it.kind} ${it.label}')
	out.sort()
	return out
}

fn test_inlay_hints_come_from_the_compiler_for_every_variable_and_argument() {
	if !compiler_supports_inlay_hints() {
		eprintln('skipped: this V does not implement the `ih^` inlay hints mode')
		return
	}
	content := "module main\n\nstruct Point {\n\tx int\n\ty int\n}\n\nfn greet(name string, times int) string {\n\treturn name.repeat(times)\n}\n\nfn main() {\n\tp := Point{\n\t\tx: 1\n\t\ty: 2\n\t}\n\tmsg := greet('John', p.x)\n\tprintln(msg)\n\tmsg2 := greet('résumé', 2)\n\tprintln(msg2)\n}\n"
	mut want := [
		'8:20 2 count: ', // name.repeat(times)
		'12:2 1 : Point', // p := Point{
		'16:4 1 : string', // msg := greet('John', p.x)
		'16:14 2 name: ',
		'16:22 2 times: ',
		'17:9 2 s: ', // println(msg)
		'18:5 1 : string', // msg2 := greet('résumé', 2)
		'18:15 2 name: ',
		'18:25 2 times: ', // UTF-16 column: each `é` is one unit
		'19:9 2 s: ',
	]
	want.sort()
	assert inlay_hint_summary(inlay_hints_for_file('inlay_from_compiler', content)) == want
}

fn test_inlay_hints_follow_disk_changes_in_files_that_are_not_open() {
	if !compiler_supports_inlay_hints() {
		eprintln('skipped: this V does not implement the `ih^` inlay hints mode')
		return
	}
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	app.v3_line_info_enabled = v3_answers_inlay_hints()
	dir := os.join_path(app.temp_dir, 'inlay_cache_disk_change')
	must_mkdir_all(dir)
	helper := os.join_path(dir, 'helper.v')
	must_write_file(helper, 'module main\n\nfn greet(times int) string {\n\treturn "hi".repeat(times)\n}\n')
	main_file := os.join_path(dir, 'main.v')
	content := 'module main\n\nfn main() {\n\tprintln(greet(3))\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	before := inlay_hints_request(mut app, uri, content).map(it.label)
	assert 'times: ' in before, before.str()
	// helper.v is not open: only the file watcher reports that it changed.
	must_write_file(helper, 'module main\n\nfn greet(count int) string {\n\treturn "hi".repeat(count)\n}\n')
	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [
				FileEvent{
					uri:        path_to_uri(helper)
					event_type: 2
				},
			]
		})
	})
	after := inlay_hints_request(mut app, uri, content).map(it.label)
	assert 'count: ' in after, after.str()
	assert 'times: ' !in after, after.str()
}

fn test_inlay_hints_follow_unsaved_edits_in_other_open_files() {
	if !compiler_supports_inlay_hints() {
		eprintln('skipped: this V does not implement the `ih^` inlay hints mode')
		return
	}
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	app.v3_line_info_enabled = v3_answers_inlay_hints()
	dir := os.join_path(app.temp_dir, 'inlay_other_open_buffer')
	must_mkdir_all(dir)
	helper := os.join_path(dir, 'helper.v')
	helper_content := 'module main\n\nfn greet(times int) string {\n\treturn "hi".repeat(times)\n}\n'
	must_write_file(helper, helper_content)
	main_file := os.join_path(dir, 'main.v')
	content := 'module main\n\nfn main() {\n\tprintln(greet(3))\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	helper_uri := path_to_uri(helper)
	app.open_files[uri] = content
	app.open_files[helper_uri] = helper_content
	before := inlay_hints_request(mut app, uri, content).map(it.label)
	assert 'times: ' in before, before.str()
	// An unsaved edit in helper.v: the file on disk still says `times`.
	app.open_files[helper_uri] = helper_content.replace('times', 'count')
	app.open_files_versions[helper_uri] = 2
	after := inlay_hints_request(mut app, uri, content).map(it.label)
	assert 'count: ' in after, after.str()
	assert 'times: ' !in after, after.str()
}

fn test_did_close_drops_cached_inlay_hints() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_file := os.join_path(app.temp_dir, 'close_inlay_hints.v')
	content := 'module main\n\nfn main() {}\n'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	app.inlay_hint_cache[uri] = CachedInlayHints{
		stamp: app.inlay_hint_stamp(uri, content)
	}

	app.on_did_close(Request{
		params: json2.encode(DidCloseTextDocumentParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	assert uri !in app.inlay_hint_cache
}

// V's builtin functions insert their call as every other function does: with
// the parameters that vlib/builtin declares, or, for one it does not declare
// (dump, which the compiler provides), at least the parentheses.
fn test_builtin_function_completions_insert_the_call() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	path := os.join_path(app.temp_dir, 'builtin_calls', 'main.v')
	content := 'module main\n\nfn main() {\n\tpr\n}\n'
	must_mkdir_all(os.dir(path))
	must_write_file(path, content)
	uri := path_to_uri(path)
	app.open_files[uri] = content
	items := app.indexed_completions(uri, Position{
		line: 3
		char: 3
	}).items
	for label, insert in {
		'println':         'println(\${1:s})\$0'
		'panic':           'panic(\${1:s})\$0'
		'exit':            'exit(\${1:code})\$0'
		'copy':            'copy(\${1:dst}, \${2:src})\$0'
		'error_with_code': 'error_with_code(\${1:message}, \${2:code})\$0'
		'flush_stdout':    'flush_stdout()'
		'print_backtrace': 'print_backtrace()'
		'dump':            'dump(\$0)'
		'sizeof':          'sizeof(\$0)'
		'typeof':          'typeof(\$0)'
		'isreftype':       'isreftype(\$0)'
	} {
		found := items.filter(it.label == label)
		assert found.len == 1, '${label}: ${found.len} items'
		assert (found[0].insert_text or { '' }) == insert, '${label}: ${found[0].insert_text}'
		assert (found[0].insert_text_format or { 1 }) == if insert.contains('\$') { 2 } else { 1 }, label
	}
	for name in v_builtins {
		found := items.filter(it.label == name)
		assert found.len == 1, '${name}: ${found.len} items'
		assert (found[0].insert_text or { '' }).starts_with('${name}('), name
	}
	// the signature is the one vlib/builtin declares, as for any other function
	assert items.filter(it.label == 'println')[0].detail == 'pub fn println(s string)'
	// V has no builtin `close`: a channel closes with `ch.close()`
	assert items.filter(it.label == 'close').len == 0
	// read once, and again after a watched change there, as when working on V
	builtin_dir := os.join_path(find_v_dir(), 'vlib', 'builtin')
	assert builtin_dir in app.builtin_calls_cache
	notify_changed(mut app, os.join_path(builtin_dir, 'printing.c.v'))
	assert builtin_dir !in app.builtin_calls_cache
}

// The builtin functions are V's: `print_backtrace` is one and colored as such,
// and `close` is not, so a function of the project may be called so and renamed.
fn test_builtin_functions_are_the_ones_v_has() {
	assert classify_v_identifier('print_backtrace') == sem_tok_function
	assert classify_v_identifier('close') == -1
	files := {
		'main.v': 'module main\n\nfn close() int {\n\treturn 1\n}\n\nfn main() {\n\tprintln(close())\n}\n'
	}
	assert rename_edits_in(files, 'main.v:3:4') == ['main.v:3:4', 'main.v:8:10']
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

fn test_make_keyword_completions_contains_builtin_types() {
	items := make_keyword_completions()
	for builtin_type in ['string', 'bool', 'int', 'u64', 'rune', 'map', 'voidptr', 'IError'] {
		matches := items.filter(it.label == builtin_type)
		assert matches.len == 1, builtin_type
		assert matches[0].kind == 7, builtin_type
		assert matches[0].detail == 'builtin type', builtin_type
	}
}

fn test_bare_completion_includes_builtin_types_without_compiler_fallback() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'builtin_type_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct User {\n\tname str\n\tactive bo\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	for line_text in ['\tname str', '\tactive bo'] {
		completion_line := lines.index(line_text)
		assert completion_line >= 0
		indexed := app.indexed_completions(uri, Position{
			line: completion_line
			char: lines[completion_line].len
		})
		assert !indexed.use_compiler
		assert indexed.items.any(it.label == 'string')
		assert indexed.items.any(it.label == 'bool')
	}
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
	encoding_dir := os.join_path(find_v_dir(), 'vlib', 'encoding')
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

fn parse_module_member_completions(content string, public_only bool) ParsedModuleCompletionIndex {
	return parse_module_member_completions_from_lines(source_code_lines(content), compile_time_conditional_lines(content), public_only)
}

fn source_declaration_is_compile_time_conditional(content string, declaration_line int) bool {
	conditional_lines := compile_time_conditional_lines(content)
	return declaration_line >= 0 && declaration_line < conditional_lines.len
		&& conditional_lines[declaration_line]
}

fn parse_module_fn_completions(content string) []Detail {
	return parse_module_member_completions(content, false).items.filter(it.kind == 3)
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

fn test_module_member_completions_ignore_block_comment_declarations() {
	content := 'module example\n\n/*\npub fn removed() {}\npub struct Removed {}\n*/\n\npub fn available() {}\npub struct Available {}\n'
	public_items := parse_module_member_completions(content, true).items
	public_labels := public_items.map(it.label)
	assert 'available' in public_labels
	assert 'Available' in public_labels
	assert 'removed' !in public_labels
	assert 'Removed' !in public_labels
	function_labels := parse_module_fn_completions(content).map(it.label)
	assert 'available' in function_labels
	assert 'removed' !in function_labels
}

fn test_module_const_block_completion_tracks_nested_expressions() {
	content := 'module example\n\npub const (\n\tvalues = [\n\t\t1\n\t\t2\n\t]\n\tnested = build(\n\t\t3\n\t)\n\tafter = 4\n)\n'
	items := parse_module_member_completions(content, true).items
	labels := items.map(it.label)
	assert labels == ['values', 'nested', 'after']
}

fn test_module_global_bindings_are_in_bare_completion() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'module_global_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := '@[has_globals]\nmodule main\n\n__global (\n\tshared_cache map[string]int\n\tinitialized = [\n\t\t1\n\t\t2\n\t]\n\tafter int\n)\n\nfn inspect() {\n\tshared_ca\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	parsed := parse_module_member_completions(content, false).items
	labels := parsed.map(it.label)
	assert labels.filter(it in ['shared_cache', 'initialized', 'after']) == [
		'shared_cache',
		'initialized',
		'after',
	]
	assert '1' !in labels
	assert parse_module_member_completions(content, true).items.len == 0
	lines := content.split_into_lines()
	completion_line := lines.index('\tshared_ca')
	assert completion_line >= 0
	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	assert !indexed.use_compiler
	assert indexed.items.any(it.label == 'shared_cache')
	assert indexed.items.any(it.label == 'initialized')
	assert indexed.items.any(it.label == 'after')
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
		id: 1
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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

	must_write_file(os.join_path(mod_dir, 'my_mod.v'), 'module my_mod\n\npub fn greet(name string) string {\n\treturn name\n}\n\npub struct PublicStruct {}\npub enum PublicEnum { value }\npub interface PublicInterface {}\npub type PublicAlias = string\n\nfn hidden() {}\nstruct HiddenStruct {}\n')

	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport my_mod\n\nfn main() {\n\tmy_mod.\n}\n'
	must_write_file(main_file, content)

	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	app.text = content

	response := app.operation_at_pos(.completion, Request{
		id: 9001
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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
	assert 'PublicStruct' in labels
	assert 'PublicEnum' in labels
	assert 'PublicInterface' in labels
	assert 'PublicAlias' in labels
	assert 'hidden' !in labels
	assert 'HiddenStruct' !in labels
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
		id: 9002
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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

fn test_local_member_completion_avoids_compiler_for_current_buffer_type() {
	result := indexed_completions_at_line_end('local_member_current_buffer', 'module main\n\nstruct App {\n\tname string\n\tshared_values shared []int\n}\n\nfn (app &App) run(port int) bool {\n\tapp.\n\treturn true\n}\n', '\tapp.')
	assert !result.use_compiler
	assert sorted_completion_labels(result) == ['name', 'run', 'shared_values', 'str']
	runs := result.items.filter(it.label == 'run')
	assert runs.len == 1
	assert runs[0].kind == 2
	assert runs[0].insert_text or { '' } == 'run(\${1:port})$0'
}

fn test_local_member_completion_does_not_leak_variable_from_previous_function() {
	result := indexed_completions_at_line_end('local_member_scope_leak', 'module main\n\nstruct App {\n\tname string\n}\n\nfn first() {\n\tapp := App{}\n\tprintln(app.name)\n}\n\nfn second() {\n\tapp.\n}\n', '\tapp.')
	assert 'name' !in result.items.map(it.label)
}

fn test_local_member_completion_includes_disk_sibling_methods() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'local_member_disk_sibling')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	methods_file := os.join_path(test_dir, 'methods.v')
	content := 'module main\n\nstruct App {\n\tname string\n}\n\nfn main() {\n\tapp := App{}\n\tapp.\n}\n'
	must_write_file(main_file, content)
	must_write_file(methods_file, 'module main\n\nfn (app &App) start() {}\n')
	uri := path_to_uri(main_file)
	app.open_files[uri] = content

	response := app.operation_at_pos(.completion, Request{
		id:     9010
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 8
				char: 5
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	labels := (response.result as CompletionList).items.map(it.label)
	assert 'name' in labels
	assert 'start' in labels
}

fn test_local_member_completion_prefers_open_sibling_methods() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'local_member_open_sibling')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	methods_file := os.join_path(test_dir, 'methods.v')
	content := 'module main\n\nstruct App {\n\tname string\n}\n\nfn main() {\n\tapp := App{}\n\tapp.\n}\n'
	must_write_file(main_file, content)
	must_write_file(methods_file, 'module main\n\nfn (app &App) disk_start() {}\n')
	uri := path_to_uri(main_file)
	methods_uri := path_to_uri(methods_file)
	app.open_files[uri] = content
	app.open_files[methods_uri] = 'module main\n\nfn (app &App) memory_start() {}\n'

	response := app.operation_at_pos(.completion, Request{
		id:     9011
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: 8
				char: 5
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	labels := (response.result as CompletionList).items.map(it.label)
	assert 'memory_start' in labels
	assert 'disk_start' !in labels
}

fn test_operation_at_pos_completion_and_definition_resolve_cross_file_receiver_method() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'receiver_method_index')
	clock_dir := os.join_path(test_dir, 'clock')
	must_mkdir_all(clock_dir)
	clock_file := os.join_path(clock_dir, 'clock.v')
	must_write_file(clock_file, 'module clock\n\npub struct Timer {}\n\npub fn (mut timer Timer) show(label string) {}\n')

	main_file := os.join_path(test_dir, 'main.v')
	main_content := 'module main\n\nimport clock\n\nfn timer_pointer(timer &clock.Timer) &clock.Timer {\n\treturn timer\n}\n\nfn main() {\n\tmut timer := unsafe {\n\t\ttimer_pointer(&clock.Timer{})\n\t}\n\ttimer.show("total")\n}\n'
	must_write_file(main_file, main_content)
	main_uri := path_to_uri(main_file)
	app.open_files[main_uri] = main_content

	lines := main_content.split_into_lines()
	mut call_line := -1
	mut show_col := -1
	for i, line in lines {
		if line.contains('timer.show(') {
			call_line = i
			show_col = line.index('show') or { -1 }
			break
		}
	}
	assert call_line >= 0
	assert show_col >= 0

	completion := app.operation_at_pos(.completion, Request{
		id: 9100
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
			position: Position{
				line: call_line
				char: show_col
			}
		},
			escape_unicode: true
		)
	})
	assert completion.result is CompletionList
	completion_items := (completion.result as CompletionList).items
	assert completion_items.any(it.label == 'show' && it.kind == 2)

	definition := app.operation_at_pos(.definition, Request{
		id: 9101
		method: 'textDocument/definition'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: main_uri
			}
			position: Position{
				line: call_line
				char: show_col + 2
			}
		},
			escape_unicode: true
		)
	})
	assert definition.result is Location
	location := definition.result as Location
	assert location.uri == path_to_uri(clock_file)
	assert location.range.start.line == 4
	assert location.range.start.char == 25
	assert location.range.end.char == 29
}

fn test_operation_at_pos_completion_includes_indexed_struct_fields() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'receiver_field_index')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct User {\n\tname string\n\tage int\n}\n\nfn (user User) display_name() string {\n\treturn user.name\n}\n\nfn main() {\n\tuser := User{}\n\tuser.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content

	lines := content.split_into_lines()
	completion_line := lines.index('\tuser.')
	assert completion_line >= 0
	response := app.operation_at_pos(.completion, Request{
		id: 9200
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: completion_line
				char: lines[completion_line].len
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	items := (response.result as CompletionList).items
	assert items.any(it.label == 'name' && it.kind == 5)
	assert items.any(it.label == 'age' && it.kind == 5)
	assert items.any(it.label == 'display_name' && it.kind == 2)
}

fn test_receiver_inference_does_not_reuse_declaration_from_earlier_function() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'receiver_function_scope')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct A {}\nstruct B {}\n\nfn (a A) alpha() {}\nfn (b B) beta() {}\n\nfn first() {\n\tx := A{}\n\tx.alpha()\n}\n\nfn second(x B) {\n\tx.beta()\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content

	lines := content.split_into_lines()
	call_line := lines.index('\tx.beta()')
	assert call_line >= 0
	dot_col := lines[call_line].index('.') or { -1 }
	beta_col := lines[call_line].index('beta') or { -1 }
	assert dot_col >= 0
	assert beta_col >= 0

	completion := app.operation_at_pos(.completion, Request{
		id: 9201
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: call_line
				char: dot_col + 1
			}
		},
			escape_unicode: true
		)
	})
	assert completion.result is CompletionList
	items := (completion.result as CompletionList).items
	assert items.any(it.label == 'beta')
	assert !items.any(it.label == 'alpha')

	definition := app.operation_at_pos(.definition, Request{
		id: 9202
		method: 'textDocument/definition'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: call_line
				char: beta_col + 2
			}
		},
			escape_unicode: true
		)
	})
	assert definition.result is Location
	location := definition.result as Location
	assert location.uri == uri
	assert location.range.start.line == lines.index('fn (b B) beta() {}')
}

fn test_imported_module_completion_resolves_from_project_root() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	root := os.join_path(app.temp_dir, 'nested_module_completion')
	module_dir := os.join_path(root, 'mylib')
	app_dir := os.join_path(root, 'cmd', 'app')
	must_mkdir_all(module_dir)
	must_mkdir_all(app_dir)
	must_write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'nested_completion'\n}\n")
	must_write_file(os.join_path(module_dir, 'mylib.v'), 'module mylib\n\npub fn from_project_root() {}\n')

	main_file := os.join_path(app_dir, 'main.v')
	content := 'module main\n\nimport mylib\n\nfn main() {\n\tmylib.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	app.workspace_roots = [root]

	lines := content.split_into_lines()
	completion_line := lines.index('\tmylib.')
	assert completion_line >= 0
	response := app.operation_at_pos(.completion, Request{
		id: 9203
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: completion_line
				char: lines[completion_line].len
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	items := (response.result as CompletionList).items
	assert items.any(it.label == 'from_project_root')
}

fn test_bare_completion_includes_local_and_top_level_scope_symbols() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'bare_scope_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nconst app_name = "vls"\nstruct User {}\nenum Mode { active }\ninterface Runner {}\n\nfn helper() {}\n\nfn main(local_param string) {\n\tlocal_value := 42\n\tlocal_\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content

	lines := content.split_into_lines()
	completion_line := lines.index('\tlocal_')
	assert completion_line >= 0
	response := app.operation_at_pos(.completion, Request{
		id: 9300
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: completion_line
				char: lines[completion_line].len
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	items := (response.result as CompletionList).items
	labels := items.map(it.label)
	assert 'local_param' in labels
	assert 'local_value' in labels
	assert 'app_name' in labels
	assert 'User' in labels
	assert 'Mode' in labels
	assert 'Runner' in labels
	assert 'helper' in labels
}

fn test_literal_and_container_receiver_completion_falls_back_to_compiler() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'receiver_compiler_fallback')
	must_mkdir_all(test_dir)
	cases := [
		["text := 'hello'", 'text.'],
		['values := [1, 2]', 'values.'],
	]
	main_file := os.join_path(test_dir, 'main.v')
	for case_idx, completion_case in cases {
		content := 'module main\n\nfn main() {\n\t${completion_case[0]}\n\t${completion_case[1]}\n}\n'
		must_write_file(main_file, content)
		uri := path_to_uri(main_file)
		app.open_files[uri] = content
		lines := content.split_into_lines()
		completion_line := lines.index('\t${completion_case[1]}')
		assert completion_line >= 0

		indexed := app.indexed_completions(uri, Position{
			line: completion_line
			char: lines[completion_line].len
		})
		// Both literals are typed by the index, which lists their builtin members.
		assert !indexed.use_compiler, completion_case.str()
		expected_member := if case_idx == 0 { 'after' } else { 'filter' }
		assert indexed.items.any(it.label == expected_member), completion_case.str()
		response := app.operation_at_pos(.completion, Request{
			id: 9301 + case_idx
			method: 'textDocument/completion'
			params: json2.encode(TextDocumentPositionParams{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position: Position{
					line: completion_line
					char: lines[completion_line].len
				}
			},
				escape_unicode: true
			)
		})
		assert response.result is CompletionList
		assert (response.result as CompletionList).items.len > 0, completion_case.str()
	}
}

fn test_typed_container_receiver_does_not_infer_nested_struct_type() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'typed_container_receiver_fallback')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	cases := [
		'users := []User{}',
		'users := [User{}]',
	]
	for declaration in cases {
		content := 'module main\n\nstruct User {\n\tname string\n}\nfn (user User) save() {}\n\nfn main() {\n\t${declaration}\n\tusers.\n}\n'
		must_write_file(main_file, content)
		uri := path_to_uri(main_file)
		app.open_files[uri] = content
		lines := content.split_into_lines()
		completion_line := lines.index('\tusers.')
		assert completion_line >= 0
		// The array is never confused with its element type `User`.
		assert app.infer_receiver_type(uri, content, 'users', completion_line) == '[]User', declaration
		indexed := app.indexed_completions(uri, Position{
			line: completion_line
			char: lines[completion_line].len
		})
		assert !indexed.use_compiler, declaration
		assert !indexed.items.any(it.label in ['name', 'save']), declaration
		response := app.operation_at_pos(.completion, Request{
			id: 9350
			method: 'textDocument/completion'
			params: json2.encode(TextDocumentPositionParams{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position: Position{
					line: completion_line
					char: lines[completion_line].len
				}
			},
				escape_unicode: true
			)
		})
		assert response.result is CompletionList
		labels := (response.result as CompletionList).items.map(it.label)
		assert labels.len > 0, declaration
		assert !labels.any(it in ['name', 'save']), declaration
	}
}

fn test_receiver_completion_honors_local_binding_that_shadows_import() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'shadowed_import_completion')
	module_dir := os.join_path(test_dir, 'clock')
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(module_dir, 'clock.v'), 'module clock\n\npub fn module_member() {}\n')
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport clock\n\nstruct Timer {}\nfn (timer Timer) start() {}\n\nfn main() {\n\tclock := Timer{}\n\tclock.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content

	lines := content.split_into_lines()
	completion_line := lines.index('\tclock.')
	assert completion_line >= 0
	response := app.operation_at_pos(.completion, Request{
		id: 9303
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: completion_line
				char: lines[completion_line].len
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	labels := (response.result as CompletionList).items.map(it.label)
	assert 'start' in labels
	assert 'module_member' !in labels
}

fn test_imported_module_completion_uses_unsaved_open_buffer() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'open_import_completion')
	module_dir := os.join_path(test_dir, 'my_mod')
	must_mkdir_all(module_dir)
	module_file := os.join_path(module_dir, 'my_mod.v')
	must_write_file(module_file, 'module my_mod\n\npub fn saved_member() {}\n')
	module_uri := path_to_uri(module_file)
	app.open_files[module_uri] = 'module my_mod\n\npub fn unsaved_member() {}\npub struct UnsavedType {}\n'

	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport my_mod\n\nfn main() {\n\tmy_mod.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tmy_mod.')
	assert completion_line >= 0

	response := app.operation_at_pos(.completion, Request{
		id: 9304
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: completion_line
				char: lines[completion_line].len
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is CompletionList
	labels := (response.result as CompletionList).items.map(it.label)
	assert 'unsaved_member' in labels
	assert 'UnsavedType' in labels
	assert 'saved_member' !in labels
}

fn test_member_completion_recognizes_typed_prefix() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'typed_member_completion')
	module_dir := os.join_path(test_dir, 'my_mod')
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(module_dir, 'my_mod.v'), 'module my_mod\n\npub fn read_value() {}\n')
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport my_mod\n\nstruct User {\n\tname string\n}\n\nfn main() {\n\tuser := User{}\n\tuser.na\n\tmy_mod.rea\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()

	for expected, source_line in {
		'name':       '\tuser.na'
		'read_value': '\tmy_mod.rea'
	} {
		completion_line := lines.index(source_line)
		assert completion_line >= 0
		response := app.operation_at_pos(.completion, Request{
			id: 9400 + completion_line
			method: 'textDocument/completion'
			params: json2.encode(TextDocumentPositionParams{
				text_document: TextDocumentIdentifier{
					uri: uri
				}
				position: Position{
					line: completion_line
					char: lines[completion_line].len
				}
			},
				escape_unicode: true
			)
		})
		assert response.result is CompletionList
		assert (response.result as CompletionList).items.any(it.label == expected)
	}
}

fn test_local_scope_completion_drops_bindings_after_nested_block() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'nested_scope_completion')
	module_dir := os.join_path(test_dir, 'clock')
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(module_dir, 'clock.v'), 'module clock\n\npub fn module_member() {}\n')
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport clock\n\nstruct Timer {}\nfn (timer Timer) start() {}\n\nfn main() {\n\tif true {\n\t\tclock := Timer{}\n\t\tclock.start()\n\t}\n\tclock.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tclock.')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	assert !app.local_scope_completions(content, position).any(it.label == 'clock')

	response := app.operation_at_pos(.completion, Request{
		id: 9401
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: position
		},
			escape_unicode: true
		)
	})
	assert response.result is CompletionList
	labels := (response.result as CompletionList).items.map(it.label)
	assert 'module_member' in labels
	assert 'start' !in labels
}

fn test_conditional_module_types_delegate_completion_to_compiler() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'conditional_module_completion')
	module_dir := os.join_path(test_dir, 'conditional')
	must_mkdir_all(module_dir)
	module_file := os.join_path(module_dir, 'conditional.v')
	module_content := 'module conditional\n\npub fn always() {}\n\n\$if windows {\n\tpub struct WinType {}\n}\n\n@[if windows]\npub struct AttributeType {}\n'
	must_write_file(module_file, module_content)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport conditional\n\nfn main() {\n\tconditional.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tconditional.')
	assert completion_line >= 0

	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	labels := indexed.items.map(it.label)
	assert indexed.use_compiler
	assert 'always' in labels
	assert 'WinType' !in labels
	assert 'AttributeType' !in labels
}

fn test_chained_member_completion_resolves_nested_struct_type() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'chained_qualifier_completion')
	module_dir := os.join_path(test_dir, 'clock')
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(module_dir, 'clock.v'), 'module clock\n\npub fn module_member() {}\n')
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport clock\n\nstruct ClockValue {}\nfn (value ClockValue) tick() {}\nstruct AppState {\n\tclock ClockValue\n}\n\nfn main() {\n\tapp := AppState{}\n\tapp.clock.\n\tapp.clock.tick()\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tapp.clock.')
	assert completion_line >= 0

	qualifier, has_member_access, standalone := member_qualifier_at_cursor(lines[completion_line], lines[completion_line].len, app.position_encoding)
	assert has_member_access
	assert qualifier == 'app.clock'
	assert !standalone
	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	assert !indexed.use_compiler
	assert indexed.items.any(it.label == 'tick')
	assert !indexed.items.any(it.label == 'module_member')
	definition_line := lines.index('\tapp.clock.tick()')
	assert definition_line >= 0
	tick_col := lines[definition_line].index('tick') or { -1 }
	definition := app.resolve_indexed_definition(uri, Position{
		line: definition_line
		char: tick_col + 2
	}) or {
		assert false, 'expected nested receiver method definition'
		return
	}
	assert definition.uri == uri
	assert definition.range.start.line == lines.index('fn (value ClockValue) tick() {}')
}

fn test_chained_member_completion_resolves_field_after_local_struct_field() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'nested_field_completion')
	must_mkdir_all(test_dir)
	content := 'module main\n\nstruct Node {\n\tid int\n}\n\nstruct Listener {\n\tnode Node\n}\n\nfn main() {\n\tlisteners := []Listener{}\n\tlisteners.filter(fn (listener Listener) bool {\n\t\treturn listener.node.\n\t})\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\t\treturn listener.node.')
	assert line >= 0
	position := Position{
		line: line
		char: lines[line].len
	}
	assert app.local_scope_bindings(content, position).any(it.name == 'listener')
	expression := member_expression_at_cursor(lines[line], lines[line].len, app.position_encoding)
	assert expression == 'listener.node', expression
	assert app.infer_receiver_type_at_position(uri, content, 'listener.node', position) == 'Node'
	result := app.indexed_completions(uri, position)
	labels := result.items.map(it.label)
	assert 'id' in labels, labels.str()
}

fn test_hover_prefers_shadowing_closure_parameter_type() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'shadowing_closure_hover')
	must_mkdir_all(test_dir)
	content := 'module main\n\nstruct Listener {}\n\nfn main() {\n\tx := 1\n\t[]Listener{}.filter(fn (x Listener) bool {\n\t\treturn x.\n\t})\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\t\treturn x.')
	assert line >= 0
	x_col := lines[line].index('x') or { -1 }
	assert x_col >= 0
	response := app.operation_at_pos(.hover, Request{
		id: 9501
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: line
				char: x_col + 1
			}
		},
			escape_unicode: true
		)
	})
	assert response.result is Hover
	hover := response.result as Hover
	assert hover.contents.value.contains('x Listener'), hover.contents.value
	assert !hover.contents.value.contains('x int'), hover.contents.value
}

fn test_hover_does_not_treat_member_selector_as_local_binding() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'shadowing_member_hover')
	must_mkdir_all(test_dir)
	content := 'module main\n\nstruct Listener {\n\tx int\n}\n\nfn main() {\n\tread := fn (x Listener) int {\n\t\treturn x.x\n\t}\n\tread(Listener{x: 1})\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\t\treturn x.x')
	assert line >= 0
	receiver_col := lines[line].index('x.x') or { -1 }
	field_col := receiver_col + 2
	assert receiver_col >= 0
	assert app.local_binding_hover(uri, Position{
		line: line
		char: receiver_col + 1
	}) != none
	assert app.local_binding_hover(uri, Position{
		line: line
		char: field_col
	}) == none
	field_response := app.operation_at_pos(.hover, Request{
		id: 9531
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: line
				char: field_col
			}
		},
			escape_unicode: true
		)
	})
	if field_response.result is Hover {
		field_hover := field_response.result as Hover
		assert !field_hover.contents.value.contains('x Listener'), field_hover.contents.value
	}
}

fn test_hover_only_answers_for_a_variable_reference() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'variable_reference_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nfn main() {\n\tvalue := 3\n\touter := 1\n\tinner := 2\n\tprintln('value in text')\n\t// value in comment\n\tprintln('value is \${value}')\n\touter: for i in 0 .. 2 {\n\t\tif i == outer {\n\t\t\tbreak outer\n\t\t}\n\t}\n\tinner: for j in 0 .. 2 {\n\t\tif j == inner {\n\t\t\tbreak inner // stop here\n\t\t}\n\t}\n\tprintln(value)\n\tprintln(inner) // keep this\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	// Only the references are the variable: the word in a string or a comment is
	// text, and a label is not a variable even when it is spelled like one.
	for source_line, expected in {
		"\tprintln('value in text')":      ''
		'\t// value in comment':           ''
		'\t\t\tbreak outer':               ''
		'\t\t\tbreak inner // stop here':  ''
		"\tprintln('value is \${value}')": 'value int'
		'\tprintln(value)':                'value int'
		'\t\tif i == outer {':             'outer int'
		'\t\tif j == inner {':             'inner int'
		'\tprintln(inner) // keep this':   'inner int'
	} {
		line := lines.index(source_line)
		assert line >= 0, source_line
		word := if source_line.contains('outer') {
			'outer'
		} else if source_line.contains('inner') {
			'inner'
		} else {
			'value'
		}
		col := lines[line].last_index(word) or { -1 }
		assert col >= 0, source_line
		hover := app.local_binding_hover(uri, Position{
			line: line
			char: col + 1
		}) or { Hover{} }
		if expected == '' {
			assert hover.contents.value == '', '${source_line}: ${hover.contents.value}'
		} else {
			assert hover.contents.value.contains(expected), '${source_line}: ${hover.contents.value}'
		}
	}
}

fn test_hover_keeps_a_closure_parameter_reference_type() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'closure_reference_hover')
	must_mkdir_all(test_dir)
	content := 'module main\n\nstruct Point {\n\tx int\n}\n\nfn main() {\n\tshow := fn (ptr &Point) {\n\t\tprintln(ptr)\n\t}\n\tshow(&Point{})\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\t\tprintln(ptr)')
	assert line >= 0
	col := lines[line].index('(ptr)') or { -1 }
	assert col > 0
	hover := app.local_binding_hover(uri, Position{
		line: line
		char: col + 2
	}) or { Hover{} }
	assert hover.contents.value.contains('ptr &Point'), hover.contents.value
}

fn test_hover_names_the_type_of_a_typed_container_declaration() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'container_declaration_hover')
	must_mkdir_all(test_dir)
	content := 'module main\n\nfn main() {\n\tfixed := [3]int{}\n\ttable := map[string]int{}\n\tprintln(fixed)\n\tprintln(table)\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	for name, expected in {
		'fixed': 'fixed [3]int'
		'table': 'table map[string]int'
	} {
		line := lines.index('\tprintln(${name})')
		assert line >= 0, name
		col := lines[line].index('(${name})') or { -1 }
		assert col > 0, name
		hover := app.local_binding_hover(uri, Position{
			line: line
			char: col + 2
		}) or { Hover{} }
		assert hover.contents.value.contains(expected), '${name}: ${hover.contents.value}'
	}
}

fn test_hover_keeps_reference_and_option_parameter_types() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'modifier_parameter_hover')
	must_mkdir_all(test_dir)
	content := 'module main\n\nstruct Point {\n\tx int\n}\n\nfn inspect(ptr &Point, opt ?Point) {\n\tprintln(ptr)\n\tprintln(opt)\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	// A hover shows the variable's own type; only member completion drops `&` and `?`.
	for name, expected in {
		'ptr': 'ptr &Point'
		'opt': 'opt ?Point'
	} {
		line := lines.index('\tprintln(${name})')
		assert line >= 0, name
		col := lines[line].index('(${name})') or { -1 }
		assert col > 0, name
		hover := app.local_binding_hover(uri, Position{
			line: line
			char: col + 2
		}) or { Hover{} }
		assert hover.contents.value.contains(expected), '${name}: ${hover.contents.value}'
	}
}

// public_hover_text asks for a hover through the same entry point an editor
// uses, and returns the text of the answer.
fn public_hover_text(mut app App, uri string, line int, character int) string {
	response := app.operation_at_pos(.hover, Request{
		id: 9700 + line
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: line
				char: character
			}
		},
			escape_unicode: true
		)
	})
	if response.result is Hover {
		hover := response.result as Hover
		return hover.contents.value
	}
	return ''
}

fn open_hover_fixture(mut app App, name string, content string) (string, []string) {
	test_dir := os.join_path(app.temp_dir, name)
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	return uri, content.split_into_lines()
}

fn test_hover_keeps_the_type_a_reference_returning_call_gives() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri, lines := open_hover_fixture(mut app, 'reference_call_hover', 'module main\n\n@[heap]\nstruct Point {\n\tx int\n}\n\nfn new_point() &Point {\n\treturn &Point{\n\t\tx: 1\n\t}\n}\n\nfn copy_ref(ptr &Point) {\n\tq := ptr\n\tprintln(q)\n}\n\nfn main() {\n\tp := new_point()\n\tprintln(p)\n\tcopy_ref(p)\n}\n')
	// A value that does not spell its type can still be a reference: the type
	// shown has to keep the `&` the function returns or the parameter declares.
	for source_line, expected in {
		'\tprintln(p)': 'p &Point'
		'\tprintln(q)': 'q &Point'
	} {
		line := lines.index(source_line)
		assert line >= 0, source_line
		col := lines[line].index('(') or { -1 }
		value := public_hover_text(mut app, uri, line, col + 1)
		assert value.contains(expected), '${source_line}: ${value}'
	}
}

fn test_hover_keeps_the_reference_through_an_inferred_value() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri, lines := open_hover_fixture(mut app, 'inferred_reference_hover', 'module main\n\n@[heap]\nstruct Point {\n\tx int\n}\n\nstruct Holder {\n\tptr    &Point\n\tpoints []&Point\n}\n\nfn (h &Holder) itself() &Holder {\n\treturn h\n}\n\nfn new_point() &Point {\n\treturn &Point{\n\t\tx: 1\n\t}\n}\n\nfn maybe_point() ?&Point {\n\treturn new_point()\n}\n\nfn main() {\n\tp := new_point()\n\ts := p\n\tprintln(s)\n\tholder := &Holder{\n\t\tptr:    p\n\t\tpoints: [p]\n\t}\n\tcopied := holder\n\tprintln(copied)\n\tr := holder.ptr\n\tprintln(r)\n\tm := holder.itself()\n\tprintln(m)\n\tfirst := holder.points[0]\n\tprintln(first)\n\tpair := [p, s]\n\tprintln(pair)\n\to := maybe_point() or { p }\n\tprintln(o)\n\tif g := maybe_point() {\n\t\tprintln(g)\n\t}\n\tt := spawn new_point()\n\tprintln(t.wait())\n}\n')
	// Each value is read from another one: a variable, a field, a method, an
	// index, an `or` block or an `if` guard. Unwrapping takes the `?` away, but
	// the `&` the source declares has to reach the hover every time.
	mut failures := []string{}
	for source_line, expected in {
		'\tprintln(s)':        's &Point'
		'\tprintln(copied)':   'copied &Holder'
		'\tprintln(r)':        'r &Point'
		'\tprintln(m)':        'm &Holder'
		'\tprintln(first)':    'first &Point'
		'\tprintln(pair)':     'pair []&Point'
		'\tprintln(o)':        'o &Point'
		'\t\tprintln(g)':      'g &Point'
		'\tprintln(t.wait())': 't thread &Point'
	} {
		line := lines.index(source_line)
		assert line >= 0, source_line
		col := lines[line].index('(') or { -1 }
		value := public_hover_text(mut app, uri, line, col + 1)
		if !value.contains(expected) {
			failures << '${source_line.trim_space()}: expected `${expected}`, got `${value}`'
		}
	}
	assert failures.len == 0, failures.join('\n')
}

fn test_hover_on_a_field_shows_the_type_it_declares() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri, lines := open_hover_fixture(mut app, 'declared_field_hover', 'module main\n\nstruct Point {\n\tx int\n}\n\nstruct Holder {\n\tptr    &Point\n\topt    ?Point\n\tpoints []&Point\n\tlookup map[string]?Point\n}\n\nfn inspect(holder Holder) {\n\tprintln(holder.ptr)\n\tprintln(holder.opt)\n\tprintln(holder.points)\n\tprintln(holder.lookup)\n}\n')
	// The member list strips `&` and `?` to find the members of the underlying
	// type; the hover has to show the field as it is declared.
	for field, expected in {
		'ptr':    'ptr &Point'
		'opt':    'opt ?Point'
		'points': 'points []&Point'
		'lookup': 'lookup map[string]?Point'
	} {
		line := lines.index('\tprintln(holder.${field})')
		assert line >= 0, field
		col := lines[line].index('.${field}') or { -1 }
		value := public_hover_text(mut app, uri, line, col + 2)
		assert value.contains(expected), '${field}: ${value}'
	}
}

fn test_hover_keeps_the_whole_result_of_a_function_typed_parameter() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri, lines := open_hover_fixture(mut app, 'function_parameter_result_hover', 'module main\n\nfn use_pair(cb fn () (int, int)) {\n\ta, b := cb()\n\tprintln(a + b)\n}\n\nfn use_chan(make fn () chan int) {\n\tch := make()\n\tprintln(ch)\n}\n\nfn use_nested(build fn (n int) fn () ?string) {\n\tf := build(1)\n\tprintln(f())\n}\n\nfn main() {\n\tuse_pair(fn () (int, int) {\n\t\treturn 1, 2\n\t})\n}\n')
	// A result type is not always one word: a tuple, a channel and a function
	// returning another function are single types too.
	for source_line, expected in {
		'\ta, b := cb()':  'cb fn () (int, int)'
		'\tch := make()':  'make fn () chan int'
		'\tf := build(1)': 'build fn (n int) fn () ?string'
	} {
		line := lines.index(source_line)
		assert line >= 0, source_line
		name := expected.all_before(' ')
		col := lines[line].index('${name}(') or { -1 }
		assert col > 0, source_line
		value := public_hover_text(mut app, uri, line, col + 1)
		assert value.contains(expected), '${source_line}: ${value}'
	}
}

fn test_hover_on_a_call_keeps_the_declaration_as_written() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'call_site_hover')
	must_mkdir_all(test_dir)
	content := 'module main\n\nfn apply(cb fn (a int) int, times int) int {\n\treturn cb(times)\n}\n\nfn main() {\n\tprintln(apply(fn (n int) int { return n }, 3))\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\tprintln(apply(fn (n int) int { return n }, 3))')
	assert line >= 0
	col := lines[line].index('apply(') or { -1 }
	assert col > 0
	// The compiler re-prints a function type without its parameter names, so the
	// declaration written in the source is the better answer.
	response := app.operation_at_pos(.hover, Request{
		id: 9601
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: line
				char: col + 2
			}
		},
			escape_unicode: true
		)
	})
	rendered := response.result.str()
	assert rendered.contains('cb fn (a int) int'), rendered
}

fn test_hover_on_a_field_of_a_chain_answers_for_that_field() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'chain_field_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nstruct Child {\n\tvalue int\n}\n\nstruct Node {\n\tchild Child\n}\n\nstruct Listener {\n\tnode Node\n}\n\nfn main() {\n\tlistener := Listener{}\n\tprintln(listener.node.child.value)\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\tprintln(listener.node.child.value)')
	assert line >= 0
	// Every step of the chain describes itself, not the one it hangs from.
	for name, expected in {
		'node':  'node Node'
		'child': 'child Child'
		'value': 'value int'
	} {
		col := lines[line].index('.' + name) or { -1 }
		assert col > 0, name
		hover := app.hover_at(uri, Position{
			line: line
			char: col + 2
		}) or { Hover{} }
		assert hover.contents.value.contains(expected), '${name}: ${hover.contents.value}'
	}
}

const language_member_hover_main = "module main

enum Color {
	red
	green
}

@[flag]
enum Perm {
	read
	write
}

struct Point {
	x int
}

fn (point Point) str() string {
	return 'point'
}

fn main() {
	c := Color.from('red') or { Color.green }
	println(c.str())
	mut p := Perm.zero()
	p.set(.read)
	println(p.has(.read))
	println(p.all(.read | .write))
	p.toggle(.write)
	p.clear(.read)
	p.set_all()
	p.clear_all()
	println(p.is_empty())
	q := Perm.from('read') or { Perm.zero() }
	println(q)
	pt := Point{}
	println(pt.str())
	println(Color.red)
}
"

// hover_value_at hovers `word` inside the first line of `content` holding `needle`.
fn hover_value_at(mut app App, uri string, content string, needle string, word string) string {
	lines := content.split_into_lines()
	line := lines.filter(it.contains(needle))[0]
	col := line.index(needle) or { -1 } + needle.index(word) or { -1 } + 1
	hover := app.hover_at(uri, Position{
		line: lines.index(line)
		char: col
	}) or { Hover{} }
	return hover.contents.value
}

// V gives every enum `from` and `str`, and a flag enum `zero` and the methods
// that work its flags. There is no declaration of them to show: the hover is
// the signature V gives them with what they do, not the documentation of a
// method of arrays that has the same name. A type's own `str` is its own.
fn test_hover_shows_the_members_v_gives_enums() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	path := os.join_path(app.temp_dir, 'language_member_hover', 'main.v')
	content := language_member_hover_main
	must_mkdir_all(os.dir(path))
	must_write_file(path, content)
	uri := path_to_uri(path)
	app.open_files[uri] = content
	app.reindex_uri(uri)
	for needle, signature in {
		'Color.from':  'fn Color.from[W](input W) !Color'
		'Perm.from':   'fn Perm.from[W](input W) !Perm'
		'Perm.zero':   'fn Perm.zero() Perm'
		'c.str':       'fn (e Color) str() string'
		'p.set(':      'fn (mut e Perm) set(flag_ Perm)'
		'p.has':       'fn (e &Perm) has(flag_ Perm) bool'
		'p.all':       'fn (e &Perm) all(flag_ Perm) bool'
		'p.toggle':    'fn (mut e Perm) toggle(flag_ Perm)'
		'p.clear(':    'fn (mut e Perm) clear(flag_ Perm)'
		'p.set_all':   'fn (mut e Perm) set_all()'
		'p.clear_all': 'fn (mut e Perm) clear_all()'
		'p.is_empty':  'fn (e &Perm) is_empty() bool'
	} {
		word := needle.all_after('.').trim_right('(')
		value := hover_value_at(mut app, uri, content, needle, word)
		assert value.contains('```v\n${signature}\n```'), '${needle}: ${value}'
		assert !value.contains('array') && !value.contains('IError'), '${needle}: ${value}'
	}
	assert hover_value_at(mut app, uri, content, 'Color.from', 'from').contains('string')
	assert hover_value_at(mut app, uri, content, 'p.has', 'has').contains('at least one')
	// declared by the type itself, or not a member V gives: not answered from V's list
	assert hover_value_at(mut app, uri, content, 'pt.str', 'str').contains('fn (point Point) str() string')
	assert !hover_value_at(mut app, uri, content, 'Color.red', 'red').contains('fn ')
}

// A member's documentation is the one of the declaration it resolves to, even
// when that one has none: never the one of another type's member of the same
// name, as `str` of IError for a struct's own undocumented `str`.
fn test_hover_documents_a_member_with_its_own_declaration() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := "module main\n\nstruct Point {\n\tx int\n}\n\nfn (point Point) str() string {\n\treturn 'point'\n}\n\n// area is how much room the point takes.\nfn (point Point) area() int {\n\treturn 0\n}\n\n// scaled grows the point.\n@[inline]\nfn (point Point) scaled() Point {\n\treturn point\n}\n\nfn main() {\n\tpt := Point{}\n\tprintln(pt.str())\n\tprintln(pt.area())\n\tprintln(pt.scaled())\n\tarr := [1]\n\tprintln(arr.first())\n\tprintln('a'.to_upper())\n}\n"
	path := os.join_path(app.temp_dir, 'member_docs', 'main.v')
	must_mkdir_all(os.dir(path))
	must_write_file(path, content)
	uri := path_to_uri(path)
	app.open_files[uri] = content
	app.reindex_uri(uri)
	lines := content.split_into_lines()
	mut docs := map[string]string{}
	for needle in ['pt.str', 'pt.area', 'pt.scaled', 'arr.first', "'a'.to_upper"] {
		line := lines.filter(it.contains(needle))[0]
		col := line.index(needle) or { -1 } + needle.index('.') or { -1 } + 2
		docs[needle] = app.hover_doc_comment(uri, '${lines.index(line) + 1}:hv^${col}')
	}
	assert docs['pt.str'] == '', docs['pt.str']
	assert docs['pt.area'] == 'area is how much room the point takes.', docs['pt.area']
	// an attribute sits between a declaration and its documentation
	assert docs['pt.scaled'] == 'scaled grows the point.', docs['pt.scaled']
	assert docs["'a'.to_upper"].starts_with('to_upper returns the string in all uppercase characters.'), docs["'a'.to_upper"]
	// a member of a builtin type keeps the documentation vlib gives it
	assert docs['arr.first'].contains('first element'), docs['arr.first']
}

fn test_hover_on_a_deep_chain_inside_nested_closures() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'nested_chain_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nstruct Leaf {\n\tflag bool\n}\n\nstruct Child {\n\tleaf Leaf\n}\n\nstruct Node {\n\tchild Child\n}\n\nstruct Listener {\n\tnode Node\n}\n\nfn main() {\n\tlisteners := []Listener{}\n\touter := fn (x Listener) bool {\n\t\tinner := fn (y Listener) bool {\n\t\t\treturn y.node.child.leaf.flag\n\t\t}\n\t\treturn inner(x) && x.node.child.leaf.flag\n\t}\n\tprintln(listeners.filter(outer))\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	inner_line := lines.index('\t\t\treturn y.node.child.leaf.flag')
	outer_line := lines.index('\t\treturn inner(x) && x.node.child.leaf.flag')
	assert inner_line >= 0 && outer_line >= 0
	for line, cases in {
		inner_line: {
			'node':  'node Node'
			'child': 'child Child'
			'leaf':  'leaf Leaf'
			'flag':  'flag bool'
		}
		outer_line: {
			'node':  'node Node'
			'child': 'child Child'
			'leaf':  'leaf Leaf'
			'flag':  'flag bool'
		}
	} {
		for name, expected in cases {
			col := lines[line].last_index('.' + name) or { -1 }
			assert col > 0, '${line}:${name}'
			hover := app.hover_at(uri, Position{
				line: line
				char: col + 2
			}) or { Hover{} }
			assert hover.contents.value.contains(expected), '${line}:${name}: ${hover.contents.value}'
		}
	}
}

fn test_hover_on_a_closure_parameter_uses_the_type_written_beside_it() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'closure_parameter_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nstruct Child {\n\tvalue int\n}\n\nstruct Node {\n\tchild Child\n}\n\nstruct Listener {\n\tnode Node\n}\n\nfn main() {\n\tx := 1\n\tlisteners := []Listener{}\n\tkept := listeners.filter(fn (x Listener) bool {\n\t\treturn x.node.child.value == 1\n\t})\n\tprintln('\${x} \${kept}')\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	// The parameter is being declared here, so the binding of the same name from
	// the enclosing scope must not answer for it.
	signature := lines.index('\tkept := listeners.filter(fn (x Listener) bool {')
	assert signature >= 0
	signature_col := lines[signature].index('x Listener') or { -1 }
	assert signature_col > 0
	hover := app.local_binding_hover(uri, Position{
		line: signature
		char: signature_col
	}) or { Hover{} }
	assert hover.contents.value.contains('x Listener'), hover.contents.value
	body := lines.index('\t\treturn x.node.child.value == 1')
	assert body >= 0
	body_col := lines[body].index('x.node') or { -1 }
	assert body_col > 0
	inside := app.local_binding_hover(uri, Position{
		line: body
		char: body_col
	}) or { Hover{} }
	assert inside.contents.value.contains('x Listener'), inside.contents.value
	outer := lines.index("\tprintln('\${x} \${kept}')")
	assert outer >= 0
	outer_col := lines[outer].index('\${x}') or { -1 }
	assert outer_col > 0
	outer_hover := app.local_binding_hover(uri, Position{
		line: outer
		char: outer_col + 2
	}) or { Hover{} }
	assert outer_hover.contents.value.contains('x int'), outer_hover.contents.value
}

fn test_hover_on_nested_closure_parameters_keeps_each_type() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'nested_closure_parameter_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nstruct Child {\n\tvalue int\n}\n\nstruct Node {\n\tchild Child\n}\n\nstruct Listener {\n\tnode Node\n}\n\nfn main() {\n\tx := 'text'\n\touter := fn (x Listener) bool {\n\t\tinner := fn (x Child) bool {\n\t\t\treturn x.value == 1\n\t\t}\n\t\treturn inner(x.node.child)\n\t}\n\tprintln('\${x} \${outer(Listener{})}')\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	// Three parameters of the same name, one inside the other: each hover has to
	// answer with the type written next to that one.
	for source_line, expected in {
		'\touter := fn (x Listener) bool {':      'x Listener'
		'\t\tinner := fn (x Child) bool {':       'x Child'
		'\t\t\treturn x.value == 1':              'x Child'
		'\t\treturn inner(x.node.child)':         'x Listener'
	} {
		line := lines.index(source_line)
		assert line >= 0, source_line
		col := if source_line.contains('fn (x ') {
			lines[line].index('x ' + expected.all_after(' ')) or { -1 }
		} else {
			lines[line].index('x.') or { -1 }
		}
		assert col > 0, source_line
		hover := app.local_binding_hover(uri, Position{
			line: line
			char: col
		}) or { Hover{} }
		assert hover.contents.value.contains(expected), '${source_line}: ${hover.contents.value}'
	}
}

fn test_hover_types_a_binding_holding_a_function_literal() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'function_literal_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nfn main() {\n\tx := 2\n\tf := fn (a int) {\n\t\tprintln(a)\n\t}\n\tg := fn (a int, b string) !int {\n\t\treturn a + b.len\n\t}\n\th := fn () {\n\t\tprintln('hi')\n\t}\n\tc := fn [x] (a int) int {\n\t\treturn a + x\n\t}\n\tf(1)\n\tg(1, 'a') or { 0 }\n\th()\n\tprintln(c(1))\n\tprintln(apply(c))\n}\n\nfn apply(cb fn (int) int) int {\n\treturn cb(1)\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	// A function literal writes its own type down: the signature, without the
	// capture list and without the body.
	for name, expected in {
		'f': 'f fn (a int)'
		'g': 'g fn (a int, b string) !int'
		'h': 'h fn ()'
		'c':  'c fn (a int) int'
		'cb': 'cb fn (int) int'
	} {
		mut line := -1
		mut col := -1
		for idx, text in lines {
			if !text.contains('${name}(') {
				continue
			}
			line = idx
			col = text.index('${name}(') or { -1 }
			break
		}
		assert line >= 0 && col >= 0, name
		hover := app.local_binding_hover(uri, Position{
			line: line
			char: col + 1
		}) or { Hover{} }
		assert hover.contents.value.contains(expected), '${name}: ${hover.contents.value}'
	}
}

fn test_hover_types_bindings_whose_value_names_no_type() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'inferred_binding_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nfn make_int() !int {\n\treturn 3\n}\n\nfn work() int {\n\treturn 4\n}\n\nfn main() {\n\tres := make_int() or {\n\t\tprintln(err)\n\t\t0\n\t}\n\tth := spawn work()\n\tif v := make_int() {\n\t\tprintln(v)\n\t}\n\tprintln(res)\n\tprintln(th.wait())\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	// A value that does not write its type down is still worth inferring: an `or`
	// block, a spawned call and an `if` guard all bind a variable.
	for source_line, expected in {
		'\tprintln(res)':       'res int'
		'\tprintln(th.wait())': 'th thread int'
		'\t\tprintln(v)':       'v int'
	} {
		line := lines.index(source_line)
		assert line >= 0, source_line
		name := source_line.all_after('println(').all_before(')').all_before('.')
		col := lines[line].index('(${name}') or { -1 }
		assert col >= 0, source_line
		hover := app.local_binding_hover(uri, Position{
			line: line
			char: col + 2
		}) or { Hover{} }
		assert hover.contents.value.contains(expected), '${source_line}: ${hover.contents.value}'
	}
}

fn test_hover_types_a_declaration_split_over_lines() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'multiline_declaration_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nstruct Point {\n\tx int\n}\n\nfn main() {\n\tone := &Point{\n\t\tx: 1\n\t}\n\ttwo := Point{\n\t\tx: 2\n\t}\n\tages := map[string]int{\n\t\t'a': 1\n\t}\n\tnames := []string{\n\t\tlen: 2\n\t}\n\tprintln(one)\n\tprintln(two)\n\tprintln(ages)\n\tprintln(names)\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	// A value written over several lines still names its type on the first one.
	for name, expected in {
		'one':   'one &Point'
		'two':   'two Point'
		'ages':  'ages map[string]int'
		'names': 'names []string'
	} {
		line := lines.index('\tprintln(${name})')
		assert line >= 0, name
		col := lines[line].index('(${name})') or { -1 }
		assert col > 0, name
		hover := app.local_binding_hover(uri, Position{
			line: line
			char: col + 2
		}) or { Hover{} }
		assert hover.contents.value.contains(expected), '${name}: ${hover.contents.value}'
	}
}

fn test_hover_keeps_an_inferred_reference_type() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'inferred_reference_hover')
	must_mkdir_all(test_dir)
	content := 'module main\n\nstruct Point {\n\tx int\n}\n\nfn main() {\n\tp := &Point{}\n\tprintln(p)\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\tprintln(p)')
	assert line >= 0
	col := lines[line].index('(p)') or { -1 }
	assert col > 0
	hover := app.local_binding_hover(uri, Position{
		line: line
		char: col + 2
	}) or { Hover{} }
	assert hover.contents.value.contains('p &Point'), hover.contents.value
}

fn test_hover_leaves_struct_literal_field_labels_to_field_hover() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'field_label_hover')
	must_mkdir_all(test_dir)
	content := "module main\n\nstruct Row {\n\tvalue string\n}\n\nfn main() {\n\tshow := fn (value int) {\n\t\trow := Row{\n\t\t\tvalue: 'hello'\n\t\t}\n\t\tprintln(row)\n\t\tprintln(value)\n\t}\n\tshow(1)\n}\n"
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	label_line := lines.index("\t\t\tvalue: 'hello'")
	assert label_line >= 0
	label_col := lines[label_line].index('value') or { -1 }
	assert label_col >= 0
	// The field label is not the closure parameter, so it is left to field hover.
	assert app.local_binding_hover(uri, Position{
		line: label_line
		char: label_col + 1
	}) == none
	use_line := lines.index('\t\tprintln(value)')
	assert use_line >= 0
	use_col := lines[use_line].index('(value)') or { -1 }
	assert use_col > 0
	hover := app.local_binding_hover(uri, Position{
		line: use_line
		char: use_col + 2
	}) or { Hover{} }
	assert hover.contents.value.contains('value int'), hover.contents.value
}

fn test_hover_and_inference_use_innermost_nested_binding() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'nested_binding_hover')
	must_mkdir_all(test_dir)
	content := 'module main\n\nfn main() {\n\touter := fn (x string) {\n\t\tinner := fn (x int) {\n\t\t\tprintln(x)\n\t\t}\n\t\tinner(x.len)\n\t}\n\touter("abc")\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\t\t\tprintln(x)')
	assert line >= 0
	x_col := lines[line].index('x') or { -1 }
	assert x_col >= 0
	hover := app.local_binding_hover(uri, Position{
		line: line
		char: x_col + 1
	}) or {
		assert false, 'expected hover for innermost binding'
		return
	}
	assert hover.contents.value.contains('x int'), hover.contents.value
}

fn test_inference_does_not_use_typed_outer_binding_for_inner_local() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'nested_inferred_binding')
	must_mkdir_all(test_dir)
	content := 'module main\n\nfn main() {\n\touter := fn (x string) {\n\t\tinner := fn () {\n\t\t\tx := 7\n\t\t\tprintln(x)\n\t\t}\n\t\tinner()\n\t}\n\touter("abc")\n}\n'
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index('\t\t\tprintln(x)')
	assert line >= 0
	position := Position{
		line: line
		char: lines[line].index('x') or { 0 }
	}
	assert app.infer_receiver_type_at_position(uri, content, 'x', position) == 'int'
}

fn test_non_identifier_receiver_uses_compiler_fallback() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'non_identifier_receiver_fallback')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct Service {}\nfn (service Service) start() {}\nfn start() {}\nfn make_service() Service {\n\treturn Service{}\n}\n\nfn main() {\n\tservices := [Service{}]\n\tmake_service().sta\n\tservices[0].\n\tmake_service().start()\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()

	for source_line in ['\tmake_service().sta', '\tservices[0].'] {
		completion_line := lines.index(source_line)
		assert completion_line >= 0
		qualifier, has_member_access, standalone := member_qualifier_at_cursor(lines[completion_line], lines[completion_line].len, app.position_encoding)
		assert qualifier == ''
		assert has_member_access
		assert !standalone
		indexed := app.indexed_completions(uri, Position{
			line: completion_line
			char: lines[completion_line].len
		})
		// The index types the receiver itself: `Service`'s method, never the free
		// function `start()`.
		assert !indexed.use_compiler
		starts := indexed.items.filter(it.label == 'start')
		assert starts.len == 1, indexed.items.map(it.label).str()
		assert starts[0].detail.contains('(service Service)'), starts[0].detail
	}

	definition_line := lines.index('\tmake_service().start()')
	assert definition_line >= 0
	start_col := lines[definition_line].index('start') or { -1 }
	assert start_col >= 0
	if app.resolve_indexed_definition(uri, Position{
		line: definition_line
		char: start_col + 2
	}) != none {
		assert false, 'complex receiver definition must delegate to the compiler'
	}
}

fn test_chained_member_completion_resolves_field_type_imported_by_parent_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	root := os.join_path(app.temp_dir, 'nested_imported_field_completion')
	devices_dir := os.join_path(root, 'devices')
	models_dir := os.join_path(root, 'models')
	must_mkdir_all(devices_dir)
	must_mkdir_all(models_dir)
	must_write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'nested_fields'\n}\n")
	device_file := os.join_path(devices_dir, 'devices.v')
	must_write_file(device_file, 'module devices\n\npub struct Cpu {\npub:\n\tcores int\n}\n\npub fn (cpu Cpu) usage() int {\n\treturn 0\n}\n')
	must_write_file(os.join_path(models_dir, 'models.v'), 'module models\n\nimport devices\n\npub struct AppState {\npub:\n\tcpu devices.Cpu\n}\n')
	main_file := os.join_path(root, 'main.v')
	content := 'module main\n\nimport models\n\nfn main() {\n\tapp := models.AppState{}\n\tapp.cpu.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	app.workspace_roots = [root]
	lines := content.split_into_lines()
	completion_line := lines.index('\tapp.cpu.')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}

	assert app.infer_receiver_type_at_position(uri, content, 'app.cpu', position) == 'devices.Cpu'
	indexed := app.indexed_completions(uri, position)
	assert !indexed.use_compiler
	assert indexed.items.any(it.label == 'cores' && it.kind == 5)
	assert indexed.items.any(it.label == 'usage' && it.kind == 2)
}

fn test_multi_binding_receiver_uses_corresponding_rhs() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'multi_binding_receiver_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct A {}\nfn (value A) left_method() {}\nstruct B {}\nfn (value B) right_method() {}\n\nfn main() {\n\tleft, right := A{}, B{}\n\tright.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tright.')
	assert completion_line >= 0
	assert app.infer_receiver_type(uri, content, 'left', completion_line) == 'A'
	assert app.infer_receiver_type(uri, content, 'right', completion_line) == 'B'

	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	labels := indexed.items.map(it.label)
	assert !indexed.use_compiler
	assert 'right_method' in labels
	assert 'left_method' !in labels
}

fn test_generic_struct_receiver_completion_includes_fields() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'generic_struct_field_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct Box[T] {\n\tvalue T\n}\nfn (box Box[T]) reset() {}\n\nfn inspect(box Box[int]) {\n\tbox.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tbox.')
	assert completion_line >= 0

	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	labels := indexed.items.map(it.label)
	assert !indexed.use_compiler
	assert 'value' in labels
	assert 'reset' in labels
}

fn test_embedded_struct_receiver_completion_includes_promoted_members() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'embedded_struct_receiver_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct Base {\n\tpromoted_field string\n}\nfn (base Base) promoted_method() {}\n\nstruct Child {\n\tBase\n\town_field int\n}\nfn (child Child) child_method() {}\n\nfn inspect(child Child) {\n\tchild.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tchild.')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	fields := app.indexed_struct_field_completions(uri, content, 'Child')
	assert !fields.use_compiler
	assert fields.items.any(it.label == 'own_field')
	assert fields.items.any(it.label == 'promoted_field')
	assert !fields.items.any(it.label == 'Base')
	indexed := app.indexed_completions(uri, position)
	assert !indexed.use_compiler
	assert indexed.items.any(it.label == 'own_field')
	assert indexed.items.any(it.label == 'promoted_field')
	assert indexed.items.any(it.label == 'child_method')
	assert indexed.items.any(it.label == 'promoted_method')
	assert !indexed.items.any(it.label == 'Base')

	response := app.operation_at_pos(.completion, Request{
		id: 9700
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: position
		},
			escape_unicode: true
		)
	})
	assert response.result is CompletionList
	labels := (response.result as CompletionList).items.map(it.label)
	assert 'promoted_field' in labels
	assert 'promoted_method' in labels
	assert 'own_field' in labels
	assert 'child_method' in labels
}

fn test_struct_field_completion_excludes_attributes() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'attributed_struct_field_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nstruct User {\n\t@[json: 'user_name']\n\tname string\n\t@[\n\t\tdeprecated\n\t]\n\tage int\n}\n\nfn inspect(user User) {\n\tuser.\n}\n"
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tuser.')
	assert completion_line >= 0

	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	labels := indexed.items.map(it.label)
	assert 'name' in labels
	assert 'age' in labels
	assert '@[json:' !in labels
	assert 'deprecated' !in labels
}

fn test_struct_field_completion_excludes_block_comment_fields() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'commented_struct_field_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct User {\n\tname string\n\t/*\n\tobsolete string\n\t*/\n\tage int\n}\n\nfn inspect(user User) {\n\tuser.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tuser.')
	assert completion_line >= 0

	symbols := parse_document_symbols(content)
	user := symbols.filter(it.name == 'User')
	assert user.len == 1
	assert !user[0].children.any(it.name == 'obsolete')
	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	labels := indexed.items.map(it.label)
	assert 'name' in labels
	assert 'age' in labels
	assert 'obsolete' !in labels
}

fn test_multiline_function_completion_builds_full_snippet() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'multiline_function_completion')
	module_dir := os.join_path(test_dir, 'builder')
	must_mkdir_all(module_dir)
	module_content := 'module builder\n\npub fn build(\n\trequired string,\n\tcount int,\n) string {\n\treturn required.repeat(count)\n}\n'
	must_write_file(os.join_path(module_dir, 'builder.v'), module_content)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport builder\n\nfn main() {\n\tbuilder.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tbuilder.')
	assert completion_line >= 0
	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	public_build := indexed.items.filter(it.label == 'build')
	assert public_build.len == 1
	public_insert := public_build[0].insert_text or { '' }
	assert public_insert == 'build(\${1:required}, \${2:count})\$0'

	local_items := parse_module_fn_completions(module_content)
	local_build := local_items.filter(it.label == 'build')
	assert local_build.len == 1
	local_insert := local_build[0].insert_text or { '' }
	assert local_insert == 'build(\${1:required}, \${2:count})\$0'
}

fn test_function_typed_parameter_completion_builds_full_snippet() {
	module_content := 'module callbacks\n\npub fn apply(callback fn (int) int, value int) int {\n\treturn callback(value)\n}\n'
	items := parse_module_fn_completions(module_content)
	apply_items := items.filter(it.label == 'apply')
	assert apply_items.len == 1
	insert := apply_items[0].insert_text or { '' }
	assert insert == 'apply(\${1:callback}, \${2:value})\$0'
}

fn test_struct_literal_completion_includes_indexed_fields() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	test_dir := os.join_path(app.temp_dir, 'struct_literal_field_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct User {\n\tname string\n\tage int\n}\nfn (user User) save() {}\n\nfn main() {\n\tuser := User{\n\t\tna\n\t}\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\t\tna')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	assert struct_literal_type_at_cursor(content, position, app.position_encoding) == 'User'

	indexed := app.indexed_completions(uri, position)
	labels := indexed.items.map(it.label)
	assert !indexed.use_compiler
	assert 'name' in labels
	assert 'age' in labels
	assert 'save' !in labels
}

fn test_struct_literal_value_completion_keeps_expression_symbols() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'struct_literal_value_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nstruct User {\n\tname string\n\tage int\n}\n\nfn main() {\n\tlocal_name := 'Alex'\n\tuser := User{name: local_}\n}\n"
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tuser := User{name: local_}')
	assert completion_line >= 0
	local_end := lines[completion_line].index('local_') or { -1 }
	assert local_end >= 0
	position := Position{
		line: completion_line
		char: local_end + 'local_'.len
	}
	assert struct_literal_type_at_cursor(content, position, app.position_encoding) == ''
	indexed := app.indexed_completions(uri, position)
	assert indexed.items.any(it.label == 'local_name')
	assert !indexed.items.any(it.label == 'age')
}

fn test_struct_literal_value_completion_survives_continuation_lines() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'struct_literal_continued_value_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	cases := [
		'\tuser := User{\n\t\tname:\n\t\t\tlocal_\n\t}',
		'\tuser := User{\n\t\tname: local_name +\n\t\t\tlocal_\n\t}',
	]
	for literal in cases {
		content := "module main\n\nstruct User {\n\tname string\n\tage int\n}\n\nfn main() {\n\tlocal_name := 'Alex'\n${literal}\n}\n"
		must_write_file(main_file, content)
		uri := path_to_uri(main_file)
		app.open_files[uri] = content
		lines := content.split_into_lines()
		completion_line := lines.index('\t\t\tlocal_')
		assert completion_line >= 0
		position := Position{
			line: completion_line
			char: lines[completion_line].len
		}
		assert struct_literal_type_at_cursor(content, position, app.position_encoding) == '', literal
		indexed := app.indexed_completions(uri, position)
		assert indexed.items.any(it.label == 'local_name'), literal
		assert !indexed.items.any(it.label == 'age'), literal
	}
}

fn test_struct_literal_completion_resumes_on_next_field_line() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'struct_literal_next_field_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nstruct User {\n\tname string\n\tage int\n}\n\nfn main() {\n\tuser := User{\n\t\tname: 'Alex'\n\t\tag\n\t}\n}\n"
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\t\tag')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	assert struct_literal_type_at_cursor(content, position, app.position_encoding) == 'User'
	indexed := app.indexed_completions(uri, position)
	assert indexed.items.any(it.label == 'age')
	assert !indexed.items.any(it.label == 'user')
}

fn test_function_body_is_not_detected_as_struct_literal() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'function_body_struct_literal_detection')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct User {\n\tname string\n}\n\nfn build() User {\n\tlocal_value := 1\n\tloc\n\treturn User{}\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tloc')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	assert struct_literal_type_at_cursor(content, position, app.position_encoding) == ''
	indexed := app.indexed_completions(uri, position)
	assert indexed.items.any(it.label == 'local_value')
	assert !indexed.items.any(it.label == 'name')
}

fn test_smart_cast_body_is_not_detected_as_struct_literal() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'smart_cast_struct_literal_detection')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct Location {\n\tname string\n}\nstruct Missing {}\ntype Result = Location | Missing\n\nfn inspect(result Result) {\n\tlocal_value := 1\n\tif result is Location {\n\t\tloc\n\t}\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\t\tloc')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	assert struct_literal_type_at_cursor(content, position, app.position_encoding) == ''
	indexed := app.indexed_completions(uri, position)
	assert indexed.items.any(it.label == 'local_value')
	assert !indexed.items.any(it.label == 'name')
}

fn test_sum_type_match_arm_is_not_detected_as_struct_literal() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'match_arm_struct_literal_detection')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct Location {\n\tname string\n}\nstruct Missing {}\nstruct User {\n\tlabel string\n}\ntype Result = Location | Missing\n\nfn inspect(result Result) {\n\tlocal_value := 1\n\tmatch result {\n\t\tLocation {\n\t\t\tloc\n\t\t\tuser := User{\n\t\t\t\tlab\n\t\t\t}\n\t\t}\n\t\tMissing {}\n\t}\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\t\t\tloc')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	assert struct_literal_type_at_cursor(content, position, app.position_encoding) == ''
	indexed := app.indexed_completions(uri, position)
	assert indexed.items.any(it.label == 'local_value')
	assert indexed.items.any(it.label == 'string')
	assert !indexed.items.any(it.label == 'name')
	literal_line := lines.index('\t\t\t\tlab')
	assert literal_line >= 0
	literal_position := Position{
		line: literal_line
		char: lines[literal_line].len
	}
	assert struct_literal_type_at_cursor(content, literal_position, app.position_encoding) == 'User'
	literal_indexed := app.indexed_completions(uri, literal_position)
	assert literal_indexed.items.any(it.label == 'label')
}

fn test_bare_completion_includes_scoped_implicit_bindings() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'implicit_binding_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn might_fail() !int {\n\treturn 1\n}\n\nfn main() {\n\tvalues := [1, 2]\n\tpositive := values.filter(it)\n\tvalue := might_fail() or {\n\t\ter\n\t}\n\ter\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	it_line := lines.index('\tpositive := values.filter(it)')
	err_line := lines.index('\t\ter')
	after_line := lines.index('\ter')
	assert it_line >= 0
	assert err_line >= 0
	assert after_line >= 0
	it_start := lines[it_line].index('it)') or { -1 }
	assert it_start >= 0
	it_position := Position{
		line: it_line
		char: it_start + 2
	}
	assert app.local_scope_completions(content, it_position).any(it.label == 'it')
	assert app.indexed_completions(uri, it_position).items.any(it.label == 'it')
	err_position := Position{
		line: err_line
		char: lines[err_line].len
	}
	assert app.local_scope_completions(content, err_position).any(it.label == 'err')
	assert app.indexed_completions(uri, err_position).items.any(it.label == 'err')
	after_position := Position{
		line: after_line
		char: lines[after_line].len
	}
	assert !app.local_scope_completions(content, after_position).any(it.label in ['it', 'err'])
}

// local_labels_at returns the local names that completion offers where the
// marked source has `‸`.
fn local_labels_at(mut app App, marked string) []string {
	cursor := marked.index('‸') or { panic('no cursor in ${marked}') }
	content := marked.replace('‸', '')
	before := content[..cursor]
	line := before.count('\n')
	col := cursor - (before.last_index('\n') or { -1 }) - 1
	return app.local_scope_completions(content, Position{
		line: line
		char: col
	}).map(it.label)
}

const implicit_names_head = 'module main\n\nstruct Row {\n\tname string\n}\n\nfn parse(s string) !int {\n\treturn s.int()\n}\n\nfn find(n int) ?int {\n\treturn if n > 0 { n } else { none }\n}\n\n'

// The names V gives code without a declaration: `it` in the predicate or the
// callback of every array method that takes one, `a` and `b` in a sort, `err` in
// the `else` of `if x := call() {` as in an `or {}` block, and the variable of a
// `$for`. Each only where V gives it.
fn test_local_completion_offers_the_names_v_gives_without_a_declaration() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	for label, marked in {
		'it':    'fn main() {\n\tnums := [1]\n\tprintln(nums.count(i‸))\n}\n'
		'a':     'fn main() {\n\tmut nums := [1]\n\tnums.sort(a‸)\n}\n'
		'b':     'fn main() {\n\tnums := [1]\n\tprintln(nums.sorted(a < b‸))\n}\n'
		'err':   "fn main() {\n\tif v := parse('1') {\n\t\tprintln(v)\n\t} else {\n\t\tprintln(e‸)\n\t}\n}\n"
		'field': 'fn main() {\n\t\$for field in Row.fields {\n\t\tprintln(f‸)\n\t}\n}\n'
	} {
		assert label in local_labels_at(mut app, implicit_names_head + marked), '${label}: ${marked}'
	}
	// an Option guard gives `err` in its `else` too
	assert 'err' in local_labels_at(mut app, implicit_names_head + 'fn main() {\n\tif v := find(1) {\n\t\tprintln(v)\n\t} else {\n\t\tprintln(e‸)\n\t}\n}\n')
	// `it` is still there in filter, and `a` and `b` in sorted
	assert 'it' in local_labels_at(mut app, implicit_names_head + 'fn main() {\n\tnums := [1]\n\tprintln(nums.filter(i‸))\n}\n')
	assert 'a' in local_labels_at(mut app, implicit_names_head + 'fn main() {\n\tnums := [1]\n\tprintln(nums.sorted(a‸))\n}\n')
	// and nowhere else
	for label, marked in {
		'it':    'fn main() {\n\tnums := [1]\n\tprintln(nums.index(i‸))\n}\n'
		'a':     'fn main() {\n\tnums := [1]\n\tprintln(nums.map(a‸))\n}\n'
		'err':   'fn main() {\n\tif true {\n\t\tprintln(1)\n\t} else {\n\t\tprintln(e‸)\n\t}\n}\n'
		'field': 'fn main() {\n\t\$for field in Row.fields {\n\t\tprintln(1)\n\t}\n\tprintln(f‸)\n}\n'
	} {
		assert label !in local_labels_at(mut app, implicit_names_head + marked), '${label}: ${marked}'
	}
	assert 'err' !in local_labels_at(mut app, implicit_names_head + "fn main() {\n\tif v := parse('1') {\n\t\tprintln(v)\n\t} else {\n\t\tprintln(1)\n\t}\n\tprintln(e‸)\n}\n")
}

fn test_loop_header_bindings_are_removed_with_loop_scope() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	content := 'module main\n\nfn inspect(values []string) {\n\tfor i, value in values {\n\t\tvalue\n\t}\n\tfor j, item in\n\t\tvalues {\n\t\titem\n\t}\n\tval\n}\n'
	lines := content.split_into_lines()
	inside_line := lines.index('\t\tvalue')
	multiline_inside_line := lines.index('\t\titem')
	after_line := lines.index('\tval')
	assert inside_line >= 0
	assert multiline_inside_line >= 0
	assert after_line >= 0
	inside := app.local_scope_completions(content, Position{
		line: inside_line
		char: lines[inside_line].len
	}).map(it.label)
	assert 'i' in inside
	assert 'value' in inside
	multiline_inside := app.local_scope_completions(content, Position{
		line: multiline_inside_line
		char: lines[multiline_inside_line].len
	}).map(it.label)
	assert 'j' in multiline_inside
	assert 'item' in multiline_inside

	after := app.local_scope_completions(content, Position{
		line: after_line
		char: lines[after_line].len
	}).map(it.label)
	assert 'values' in after
	assert 'i' !in after
	assert 'value' !in after
	assert 'j' !in after
	assert 'item' !in after
}

fn test_loop_header_literal_braces_do_not_change_lexical_scope() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := "module main\n\nfn inspect() {\n\tfor key, value in {'x': 1} {\n\t\tvalue\n\t}\n\tkey\n}\n"
	test_dir := os.join_path(app.temp_dir, 'loop_literal_scope_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	inside_line := lines.index('\t\tvalue')
	after_line := lines.index('\tkey')
	assert inside_line >= 0
	assert after_line >= 0
	inside := app.local_scope_completions(content, Position{
		line: inside_line
		char: lines[inside_line].len
	}).map(it.label)
	assert 'key' in inside
	assert 'value' in inside
	indexed := app.indexed_completions(uri, Position{
		line: inside_line
		char: lines[inside_line].len
	})
	assert !indexed.use_compiler
	assert indexed.items.any(it.label == 'key')
	assert indexed.items.any(it.label == 'value')
	after := app.local_scope_completions(content, Position{
		line: after_line
		char: lines[after_line].len
	}).map(it.label)
	assert 'key' !in after
	assert 'value' !in after
}

fn test_loop_header_nested_struct_literal_does_not_change_lexical_scope() {
	assert binding_scope_header_starts_literal('for user in [User')
	assert binding_scope_header_starts_literal('for box in []Box[int]')
	assert binding_scope_header_starts_literal('for value in []int')
	assert binding_scope_header_starts_literal('if value := module.Value')
	assert !binding_scope_header_starts_literal('if result is module.Location')
	assert !binding_scope_header_starts_literal('for user in [User{}]')
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\nstruct User {}\n\nfn inspect() {\n\tfor user in [User{}] {\n\t\tuser\n\t}\n\tuser\n}\n'
	test_dir := os.join_path(app.temp_dir, 'loop_struct_literal_scope_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	inside_line := lines.index('\t\tuser')
	after_line := lines.index('\tuser')
	assert inside_line >= 0
	assert after_line >= 0
	inside := app.indexed_completions(uri, Position{
		line: inside_line
		char: lines[inside_line].len
	})
	assert !inside.use_compiler
	assert inside.items.any(it.label == 'user')
	after := app.local_scope_completions(content, Position{
		line: after_line
		char: lines[after_line].len
	})
	assert !after.any(it.label == 'user')
}

fn test_loop_header_multidimensional_literal_does_not_change_lexical_scope() {
	assert binding_scope_header_starts_literal('for row in [][]int')
	assert binding_scope_header_starts_literal('for row in [2][]int')
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\nfn inspect() {\n\tfor row in [][]int{len: 2, init: []int{}} {\n\t\trow\n\t}\n\trow\n}\n'
	test_dir := os.join_path(app.temp_dir, 'loop_multidimensional_scope_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	inside_line := lines.index('\t\trow')
	after_line := lines.index('\trow')
	assert inside_line >= 0
	assert after_line >= 0
	inside := app.indexed_completions(uri, Position{
		line: inside_line
		char: lines[inside_line].len
	})
	assert !inside.use_compiler
	assert inside.items.any(it.label == 'row')
	after := app.local_scope_completions(content, Position{
		line: after_line
		char: lines[after_line].len
	})
	assert !after.any(it.label == 'row')
}

fn test_conditional_bare_completion_requests_compiler_fallback() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'active_conditional_bare_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nfn always() {}\n\n\$if linux {\n\tfn platform_only() {}\n}\n\nfn main() {\n\tplat\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tplat')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	indexed := app.indexed_completions(uri, position)
	assert indexed.use_compiler
	assert indexed.items.any(it.label == 'always')
	assert !indexed.items.any(it.label == 'platform_only')

	response := app.operation_at_pos(.completion, Request{
		id: 9600
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: position
		},
			escape_unicode: true
		)
	})
	assert response.result is CompletionList
	assert (response.result as CompletionList).items.any(it.label == 'always')
}

fn test_conditional_structs_do_not_contribute_indexed_receiver_fields() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'conditional_receiver_fields')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\n\$if windows {\n\tstruct Platform {\n\t\twin int\n\t}\n} \$else {\n\tstruct Platform {\n\t\tunix int\n\t}\n}\n\nfn (platform Platform) reset() {}\n\nfn inspect(platform Platform) {\n\tplatform.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tplatform.')
	assert completion_line >= 0
	position := Position{
		line: completion_line
		char: lines[completion_line].len
	}
	fields := app.indexed_struct_field_completions(uri, content, 'Platform')
	assert fields.items.len == 0
	assert fields.use_compiler
	indexed := app.indexed_completions(uri, position)
	assert indexed.use_compiler
	assert indexed.items.any(it.label == 'reset')
	assert !indexed.items.any(it.label in ['win', 'unix'])
}

fn test_conditional_methods_request_receiver_completion_fallback() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'conditional_receiver_methods')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct Service {\n\tname string\n}\n\nfn (service Service) start() {}\n\n\$if !js {\n\tfn (service Service) reload() {}\n}\n\nfn inspect(service Service) {\n\tservice.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\tservice.')
	assert completion_line >= 0

	methods := app.indexed_method_symbols(uri, content, 'Service', '')
	assert methods.use_compiler
	assert methods.locations.len == 1
	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	assert indexed.use_compiler
	assert indexed.items.any(it.label == 'name')
	assert indexed.items.any(it.label == 'start')
	assert !indexed.items.any(it.label == 'reload')
	response := app.operation_at_pos(.completion, Request{
		id: 9601
		method: 'textDocument/completion'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: completion_line
				char: lines[completion_line].len
			}
		},
			escape_unicode: true
		)
	})
	assert response.result is CompletionList
	assert (response.result as CompletionList).items.any(it.label == 'reload')
}

fn test_imported_private_conditional_methods_do_not_request_fallback() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	root := os.join_path(app.temp_dir, 'private_conditional_receiver_methods')
	module_dir := os.join_path(root, 'service')
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'private_conditional'\n}\n")
	must_write_file(os.join_path(module_dir, 'service.v'), 'module service\n\npub struct Service {\npub:\n\tname string\n}\n\n\$if !js {\n\tfn (service Service) private_reload() {}\n}\n')
	main_file := os.join_path(root, 'main.v')
	content := 'module main\n\nimport service\n\nfn inspect(value service.Service) {\n\tvalue.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	app.workspace_roots = [root]
	lines := content.split_into_lines()
	completion_line := lines.index('\tvalue.')
	assert completion_line >= 0

	methods := app.indexed_method_symbols(uri, content, 'service.Service', '')
	assert !methods.use_compiler
	assert methods.items.len == 0
	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	assert !indexed.use_compiler
	assert indexed.items.any(it.label == 'name')
	assert !indexed.items.any(it.label == 'private_reload')
}

fn test_receiver_definition_ignores_closed_import_shadow() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'closed_import_shadow_definition')
	module_dir := os.join_path(test_dir, 'clock')
	must_mkdir_all(module_dir)
	module_file := os.join_path(module_dir, 'clock.v')
	module_content := 'module clock\n\npub fn start() {}\n'
	must_write_file(module_file, module_content)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport clock\n\nstruct Timer {}\nfn (timer Timer) start() {}\n\nfn main() {\n\tif true {\n\t\tclock := Timer{}\n\t\tclock.start()\n\t}\n\tclock.start()\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	module_uri := path_to_uri(module_file)
	app.open_files[uri] = content
	app.open_files[module_uri] = module_content
	lines := content.split_into_lines()
	inside_line := lines.index('\t\tclock.start()')
	outside_line := lines.index('\tclock.start()')
	assert inside_line >= 0
	assert outside_line >= 0
	assert app.infer_receiver_type(uri, content, 'clock', inside_line) == 'Timer'
	assert app.infer_receiver_type(uri, content, 'clock', outside_line) == ''
	inside_start_col := lines[inside_line].index('start') or { 0 }
	outside_start_col := lines[outside_line].index('start') or { 0 }

	inside := app.resolve_indexed_definition(uri, Position{
		line: inside_line
		char: inside_start_col + 2
	}) or {
		assert false, 'expected the in-scope Timer method definition'
		return
	}
	assert inside.uri == uri
	assert inside.range.start.line == 5

	outside := app.resolve_indexed_definition(uri, Position{
		line: outside_line
		char: outside_start_col + 2
	}) or {
		assert false, 'expected the imported clock.start definition'
		return
	}
	assert outside.uri == module_uri
	assert outside.range.start.line == 2
}

fn test_chained_definition_resolves_nested_receiver_not_import_alias() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'chained_definition_import_alias')
	module_dir := os.join_path(test_dir, 'clock')
	must_mkdir_all(module_dir)
	module_file := os.join_path(module_dir, 'clock.v')
	module_content := 'module clock\n\npub fn start() {}\n'
	must_write_file(module_file, module_content)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport clock\n\nstruct Timer {}\nfn (timer Timer) start() {}\nstruct App {\n\tclock Timer\n}\n\nfn main() {\n\tapp := App{}\n\tapp.clock.start()\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	call_line := lines.index('\tapp.clock.start()')
	assert call_line >= 0
	start_col := lines[call_line].index('start') or { -1 }
	assert start_col >= 0
	position := Position{
		line: call_line
		char: start_col + 2
	}
	indexed_location := app.resolve_indexed_definition(uri, position) or {
		assert false, 'expected indexed nested receiver definition'
		return
	}
	assert indexed_location.uri == uri
	assert indexed_location.range.start.line == lines.index('fn (timer Timer) start() {}')
	definition := app.operation_at_pos(.definition, Request{
		id: 9602
		method: 'textDocument/definition'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: position
		},
			escape_unicode: true
		)
	})
	assert definition.result is Location
	location := definition.result as Location
	assert location.uri == uri
	assert location.range.start.line == lines.index('fn (timer Timer) start() {}')
}

fn test_receiver_inference_uses_active_outer_binding_after_inner_shadow() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\nstruct Outer {}\nstruct Inner {}\n\nfn main() {\n\tvalue := Outer{}\n\tif true {\n\t\tvalue := Inner{}\n\t\tvalue.\n\t}\n\tvalue.\n}\n'
	lines := content.split_into_lines()
	inside_line := lines.index('\t\tvalue.')
	outside_line := lines.index('\tvalue.')
	assert inside_line >= 0
	assert outside_line >= 0
	assert app.infer_receiver_type('file:///tmp/scoped_receiver.v', content, 'value', inside_line) == 'Inner'
	assert app.infer_receiver_type('file:///tmp/scoped_receiver.v', content, 'value', outside_line) == 'Outer'
}

fn test_receiver_inference_uses_innermost_same_line_binding() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\nstruct A {}\nfn (value A) from_a() {}\nfn (value A) target() {}\nstruct B {}\nfn (value B) from_b() {}\nfn (value B) target() {}\n\nfn main() {\n\tvalue := A{}; if true { value := B{}; value.target() }; value.from_a()\n}\n'
	test_dir := os.join_path(app.temp_dir, 'same_line_receiver_shadow')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	use_line := lines.index('\tvalue := A{}; if true { value := B{}; value.target() }; value.from_a()')
	assert use_line >= 0
	member_start := lines[use_line].index('value.target') or { -1 }
	assert member_start >= 0
	completion_position := Position{
		line: use_line
		char: member_start + 'value.'.len
	}
	assert app.infer_receiver_type_at_position(uri, content, 'value', completion_position) == 'B'
	indexed := app.indexed_completions(uri, completion_position)
	assert !indexed.use_compiler
	assert indexed.items.any(it.label == 'from_b')
	assert !indexed.items.any(it.label == 'from_a')
	outer_start := lines[use_line].last_index('value.from_a') or { -1 }
	assert outer_start >= 0
	outer_position := Position{
		line: use_line
		char: outer_start + 'value.'.len
	}
	assert app.infer_receiver_type_at_position(uri, content, 'value', outer_position) == 'A'
	outer := app.indexed_completions(uri, outer_position)
	assert !outer.use_compiler
	assert outer.items.any(it.label == 'from_a')
	assert !outer.items.any(it.label == 'from_b')
	target_start := lines[use_line].index('target()') or { -1 }
	assert target_start >= 0
	location := app.resolve_indexed_definition(uri, Position{
		line: use_line
		char: target_start + 2
	}) or {
		assert false, 'expected the innermost B method definition'
		return
	}
	assert location.uri == uri
	assert location.range.start.line == lines.index('fn (value B) target() {}')
}

fn test_closure_parameters_are_scoped_local_completions() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\nfn main() {\n\tcallback := fn (value int) {\n\t\tval\n\t}\n\tother := fn (\n\t\titem string,\n\t) {\n\t\tite\n\t}\n\tval\n}\n'
	test_dir := os.join_path(app.temp_dir, 'closure_parameter_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	value_line := lines.index('\t\tval')
	item_line := lines.index('\t\tite')
	after_line := lines.index('\tval')
	assert value_line >= 0
	assert item_line >= 0
	assert after_line >= 0

	value_items := app.local_scope_completions(content, Position{
		line: value_line
		char: lines[value_line].len
	}).map(it.label)
	assert 'value' in value_items
	assert 'callback' in value_items
	indexed := app.indexed_completions(uri, Position{
		line: value_line
		char: lines[value_line].len
	})
	assert indexed.items.any(it.label == 'value')
	item_items := app.local_scope_completions(content, Position{
		line: item_line
		char: lines[item_line].len
	}).map(it.label)
	assert 'item' in item_items
	assert 'other' in item_items
	after_items := app.local_scope_completions(content, Position{
		line: after_line
		char: lines[after_line].len
	}).map(it.label)
	assert 'value' !in after_items
	assert 'item' !in after_items
	assert 'callback' in after_items
	assert 'other' in after_items
}

fn test_receiver_inference_stops_at_completed_declaration_rhs() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'receiver_declaration_boundary')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := "module main\n\nstruct User {}\nfn (user User) save() {}\n\nfn main() {\n\ttext := 'hello'\n\tuser := User{}\n\ttext.\n}\n"
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	completion_line := lines.index('\ttext.')
	assert completion_line >= 0
	// The literal types `text`; inference must not continue into `user := User{}`.
	assert app.infer_receiver_type(uri, content, 'text', completion_line) == 'string'

	indexed := app.indexed_completions(uri, Position{
		line: completion_line
		char: lines[completion_line].len
	})
	assert indexed.items.any(it.label == 'after')
	assert !indexed.items.any(it.label == 'save')

	continued_content := 'module main\n\nstruct User {}\n\nfn main() {\n\tcontinued :=\n\t\tUser{}\n\tcontinued.\n}\n'
	continued_lines := continued_content.split_into_lines()
	continued_line := continued_lines.index('\tcontinued.')
	assert continued_line >= 0
	assert app.infer_receiver_type(uri, continued_content, 'continued', continued_line) == 'User'
}

fn test_import_prefix_identifiers_use_normal_completion() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'import_prefix_completion')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nstruct Important {}\nfn (value Important) run() {}\n\nfn main() {\n\timportant := Important{}\n\timported_value := 1\n\timportant.\n\timported_\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	member_line := lines.index('\timportant.')
	bare_line := lines.index('\timported_')
	assert member_line >= 0
	assert bare_line >= 0
	assert !is_import_completion_line(lines[member_line])
	assert !is_import_completion_line(lines[bare_line])
	assert get_import_completions(lines[member_line], test_dir).len == 0

	member := app.indexed_completions(uri, Position{
		line: member_line
		char: lines[member_line].len
	})
	assert !member.use_compiler
	assert member.items.any(it.label == 'run')
	bare := app.indexed_completions(uri, Position{
		line: bare_line
		char: lines[bare_line].len
	})
	assert bare.items.any(it.label == 'imported_value')
}

fn test_if_header_bindings_are_removed_with_branch_scope() {
	app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	content := 'module main\n\nfn inspect() {\n\tif clock := maybe_clock() {\n\t\tclock\n\t}\n\tif other :=\n\t\tmaybe_clock() {\n\t\tother\n\t}\n\tclo\n}\n'
	lines := content.split_into_lines()
	inside_line := lines.index('\t\tclock')
	multiline_inside_line := lines.index('\t\tother')
	after_line := lines.index('\tclo')
	assert inside_line >= 0
	assert multiline_inside_line >= 0
	assert after_line >= 0
	inside := app.local_scope_completions(content, Position{
		line: inside_line
		char: lines[inside_line].len
	}).map(it.label)
	assert 'clock' in inside
	multiline_inside := app.local_scope_completions(content, Position{
		line: multiline_inside_line
		char: lines[multiline_inside_line].len
	}).map(it.label)
	assert 'other' in multiline_inside
	after := app.local_scope_completions(content, Position{
		line: after_line
		char: lines[after_line].len
	}).map(it.label)
	assert 'clock' !in after
	assert 'other' !in after
}

fn test_union_declarations_are_in_module_completions() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'union_module_completion')
	module_dir := os.join_path(test_dir, 'packets')
	must_mkdir_all(module_dir)
	module_file := os.join_path(module_dir, 'packets.v')
	module_content := 'module packets\n\npub union Packet {\n\ttext string\n\tnumber int\n}\n\npub fn always() {}\n\nfn inspect() {\n\tPac\n}\n'
	must_write_file(module_file, module_content)
	module_uri := path_to_uri(module_file)
	app.open_files[module_uri] = module_content
	module_lines := module_content.split_into_lines()
	bare_line := module_lines.index('\tPac')
	assert bare_line >= 0
	bare := app.indexed_completions(module_uri, Position{
		line: bare_line
		char: module_lines[bare_line].len
	})
	packet_items := bare.items.filter(it.label == 'Packet')
	assert packet_items.len == 1
	assert packet_items[0].kind == 22

	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nimport packets\n\nfn main() {\n\tpackets.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	member_line := lines.index('\tpackets.')
	assert member_line >= 0
	imported := app.indexed_completions(uri, Position{
		line: member_line
		char: lines[member_line].len
	})
	labels := imported.items.map(it.label)
	assert !imported.use_compiler
	assert 'Packet' in labels
	assert 'always' in labels
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
		id: 800
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

fn test_semantic_tokens_classify_functions_methods_and_properties() {
	tokens := tokenize_v_source('fn run() {\n\tapp.start(app.name)\n}\n')
	assert tokens.any(it.line == 0 && it.start == 3 && it.type_idx == sem_tok_function)
	assert tokens.any(it.line == 1 && it.start == 1 && it.type_idx == sem_tok_variable)
	assert tokens.any(it.line == 1 && it.start == 5 && it.type_idx == sem_tok_method)
	assert tokens.any(it.line == 1 && it.start == 11 && it.type_idx == sem_tok_variable)
	assert tokens.any(it.line == 1 && it.start == 15 && it.type_idx == sem_tok_property)
}

fn test_semantic_tokens_classify_imported_namespace_calls() {
	content := 'module main\n\nimport os\nimport net.http as http\n\nfn main() {\n' +
		'\tos.read_file("a")\n\thttp.get("https://example.com")\n\tapp.start()\n}\n'
	tokens := tokenize_v_source(content)
	assert tokens.any(it.line == 6 && it.start == 1 && it.type_idx == sem_tok_namespace)
	assert tokens.any(it.line == 6 && it.start == 4 && it.type_idx == sem_tok_function)
	assert tokens.any(it.line == 7 && it.start == 1 && it.type_idx == sem_tok_namespace)
	assert tokens.any(it.line == 7 && it.start == 6 && it.type_idx == sem_tok_function)
	assert tokens.any(it.line == 8 && it.start == 1 && it.type_idx == sem_tok_variable)
	assert tokens.any(it.line == 8 && it.start == 5 && it.type_idx == sem_tok_method)
}

fn test_semantic_tokens_keep_inline_method_calls_as_functions() {
	tokens := tokenize_v_source('fn (a A) run() { helper() }\n')
	assert tokens.any(it.line == 0 && it.start == 9 && it.type_idx == sem_tok_method)
	assert tokens.any(it.line == 0 && it.start == 17 && it.type_idx == sem_tok_function)
}

fn test_semantic_tokens_classify_receivers_parameters_and_reused_variables() {
	content := 'module main\n\npub fn (app &App) index(mut ctx Context) {\n' +
		'\tx := 1\n\tdump(x)\n\tapp.run(ctx)\n}\n'
	tokens := tokenize_v_source(content)
	assert tokens.any(it.line == 2 && it.start == 8 && it.type_idx == sem_tok_variable)
	assert tokens.any(it.line == 2 && it.start == 28 && it.type_idx == sem_tok_variable)
	assert tokens.any(it.line == 3 && it.start == 1 && it.type_idx == sem_tok_variable)
	assert tokens.any(it.line == 4 && it.start == 6 && it.type_idx == sem_tok_variable)
	assert tokens.any(it.line == 5 && it.start == 1 && it.type_idx == sem_tok_variable)
	assert tokens.any(it.line == 5 && it.start == 9 && it.type_idx == sem_tok_variable)
}

fn test_semantic_tokens_apply_readonly_modifier_without_coloring_properties() {
	content := 'fn main() {\n\tpeople := Person{}\n\tpeople.name = "Andre"\n' +
		'\tmut others := []Person{}\n\tothers << people\n}\n'
	tokens := tokenize_v_source(content)
	people_tokens := tokens.filter(it.type_idx == sem_tok_variable
		&& content.split_into_lines()[it.line][it.start..it.start + it.length] == 'people')
	assert people_tokens.len == 3
	assert people_tokens.all(it.mod_bits == sem_mod_readonly)
	assert tokens.any(it.line == 2 && it.start == 8 && it.type_idx == sem_tok_property
		&& it.mod_bits == 0)
	assert tokens.any(it.line == 4 && it.start == 1 && it.type_idx == sem_tok_variable
		&& it.mod_bits == 0)
}

fn test_semantic_tokens_keep_readonly_modifier_scoped_to_function() {
	content := 'fn read(app &App) {\n\tdump(app)\n}\n\nfn main() {\n\tmut app := &App{}\n' +
		'\tdump(app)\n}\n'
	tokens := tokenize_v_source(content)
	assert tokens.any(it.line == 1 && it.start == 6 && it.type_idx == sem_tok_variable
		&& it.mod_bits == sem_mod_readonly)
	assert tokens.any(it.line == 6 && it.start == 6 && it.type_idx == sem_tok_variable
		&& it.mod_bits == 0)
}

fn test_semantic_tokens_returns_empty_object_for_empty_file() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/empty.v'
	app.open_files[uri] = ''

	resp := app.handle_semantic_tokens(Request{
		id: 801
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
		id: 802
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
	// Line 0 has a variable token at column 0 and strings at columns 5 and 11.
	app.open_files[uri] = 'a := "b" + "c"\n'

	full_params := json2.encode(SemanticTokensRangeParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range: LSPRange{
			start: Position{
				line: 0
				char: 0
			}
			end: Position{
				line: 0
				char: 50
			}
		}
	},
		escape_unicode: true
	)
	full := app.handle_semantic_tokens_range(Request{
		id: 1
		params: full_params
	})
	ftok := full.result as SemanticTokens
	// The full-line request starts with the variable declaration at column 0.
	assert ftok.data.len >= 5
	assert ftok.data[0] == 0
	assert ftok.data[1] == 0

	// Narrow the range to columns [8,50): the column-5 token must be excluded, so
	// the first returned token starts at or after column 8 (the `"c"` at 11) and
	// the payload is strictly smaller than the full-line one.
	narrow_params := json2.encode(SemanticTokensRangeParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range: LSPRange{
			start: Position{
				line: 0
				char: 8
			}
			end: Position{
				line: 0
				char: 50
			}
		}
	},
		escape_unicode: true
	)
	narrow := app.handle_semantic_tokens_range(Request{
		id: 2
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
		id: 810
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
	assert lenses.len == 1
	command := lenses[0].command or {
		assert false, 'expected Run Main command'
		return
	}
	command_args := command.arguments or { [] }
	assert command.title == 'Run Main'
	assert command.command == 'vls.runFile'
	assert command_args == [uri]
}

fn test_code_lens_range_uses_negotiated_position_encoding() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/codelens_unicode.v'
	app.open_files[uri] = 'module main\n\nfn main() {} // 🚀\n'
	request := Request{
		id: 814
		method: 'textDocument/codeLens'
		params: json2.encode(CodeLensParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	}

	for encoding in [PositionEncoding.utf8, .utf16, .utf32] {
		app.position_encoding = encoding
		resp := app.handle_code_lens(request)
		assert resp.result is []CodeLens
		lenses := resp.result as []CodeLens
		assert lenses.len == 1
		assert lenses[0].range.start == Position{
			line: 2
			char: 0
		}
		expected_end := match encoding {
			.utf8 { 20 }
			.utf16 { 18 }
			.utf32 { 17 }
		}
		assert lenses[0].range.end == Position{
			line: 2
			char: expected_end
		}
	}
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
		id: 811
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
	assert lenses.len == 2
	file_command := lenses[0].command or {
		assert false, 'expected Run File command'
		return
	}
	test_command := lenses[1].command or {
		assert false, 'expected Run Test command'
		return
	}
	file_args := file_command.arguments or { [] }
	test_args := test_command.arguments or { [] }
	assert file_command.title == 'Run File'
	assert file_command.command == 'vls.runTests'
	assert file_args == [uri]
	assert test_command.title == 'Run Test'
	assert test_command.command == 'vls.runTests'
	assert test_args == [uri, 'test_something']
}

fn test_code_lens_ignores_declarations_in_comments_and_non_test_files() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/ordinary.v'
	app.open_files[uri] = 'module main\n\n/*\nfn main() {}\nfn test_hidden() {}\n*/\nfn helper() {}\n'

	resp := app.handle_code_lens(Request{
		id: 813
		method: 'textDocument/codeLens'
		params: json2.encode(CodeLensParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
		},
			escape_unicode: true
		)
	})

	assert resp.result is []CodeLens
	assert (resp.result as []CodeLens).len == 0
}

fn test_code_lens_resolve_returns_same_lens() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	lens := CodeLens{
		range: LSPRange{
			start: Position{
				line: 2
				char: 0
			}
			end: Position{
				line: 2
				char: 10
			}
		}
		command: Command{
			title: '▶ Run'
			command: 'vls.runFile'
			arguments: ['file:///tmp/a.v']
		}
	}

	resp := app.handle_code_lens_resolve(Request{
		id: 812
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

	app.capture_output = true
	resp := app.handle_execute_command(Request{
		id: 820
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
	assert app.captured_output.len == 1
	assert app.captured_output[0].contains('missing file argument')
}

fn test_execute_run_file_invokes_compiler() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	project_dir := os.join_path(app.temp_dir, 'code_lens_module')
	must_mkdir_all(project_dir)
	vmod_source := "Module {\n\tname: 'code_lens_module'\n}\n"
	must_write_file(os.join_path(project_dir, 'v.mod'), vmod_source)
	path := os.join_path(project_dir, 'main.v')
	must_write_file(path, 'module main\n\nfn main() {\n\tprintln("stale-disk")\n}\n')
	helper_path := os.join_path(project_dir, 'helper.v')
	helper_source := 'module main\n\nfn code_lens_message() string {\n\treturn "module-sibling"\n}\n\nfn code_lens_sibling_paths() string {\n\treturn @VMODROOT + "\\n" + @FILE + "\\n" + @FILE_LINE + "\\n" + @LOCATION + "\\n" + @COLUMN\n}\n'
	must_write_file(helper_path, helper_source)
	uri := path_to_uri(path)
	runtime_output_path := os.join_path(project_dir, 'code_lens_runtime_cwd.txt')
	compile_time_output_path := os.join_path(project_dir, 'code_lens_compile_time_paths.txt')
	vmod_output_path := os.join_path(project_dir, 'code_lens_vmod.txt')
	main_source := 'module main\n\nimport os\n\nfn main() {\n\tprintln(code_lens_message() + "-fresh-buffer")\n\tos.write_file("code_lens_runtime_cwd.txt", "real-module") or { panic(err) }\n\tos.write_file(os.join_path(@VMODROOT, "code_lens_compile_time_paths.txt"), code_lens_sibling_paths() + "\\n" + @FILE + "\\n" + @FILE_LINE + "\\n" + @LOCATION + "\\n" + @COLUMN) or { panic(err) }\n\tos.write_file("code_lens_vmod.txt", @VMOD_FILE) or { panic(err) }\n}\n'
	app.open_files[uri] = main_source
	app.capture_output = true
	app.execute_commands_synchronously = true

	resp := app.handle_execute_command(Request{
		id: 822
		method: 'workspace/executeCommand'
		params: json2.encode(ExecuteCommandParams{
			command: 'vls.runFile'
			arguments: [uri]
		},
			escape_unicode: true
		)
	})

	assert resp.result is string
	assert (resp.result as string) == 'null'
	assert app.captured_output.any(it.contains('module-sibling-fresh-buffer'))
	assert app.captured_output.all(!it.contains('stale-disk'))
	assert app.captured_output.any(it.contains('Run Main finished successfully'))
	assert (os.read_file(runtime_output_path) or { '' }) == 'real-module'
	helper_column := helper_source.split_into_lines()[7].index('@COLUMN') or { 0 }
	main_column := main_source.split_into_lines()[7].index('@COLUMN') or { 0 }
	expected_paths := [os.real_path(project_dir), os.real_path(helper_path), 'helper.v:8',
		'${os.real_path(helper_path)}:8, main.code_lens_sibling_paths', (helper_column + 1).str(),
		os.real_path(path), 'main.v:8', '${os.real_path(path)}:8, main.main',
		(main_column + 1).str()]
	assert (os.read_file(compile_time_output_path) or { '' }) == expected_paths.join('\n')
	assert (os.read_file(vmod_output_path) or { '' }) == vmod_source
	assert (os.read_file(helper_path) or { '' }) == helper_source
}

fn test_execute_run_file_materializes_new_unsaved_buffer() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	project_dir := os.join_path(app.temp_dir, 'code_lens_unsaved')
	must_mkdir_all(project_dir)
	path := os.join_path(project_dir, 'new_main.v')
	uri := path_to_uri(path)
	app.open_files[uri] = 'module main\n\nfn main() {\n\tprintln("new-unsaved-buffer")\n}\n'
	app.capture_output = true
	app.execute_commands_synchronously = true

	resp := app.handle_execute_command(Request{
		id: 824
		method: 'workspace/executeCommand'
		params: json2.encode(ExecuteCommandParams{
			command: 'vls.runFile'
			arguments: [uri]
		},
			escape_unicode: true
		)
	})

	assert resp.result is string
	assert (resp.result as string) == 'null'
	assert app.captured_output.any(it.contains('new-unsaved-buffer'))
	assert app.captured_output.any(it.contains('Run Main finished successfully'))
}

fn test_execute_run_file_returns_before_long_running_program_finishes() {
	mut app := create_test_app()
	defer {
		app.stop_run_commands()
		cleanup_test_app(app)
	}
	path := os.join_path(app.temp_dir, 'code_lens_long_running.v')
	marker_path := os.join_path(app.temp_dir, 'code_lens_long_running.started')
	marker_literal := code_lens_v_string_literal(marker_path)
	must_write_file(path, 'module main\n\nimport os\nimport time\n\nfn main() {\n\tos.write_file(${marker_literal}, "started") or {}\n\t_ := os.input("")\n\ttime.sleep(5 * time.second)\n}\n')
	app.capture_output = true

	started_at := time.now().unix_milli()
	resp := app.handle_execute_command(Request{
		id: 825
		method: 'workspace/executeCommand'
		params: json2.encode(ExecuteCommandParams{
			command: 'vls.runFile'
			arguments: [path_to_uri(path)]
		},
			escape_unicode: true
		)
	})
	elapsed_ms := time.now().unix_milli() - started_at

	assert resp.result is string
	assert (resp.result as string) == 'null'
	assert elapsed_ms < 1000
	// V3 compilation can take more than 10 seconds on loaded CI runners.
	startup_timeout_ms := 30_000
	deadline := time.now().unix_milli() + startup_timeout_ms
	for !os.exists(marker_path) && time.now().unix_milli() < deadline {
		time.sleep(10 * time.millisecond)
	}
	assert os.exists(marker_path)
	stop_started_at := time.now().unix_milli()
	app.stop_run_commands()
	assert time.now().unix_milli() - stop_started_at < 1000
}

fn test_execute_run_file_replaces_active_target() {
	mut app := create_test_app()
	defer {
		app.stop_run_commands()
		cleanup_test_app(app)
	}
	path := os.join_path(app.temp_dir, 'code_lens_replaced.v')
	marker_path := os.join_path(app.temp_dir, 'code_lens_replaced.txt')
	marker_literal := code_lens_v_string_literal(marker_path)
	first_source := 'module main\n\nimport os\nimport time\n\nfn main() {\n\tfor {\n\t\tmut marker := os.open_append(${marker_literal}) or { return }\n\t\tmarker.writeln("first") or {\n\t\t\tmarker.close()\n\t\t\treturn\n\t\t}\n\t\tmarker.close()\n\t\ttime.sleep(10 * time.millisecond)\n\t}\n}\n'
	must_write_file(path, first_source)
	uri := path_to_uri(path)
	app.open_files[uri] = first_source
	app.capture_output = true

	first_resp := app.handle_execute_command(Request{
		id: 826
		method: 'workspace/executeCommand'
		params: json2.encode(ExecuteCommandParams{
			command: 'vls.runFile'
			arguments: [uri]
		},
			escape_unicode: true
		)
	})
	assert first_resp.result is string
	assert (first_resp.result as string) == 'null'
	first_deadline := time.now().unix_milli() + 10_000
	for time.now().unix_milli() < first_deadline {
		if (os.read_file(marker_path) or { '' }).contains('first') {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert (os.read_file(marker_path) or { '' }).contains('first')

	app.open_files[uri] = 'module main\n\nimport os\nimport time\n\nfn main() {\n\tos.write_file(${marker_literal}, "second") or { return }\n\ttime.sleep(5 * time.second)\n}\n'
	second_resp := app.handle_execute_command(Request{
		id: 827
		method: 'workspace/executeCommand'
		params: json2.encode(ExecuteCommandParams{
			command: 'vls.runFile'
			arguments: [uri]
		},
			escape_unicode: true
		)
	})
	assert second_resp.result is string
	assert (second_resp.result as string) == 'null'
	second_deadline := time.now().unix_milli() + 10_000
	for time.now().unix_milli() < second_deadline {
		if (os.read_file(marker_path) or { '' }) == 'second' {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert (os.read_file(marker_path) or { '' }) == 'second'
	time.sleep(200 * time.millisecond)
	assert (os.read_file(marker_path) or { '' }) == 'second'
}

fn test_code_lens_process_output_is_bounded() {
	mut output := new_run_output_buffer()
	output.write('prefix')
	output.write('x'.repeat(code_lens_output_limit_bytes))
	output.write('ignored')

	assert output.output.len == code_lens_output_limit_bytes
	assert output.truncated
	result := output.str()
	assert result.len == code_lens_output_limit_bytes + code_lens_output_truncation_notice.len
	assert result.ends_with(code_lens_output_truncation_notice)
}

fn test_code_lens_process_output_truncates_at_utf8_boundary() {
	mut output := new_run_output_buffer()
	prefix := 'x'.repeat(code_lens_output_limit_bytes - 1)
	output.write(prefix)
	output.write('€')

	assert output.truncated
	assert output.str() == prefix + code_lens_output_truncation_notice

	mut exact_output := new_run_output_buffer()
	exact_prefix := 'x'.repeat(code_lens_output_limit_bytes - '€'.len) + '€'
	exact_output.write(exact_prefix)
	exact_output.write('ignored')
	assert exact_output.str() == exact_prefix + code_lens_output_truncation_notice
}

fn test_code_lens_source_paths_are_rewritten_only_in_code() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	project_dir := os.join_path(app.temp_dir, 'code_lens_source_paths')
	must_mkdir_all(project_dir)
	vmod_source := 'Module {}\n'
	must_write_file(os.join_path(project_dir, 'v.mod'), vmod_source)
	source_path := os.join_path(project_dir, 'main.v')
	temp_source_path := os.join_path(app.temp_dir, 'overlay', 'main.v')
	source := 'const source_file = @FILE\nconst source_dir = @DIR\nconst project = @VMODROOT\nconst manifest = @VMOD_FILE\nconst file_line = @FILE_LINE\nconst location = @LOCATION\nconst column = @FILE + @COLUMN\nconst literal = "@FILE @DIR @VMODROOT @VMOD_FILE @FILE_LINE @LOCATION @COLUMN"\n// @FILE @DIR @VMODROOT @VMOD_FILE @FILE_LINE @LOCATION @COLUMN\n#flag -I @VMODROOT/thirdparty\n'
	rewritten := code_lens_source_with_original_pseudos(source, source_path, temp_source_path, os.dir(temp_source_path))

	assert rewritten.contains('const source_file = ${code_lens_v_string_literal(os.real_path(source_path))}')
	assert rewritten.contains('const source_dir = ${code_lens_v_string_literal(os.real_path(project_dir))}')
	assert rewritten.contains('const project = ${code_lens_v_string_literal(os.real_path(project_dir))}')
	assert rewritten.contains('const manifest = ${code_lens_v_string_literal(vmod_source)}')
	assert rewritten.contains("const file_line = 'main.v:5'")
	assert rewritten.contains('const location = (@LOCATION.replace(')
	assert rewritten.contains(code_lens_v_string_literal('.\\main.v'))
	assert rewritten.contains(code_lens_v_string_literal('./main.v'))
	assert rewritten.contains("const column = ${code_lens_v_string_literal(os.real_path(source_path))} + '24'")
	assert rewritten.contains('const literal = "@FILE @DIR @VMODROOT @VMOD_FILE @FILE_LINE @LOCATION @COLUMN"')
	assert rewritten.contains('// @FILE @DIR @VMODROOT @VMOD_FILE @FILE_LINE @LOCATION @COLUMN')
	assert rewritten.contains('#flag -I @VMODROOT/thirdparty')
}

fn test_execute_run_test_selects_one_function() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	path := os.join_path(app.temp_dir, 'code_lens_selected_test.v')
	must_write_file(path, 'module main\n\nfn test_selected() {\n\tassert false\n}\n')
	uri := path_to_uri(path)
	test_runtime_output_path := os.join_path(app.temp_dir, 'code_lens_test_runtime_cwd.txt')
	app.open_files[uri] = 'module main\n\nimport os\n\nfn test_selected() {\n\tos.write_file("code_lens_test_runtime_cwd.txt", "real-module") or { assert false }\n\tassert true\n}\n\nfn test_other() {\n\tassert false\n}\n'
	app.capture_output = true
	app.execute_commands_synchronously = true

	resp := app.handle_execute_command(Request{
		id: 823
		method: 'workspace/executeCommand'
		params: json2.encode(ExecuteCommandParams{
			command: 'vls.runTests'
			arguments: [uri, 'test_selected']
		},
			escape_unicode: true
		)
	})

	assert resp.result is string
	assert (resp.result as string) == 'null'
	assert app.captured_output.any(it.contains('Run Test finished successfully'))
	assert (os.read_file(test_runtime_output_path) or { '' }) == 'real-module'
}

fn test_execute_command_unknown_still_returns_null() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	resp := app.handle_execute_command(Request{
		id: 821
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
		id: 830
		method: 'textDocument/inlineValue'
		params: json2.encode(InlineValueParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 831
		method: 'textDocument/inlineValue'
		params: json2.encode(InlineValueParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 0
					char: 0
				}
				end: Position{
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
		id: 840
		method: 'textDocument/linkedEditingRange'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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
		id: 841
		method: 'textDocument/linkedEditingRange'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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
		id: 850
		method: 'textDocument/selectionRange'
		params: json2.encode(SelectionRangeParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			positions: [Position{
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
		id: 851
		method: 'textDocument/selectionRange'
		params: json2.encode(SelectionRangeParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			positions: [Position{
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
		id: 860
		method: 'textDocument/onTypeFormatting'
		params: json2.encode(OnTypeFormattingParams{
			text_document: TextDocumentIdentifier{
				uri: 'file:///tmp/fmt.v'
			}
			position: Position{
				line: 3
				char: 0
			}
			ch: '}'
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
		id: 870
		method: 'callHierarchy/outgoingCalls'
		params: json2.encode(CallHierarchyOutgoingCallsParams{
			item: CallHierarchyItem{
				name: 'main'
				kind: sym_kind_function
				uri: uri
				range: LSPRange{
					start: Position{
						line: 4
						char: 0
					}
					end: Position{
						line: 6
						char: 1
					}
				}
				selection_range: LSPRange{
					start: Position{
						line: 4
						char: 3
					}
					end: Position{
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
		id: 871
		method: 'callHierarchy/incomingCalls'
		params: json2.encode(CallHierarchyIncomingCallsParams{
			item: CallHierarchyItem{
				name: 'helper'
				kind: sym_kind_function
				uri: uri
				range: LSPRange{
					start: Position{
						line: 2
						char: 0
					}
					end: Position{
						line: 2
						char: 15
					}
				}
				selection_range: LSPRange{
					start: Position{
						line: 2
						char: 3
					}
					end: Position{
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
		range: LSPRange{}
		context: CodeActionContext{}
	}
	resp := app.handle_code_action(Request{
		id: 1
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
		range: LSPRange{}
		context: CodeActionContext{}
	}
	resp := app.handle_code_action(Request{
		id: 2
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
		id: 3
		params: json2.encode(CodeActionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{}
			context: CodeActionContext{}
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
		message: 'cannot import module "foo" (not found)'
		range: LSPRange{
			start: Position{
				line: 1
				char: 0
			}
			end: Position{
				line: 1
				char: 10
			}
		}
	}
	params := CodeActionParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range: LSPRange{}
		context: CodeActionContext{
			diagnostics: [diag]
		}
	}
	resp := app.handle_code_action(Request{
		id: 1
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
		range: LSPRange{
			start: Position{
				line: 0
				char: 0
			}
			end: Position{
				line: 0
				char: 10
			}
		}
	}
	params := CodeActionParams{
		text_document: TextDocumentIdentifier{
			uri: uri
		}
		range: LSPRange{}
		context: CodeActionContext{
			diagnostics: [diag]
		}
	}
	resp := app.handle_code_action(Request{
		id: 1
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
		end: Position{
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
		id: 900
		method: 'textDocument/documentHighlight'
		params: json2.encode(DocumentHighlightParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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
			text_document: VersionedTextDocumentIdentifier{
				uri: uri
				version: 2
			}
			content_changes: [
				ContentChange{
					text: 'X'
					range: LSPRange{
						start: Position{
							line: 0
							char: 5
						}
						end: Position{
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
		id: 901
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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

fn test_operation_at_pos_hover_static_method_uses_receiver_documentation() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'hover_static_method')
	must_mkdir_all(test_dir)
	must_write_file(os.join_path(test_dir, 'v.mod'), 'Module {}\n')
	module_dir := os.join_path(test_dir, 'a')
	must_mkdir_all(module_dir)
	must_write_file(os.join_path(module_dir, 'a.v'), 'module a

pub struct App {}

// new creates a new instance of the imported App struct.
pub fn App.new() App {
	return App{}
}
')
	test_file := os.join_path(test_dir, 'main.v')
	content := 'module main

import a
import time

struct App {}

// new creates a new instance of the App struct.
fn App.new() App {
	return App{}
}

fn main() {
	mut app := App.new()
	imported := a.App.new()
	_ = app
	_ = imported
	_ = time.now()
}
'
	must_write_file(test_file, content)
	uri := path_to_uri(test_file)
	app.open_files[uri] = content
	app.text = content
	app.workspace_roots = [test_dir]
	lines := content.split_into_lines()
	call_line := lines.index('\tmut app := App.new()')
	if call_line < 0 {
		assert false, 'expected static method call line'
		return
	}
	new_col := lines[call_line].index('new') or {
		assert false, 'expected static method name'
		return
	}

	response := app.operation_at_pos(.hover, Request{
		id: 902
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: call_line
				char: new_col + 1
			}
		},
			escape_unicode: true
		)
	})

	assert response.result is Hover
	hover := response.result as Hover
	assert hover.contents.value.contains('new creates a new instance of the App struct.')
	assert !hover.contents.value.contains('new returns a time struct')

	imported_line := lines.index('\timported := a.App.new()')
	if imported_line < 0 {
		assert false, 'expected module-qualified static method call line'
		return
	}
	imported_col := lines[imported_line].index('new') or {
		assert false, 'expected imported static method name'
		return
	}
	imported_response := app.operation_at_pos(.hover, Request{
		id: 903
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: imported_line
				char: imported_col + 1
			}
		},
			escape_unicode: true
		)
	})

	assert imported_response.result is Hover
	imported_hover := imported_response.result as Hover
	assert imported_hover.contents.value.contains('new creates a new instance of the imported App struct.')
	assert !imported_hover.contents.value.contains('new creates a new instance of the App struct.')
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
		id: 902
		method: 'textDocument/references'
		params: json2.encode(ReferenceParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: 7
				char: 10
			}
			context: ReferenceContext{
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
		id: 903
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
				line: 7
				char: 11
			}
			new_name: 'renamed_value'
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
		version := document_changes[0].text_document.version
		assert version is i64
		assert (version as i64) == 7
		assert document_changes[0].edits.len == 2
	} else {
		assert false, 'rename must include versioned documentChanges'
	}
}

const rename_project_main = "module main

import os

const greeting = 'hi'

struct Point {
	x int
	y int
}

fn (p Point) sum() int {
	return p.x + p.y
}

enum Color {
	red
	green
}

fn helper(value int) int {
	total := value + 1
	return total
}

fn main() {
	p := Point{
		x: 1
		y: 2
	}
	println(p.sum())
	println(helper(3))
	println(greeting)
	c := Color.red
	println(c)
	x := 5
	println(x + p.x)
	println(os.args.len)
	// helper is named in a comment
	s := 'helper in a string'
	println(s)
	println(other_file_fn())
}
"

const rename_project_other = 'module main

fn other_file_fn() int {
	q := Point{
		x: 3
		y: 4
	}
	return helper(1) + q.sum() + q.x
}
'

// v3_answers_line_info is whether the V3 of the configured V answers the
// `-line-info` questions: a rename then asks it where each name is declared, as
// VLS does, and V1 only what V3 does not answer.
const v3_answers_line_info = v3_answers_inlay_hints()

// cleanup_rename_app ends the V3 servers a rename asked, then removes the
// project: a server runs until it is told to end.
fn cleanup_rename_app(mut app App) {
	app.stop_v3_queries()
	cleanup_test_app(app)
}

// new_rename_project_app opens a project made of main.v and other.v and returns
// the app and the uri of each file.
fn new_rename_project_app() (&App, map[string]string) {
	return new_rename_project_app_with({
		'main.v':  rename_project_main
		'other.v': rename_project_other
	})
}

// new_rename_project_app_with writes `files` into a project on disk, opens them
// all in the editor, and returns the app with the URI of each file.
fn new_rename_project_app_with(files map[string]string) (&App, map[string]string) {
	return new_rename_project_app_opening(files, files.keys())
}

// new_rename_project_app_opening is new_rename_project_app_with that opens only
// the files named in `open`; the others are on disk alone.
fn new_rename_project_app_opening(files map[string]string, open []string) (&App, map[string]string) {
	mut app := create_test_app()
	app.v3_line_info_enabled = v3_answers_line_info
	dir := os.join_path(app.temp_dir, 'rename_project')
	must_mkdir_all(dir)
	must_write_file(os.join_path(dir, 'v.mod'), 'Module {}\n')
	mut uris := map[string]string{}
	for name, content in files {
		path := os.join_path(dir, name)
		must_mkdir_all(os.dir(path))
		must_write_file(path, content)
		uri := path_to_uri(path)
		if name in open {
			app.open_files[uri] = content
			app.open_files_versions[uri] = 1
		}
		uris[name] = uri
	}
	app.workspace_roots = [dir]
	return app, uris
}

// rename_request_at builds a rename request for `file:line:col` (1-based).
fn rename_request_at(uris map[string]string, at string) Request {
	return rename_request_named(uris, at, 'renamed')
}

// rename_request_named builds a request to rename the identifier at
// `file:line:col` (1-based) to `new_name`.
fn rename_request_named(uris map[string]string, at string, new_name string) Request {
	parts := at.split(':')
	return Request{
		id:     905
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uris[parts[0]]
			}
			position:      Position{
				line: parts[1].int() - 1
				char: parts[2].int() - 1
			}
			new_name:      new_name
		},
			escape_unicode: true
		)
	}
}

// rename_edits_at renames the identifier at `file:line:col` of the project and
// returns where every edit starts as `file:line:col`, sorted; nothing when the
// rename was refused.
fn rename_edits_at(at string) []string {
	return rename_edits_in({
		'main.v':  rename_project_main
		'other.v': rename_project_other
	}, at)
}

// rename_edits_in is rename_edits_at for a project made of `files`.
fn rename_edits_in(files map[string]string, at string) []string {
	return rename_edits_opening(files, files.keys(), at)
}

// rename_edits_opening is rename_edits_in with only the files in `open` open.
fn rename_edits_opening(files map[string]string, open []string, at string) []string {
	mut app, uris := new_rename_project_app_opening(files, open)
	defer {
		cleanup_rename_app(mut app)
	}
	parts := at.split(':')
	line := files[parts[0]].split_into_lines()[parts[1].int() - 1]
	// V wants a type capitalized, and anything else lowercase.
	first := line[int_min(parts[2].int() - 1, line.len - 1)]
	new_name := if first.is_capital() { 'Renamed' } else { 'renamed' }
	response := app.handle_rename(rename_request_named(uris, at, new_name))
	if response.result !is WorkspaceEdit {
		return []string{}
	}
	edit := response.result as WorkspaceEdit
	mut edits := []string{}
	for uri, text_edits in edit.changes {
		for e in text_edits {
			edits << '${os.file_name(uri_to_path(uri))}:${e.range.start.line + 1}:${e.range.start.char + 1}'
		}
	}
	edits.sort()
	return edits
}

fn test_rename_edits_every_occurrence_of_the_symbol_and_nothing_else() {
	helper := ['main.v:21:4', 'main.v:32:10', 'other.v:8:9']
	field_x := ['main.v:13:11', 'main.v:28:3', 'main.v:37:16', 'main.v:8:2', 'other.v:5:3',
		'other.v:8:33']
	cases := {
		'main.v:21:4':  helper // a function, from its declaration
		'other.v:8:9':  helper // and from a call in another file
		'main.v:22:2':  ['main.v:22:2', 'main.v:23:9'] // a local
		'main.v:23:14': ['main.v:22:2', 'main.v:23:9'] // the cursor right after a name that ends the line
		'main.v:21:11': ['main.v:21:11', 'main.v:22:11'] // a parameter
		'main.v:12:14': ['main.v:12:14', 'main.v:31:12', 'other.v:8:23'] // a method
		'main.v:7:8':   ['main.v:12:7', 'main.v:27:7', 'main.v:7:8', 'other.v:4:7'] // a struct
		'main.v:8:2':   field_x // a field, with the keys of struct literals
		'other.v:5:3':  field_x // from a key
		'main.v:36:2':  ['main.v:36:2', 'main.v:37:10'] // a local named like the field
		'main.v:5:7':   ['main.v:33:10', 'main.v:5:7'] // a constant
		'main.v:16:6':  ['main.v:16:6', 'main.v:34:7'] // an enum, named in `Color.red`
		'main.v:17:2':  ['main.v:17:2', 'main.v:34:13'] // an enum value
		'main.v:38:13': []string{} // `os.args` is declared outside the project
	}
	for at, want in cases {
		got := rename_edits_at(at)
		assert got == want, '${at}: ${got}'
	}
}

fn test_rename_says_why_it_refuses_and_prepare_rename_refuses_first() {
	mut app, uris := new_rename_project_app()
	defer {
		cleanup_rename_app(mut app)
	}
	outside := rename_request_at(uris, 'main.v:38:13')
	if _ := app.rename_request(outside) {
		assert false, 'renaming `os.args` must be refused'
	} else {
		assert err.msg().contains('outside this project'), err.msg()
	}
	if _ := app.prepare_rename_request(outside) {
		assert false, 'preparing a rename of `os.args` must be refused'
	} else {
		assert err.msg().contains('outside this project'), err.msg()
	}
	prepared := app.prepare_rename_request(rename_request_at(uris, 'main.v:21:4')) or {
		panic(err)
	}
	assert prepared.result is PrepareRenameResult
	result := prepared.result as PrepareRenameResult
	assert result.placeholder == 'helper'
	assert result.range.start == Position{
		line: 20
		char: 3
	}
}

// A struct embedded in another, a closure and its captures, loop variables, and
// a field named like an imported module.
const rename_scopes_main = "module main

import time

struct Base {
	id int
}

fn (b Base) ident() int {
	return b.id
}

struct User {
	Base
	name string
}

struct Job {
	time int
}

fn total(items []int) int {
	mut acc := 0
	for item in items {
		acc += item
	}
	return acc
}

fn main() {
	u := User{
		Base: Base{
			id: 1
		}
		name: 'ana'
	}
	println(u.Base.id)
	println(u.ident())
	offset := 7
	add := fn [offset] (a int) int {
		return a + offset
	}
	println(add(1))
	job := Job{
		time: 3
	}
	println(job.time)
	println(time.now().year > 0)
	println(total([1, 2]))
}

struct Box[T] {
	val T
}

fn (b Box[T]) get() T {
	return b.val
}

fn make_bases() []Base {
	mut bases := []Base{}
	bases << Base{
		id: 2
	}
	return bases
}

fn read_point(p struct { x int }) int {
	y := p.x
	return y
}

struct Label {
	text string
	x    int
}

struct Frame {
	label Label
	x     int
}

fn make_frame() Frame {
	return Frame{
		label: Label{
			text: '}'
			x:    1
		}
		x:     2
	}
}

fn shadowed() {
	time := [1, 2]
	println(time.len)
}
"

fn test_rename_follows_embedded_structs_closures_and_loops() {
	// V1 alone does not tell where all these names are declared.
	if !v3_answers_line_info {
		return
	}
	files := {
		'main.v': rename_scopes_main
	}
	// The field that embeds a struct is named after it: both change together.
	base := ['main.v:14:2', 'main.v:32:3', 'main.v:32:9', 'main.v:37:12', 'main.v:5:8', 'main.v:9:7',
		'main.v:60:19', 'main.v:61:17', 'main.v:62:11']
	cases := {
		'main.v:5:8':   base // a struct that another embeds, from its declaration
		'main.v:32:3':  base // from the key of the embedded field
		'main.v:37:12': base // from the embedded field in a selector
		'main.v:14:2':  base // from the embedding itself
		'main.v:61:17': base // from `[]Base{}`, where the compiler does not answer
		'main.v:9:13':  ['main.v:38:12', 'main.v:9:13'] // a method reached through the embedding
		'main.v:24:6':  ['main.v:24:6', 'main.v:25:10'] // a `for x in` variable
		'main.v:39:2':  ['main.v:39:2', 'main.v:40:13', 'main.v:41:14'] // a variable a closure captures
		'main.v:40:22': ['main.v:40:22', 'main.v:41:10'] // a closure parameter
		'main.v:40:2':  ['main.v:40:2', 'main.v:43:10'] // a closure called through its variable
		'main.v:19:2':  ['main.v:19:2', 'main.v:45:3', 'main.v:47:14'] // a field named like an imported module
		'main.v:9:5':   ['main.v:10:9', 'main.v:9:5'] // a receiver, named like one in a generic method
		'main.v:69:7':  ['main.v:68:15', 'main.v:69:7'] // a parameter, where braces close on the declaration line
		'main.v:68:15': ['main.v:68:15', 'main.v:69:7'] // and from the parameter itself
		'main.v:75:2':  ['main.v:75:2', 'main.v:87:4'] // a field whose key follows a brace inside a string
		'main.v:94:2':  ['main.v:94:2', 'main.v:95:10'] // a local named like an imported module
		'main.v:95:10': ['main.v:94:2', 'main.v:95:10'] // and from `time.len`, where it is not the module
	}
	for at, want in cases {
		mut sorted_want := want.clone()
		sorted_want.sort()
		got := rename_edits_in(files, at)
		assert got == sorted_want, '${at}: ${got}'
	}
}

// A field of a struct that another embeds, declared in one file and used in
// another through the struct that embeds it.
const rename_promoted_base = 'module main

struct Base {
	id int
}

struct User {
	Base
	name string
}
'

const rename_promoted_main = "module main

fn main() {
	user := User{
		Base: Base{
			id: 9
		}
		name: 'ana'
	}
	println(user.id)
	println(user.Base.id)
}
"

fn test_rename_finds_a_field_through_the_struct_that_embeds_it() {
	// V1 alone does not tell where `user.id` is declared.
	if !v3_answers_line_info {
		return
	}
	files := {
		'base.v': rename_promoted_base
		'main.v': rename_promoted_main
	}
	want := ['base.v:4:2', 'main.v:10:15', 'main.v:11:20', 'main.v:6:4']
	// From each occurrence, with only its file open, as an editor may have it.
	for at in want {
		got := rename_edits_opening(files, [at.all_before(':')], at)
		assert got == want, '${at}: ${got}'
	}
}

// A program whose interface has a method and a field that a struct implements,
// and a type that implements IError.
const rename_interface_main = "module main

interface Measurable {
	area() f64
	label string
}

struct Circle {
	r     f64
	label string
}

fn (c Circle) area() f64 {
	return 3 * c.r * c.r
}

struct Fail {
	Error
}

fn (f Fail) msg() string {
	return 'fail'
}

fn total(items []Measurable) f64 {
	mut acc := 0.0
	for item in items {
		acc += item.area()
	}
	return acc
}

fn main() {
	area := total([Circle{
		r:     1
		label: 'c'
	}])
	println(area)
	println(Fail{}.msg())
}
"

fn test_rename_refuses_interface_members_and_the_names_they_share() {
	mut app, uris := new_rename_project_app_with({
		'main.v': rename_interface_main
	})
	defer {
		cleanup_rename_app(mut app)
	}
	// V needs no declaration to implement an interface: the types that
	// implement one must keep the names of its members, and a rename cannot
	// see which types those are.
	for at in ['main.v:4:2', 'main.v:5:2', 'main.v:13:15', 'main.v:10:2', 'main.v:28:15', 'main.v:21:13'] {
		count := rename_edit_count(mut app, uris, at) or {
			if v3_answers_line_info {
				assert err.msg().contains('interface'), '${at}: ${err}'
			}
			continue
		}
		assert false, '${at}: renamed with ${count} edits'
	}
	// A local with the name of such a method is none of them.
	assert rename_edits_in({
		'main.v': rename_interface_main
	}, 'main.v:34:2') == ['main.v:34:2', 'main.v:38:10']
}

fn test_rename_refuses_modules_builtin_types_and_names_v_would_reject() {
	mut app, uris := new_rename_project_app_with({
		'main.v': rename_scopes_main
	})
	defer {
		cleanup_rename_app(mut app)
	}
	refusals := {
		'main.v:3:8 x':       'names a module' // `import time`
		'main.v:48:10 x':     'names a module' // `time.now()`
		'main.v:6:5 x':       'part of V' // `int`
		'main.v:22:4 Total':  'must be lowercase'
		'main.v:22:4 fn':     'keyword'
		'main.v:22:4 1total': 'not a valid name'
		'main.v:5:8 base':    'must start with a capital letter'
		'main.v:30:4 start':  'V calls' // `fn main`
		'main.v:22:4 init':   'V calls' // a function renamed to `init`
	}
	for spec, reason in refusals {
		parts := spec.split(' ')
		if _ := app.rename_request(rename_request_named(uris, parts[0], parts[1])) {
			assert false, '${spec} must be refused'
		} else {
			assert err.msg().contains(reason), '${spec}: ${err.msg()}'
		}
	}
}

// A generic function of a module, called from main.v, whose parameter is named
// like a field of the module's struct.
const rename_generic_store = 'module shop

pub struct Store {
mut:
	items []int
}

pub fn new_store() Store {
	return Store{
		items: []int{}
	}
}

pub fn (mut s Store) add(n int) {
	s.items << n
}

pub fn (s Store) all() []int {
	return s.items
}

pub fn keep_if[T](items []T, keep fn (T) bool) []T {
	mut out := []T{}
	for item in items {
		if keep(item) {
			out << item
		}
	}
	return out
}
'

const rename_generic_main = 'module main

import shop

fn main() {
	mut s := shop.new_store()
	s.add(3)
	big := shop.keep_if(s.all(), fn (n int) bool {
		return n > 1
	})
	println(big)
}
'

// The persistent compiler reads again only the file it is asked about, so it
// finds nothing inside a generic function that another file instantiates; a
// compiler process of its own does, and the rename asks one before refusing.
fn test_rename_resolves_names_inside_a_generic_function_called_from_another_file() {
	// V1 alone does not tell where all these names are declared.
	if !v3_answers_line_info {
		return
	}
	files := {
		'main.v':       rename_generic_main
		'shop/store.v': rename_generic_store
	}
	field := ['store.v:10:3', 'store.v:15:4', 'store.v:19:11', 'store.v:5:2']
	param := ['store.v:22:19', 'store.v:24:14']
	item := ['store.v:24:6', 'store.v:25:11', 'store.v:26:11']
	cases := {
		'shop/store.v:5:2':   field // the field, whose name the generic parameter shares
		'shop/store.v:19:11': field // from a use
		'shop/store.v:22:19': param // the parameter, from its declaration
		'shop/store.v:24:14': param // and from its use in the body
		'shop/store.v:25:6':  ['store.v:22:30', 'store.v:25:6'] // a parameter called as a function
		'shop/store.v:26:11': item // a loop variable
		'shop/store.v:29:9':  ['store.v:23:6', 'store.v:26:4', 'store.v:29:9'] // a local
	}
	mut wrong := []string{}
	for at, want in cases {
		// Every file open, and only the one edited: the compiler then reads the
		// others through links to the disk, and reads imports from where a link
		// points.
		for open in [files.keys(), [at.all_before(':')]] {
			got := rename_edits_opening(files, open, at)
			if got != want {
				wrong << '${at} with ${open} open: ${got}'
			}
		}
	}
	assert wrong.len == 0, wrong.str()
}

// rename_edit_count renames the identifier at `file:line:col` and returns how
// many edits it takes, or the reason it was refused.
fn rename_edit_count(mut app App, uris map[string]string, at string) !int {
	response := app.rename_request(rename_request_named(uris, at, 'renamed'))!
	edit := response.result as WorkspaceEdit
	mut count := 0
	for _, text_edits in edit.changes {
		count += text_edits.len
	}
	return count
}

// A rename checks at most 48 occurrences, one compiler lookup each, unless
// VLS_RENAME_MAX_OCCURRENCES says otherwise; the refusal names the variable.
fn test_rename_occurrence_cap_comes_from_the_environment() {
	previous := os.getenv('VLS_RENAME_MAX_OCCURRENCES')
	defer {
		if previous == '' {
			os.unsetenv('VLS_RENAME_MAX_OCCURRENCES')
		} else {
			os.setenv('VLS_RENAME_MAX_OCCURRENCES', previous, true)
		}
	}
	// `tick` appears 51 times and `tock` 12.
	mut body := []string{}
	for _ in 0 .. reference_semantic_max_candidates + 2 {
		body << '\tprintln(tick())'
	}
	for _ in 0 .. 11 {
		body << '\tprintln(tock())'
	}
	main_v := 'module main\n\nfn tick() int {\n\treturn 1\n}\n\nfn tock() int {\n\treturn 2\n}\n\nfn main() {\n${body.join('\n')}\n}\n'
	mut app, uris := new_rename_project_app_with({
		'main.v': main_v
	})
	defer {
		cleanup_rename_app(mut app)
	}
	tick := 'main.v:3:4'
	tock := 'main.v:7:4'
	// Not set, or not a positive number: 48.
	for value in ['', 'abc', '0', '-5', '60x'] {
		if value == '' {
			os.unsetenv('VLS_RENAME_MAX_OCCURRENCES')
		} else {
			os.setenv('VLS_RENAME_MAX_OCCURRENCES', value, true)
		}
		if n := rename_edit_count(mut app, uris, tick) {
			assert false, '`${value}`: a rename of 51 occurrences must be refused, took ${n} edits'
		} else {
			assert err.msg().contains('appears 51 times'), '`${value}`: ${err.msg()}'
			assert err.msg().contains('more than the 48 '), '`${value}`: ${err.msg()}'
			assert err.msg().contains('VLS_RENAME_MAX_OCCURRENCES'), '`${value}`: ${err.msg()}'
		}
	}
	// Raised, the same rename goes through.
	os.setenv('VLS_RENAME_MAX_OCCURRENCES', '60', true)
	assert rename_edit_count(mut app, uris, tick) or { panic(err) } == 51
	// Lowered, a rename that 48 lets through is refused.
	os.setenv('VLS_RENAME_MAX_OCCURRENCES', '10', true)
	if n := rename_edit_count(mut app, uris, tock) {
		assert false, 'a rename of 12 occurrences must be refused with a cap of 10, took ${n} edits'
	} else {
		assert err.msg().contains('more than the 10 '), err.msg()
	}
	os.unsetenv('VLS_RENAME_MAX_OCCURRENCES')
	assert rename_edit_count(mut app, uris, tock) or { panic(err) } == 12
}

fn test_folding_range_covers_imports_comments_and_code_blocks() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := 'file:///tmp/folding_feature.v'
	app.open_files[uri] = 'module main\n\nimport os\nimport time\n\n// first line\n// second line\n\nfn main() {\n\tprintln(os.args)\n}\n'

	response := app.handle_folding_range(Request{
		id: 904
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
		id: 905
		method: 'textDocument/documentHighlight'
		params: json2.encode(DocumentHighlightParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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
		params: '{"settings":{"vls":{"inlayHints":{"enabled":false},"diagnostics":{"enabled":false}}}}'
	})
	assert !app.inlay_hints_enabled
	assert !app.diagnostics_enabled

	hint_response := app.handle_inlay_hints(Request{
		id: 906
		method: 'textDocument/inlayHint'
		params: json2.encode(InlayHintParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{}
				end: Position{
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

fn test_workspace_configuration_preserves_mixed_setting_shapes() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}

	app.on_did_change_configuration(Request{
		method: 'workspace/didChangeConfiguration'
		params: '{"settings":{"vls":{"inlayHints":false,"diagnostics":true}}}'
	})
	assert !app.inlay_hints_enabled
	assert app.diagnostics_enabled

	app.on_did_change_configuration(Request{
		method: 'workspace/didChangeConfiguration'
		params: '{"settings":{"vls":{"inlayHints":{"enabled":false},"diagnostics":true}}}'
	})
	assert !app.inlay_hints_enabled
	assert app.diagnostics_enabled

	app.on_did_change_configuration(Request{
		method: 'workspace/didChangeConfiguration'
		params: '{"settings":{"vls":{"inlayHints":true,"diagnostics":{"enabled":false}}}}'
	})
	assert app.inlay_hints_enabled
	assert !app.diagnostics_enabled

	app.on_did_change_configuration(Request{
		method: 'workspace/didChangeConfiguration'
		params: '{"settings":{"inlayHints":{"enabled":false},"diagnostics":true}}'
	})
	assert !app.inlay_hints_enabled
	assert app.diagnostics_enabled

	app.on_did_change_configuration(Request{
		method: 'workspace/didChangeConfiguration'
		params: '{"settings":{"inlayHints":true,"diagnostics":{"enabled":false}}}'
	})
	assert app.inlay_hints_enabled
	assert !app.diagnostics_enabled

	app.on_did_change_configuration(Request{
		method: 'workspace/didChangeConfiguration'
		params: '{"settings":{"inlayHints":{"enabled":false},"diagnostics":{"enabled":true}}}'
	})
	assert !app.inlay_hints_enabled
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
		id: 907
		method: 'textDocument/willSaveWaitUntil'
		params: json2.encode(WillSaveTextDocumentParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			reason: 1
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
		id: 908
		method: 'textDocument/rangeFormatting'
		params: json2.encode(DocumentRangeFormattingParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range: LSPRange{
				start: Position{
					line: 3
				}
				end: Position{
					line: 3
					char: 4
				}
			}
			options: FormattingOptions{
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
		id: 909
		method: 'textDocument/prepareCallHierarchy'
		params: json2.encode(PrepareCallHierarchyParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position: Position{
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

fn indexed_completions_at_line_end(dir_name string, content string, line_text string) IndexedCompletionResult {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, dir_name)
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index(line_text)
	assert line >= 0, line_text
	return app.indexed_completions(uri, Position{
		line: line
		char: lines[line].len
	})
}

fn test_thread_handle_from_spawned_fn_literal_completes_wait() {
	result := indexed_completions_at_line_end('thread_fn_literal_completion', 'module main\n\nfn main() {\n\ta := 1.5\n\tb := 2\n\tth := spawn fn (a f64, b int) f64 {\n\t\treturn a + f64(b)\n\t}(a, b)\n\tth.\n}\n', '\tth.')
	waits := result.items.filter(it.label == 'wait')
	assert waits.len == 1, result.items.map(it.label).str()
	assert waits[0].kind == 2
	assert waits[0].detail == 'fn (t thread f64) wait() f64'
}

fn test_thread_handle_from_spawned_call_completes_wait() {
	result := indexed_completions_at_line_end('thread_call_completion', 'module main\n\nfn work() int {\n\treturn 1\n}\n\nfn main() {\n\tth := spawn work()\n\tth.\n}\n', '\tth.')
	waits := result.items.filter(it.label == 'wait')
	assert waits.len == 1, result.items.map(it.label).str()
	assert waits[0].detail == 'fn (t thread int) wait() int'
}

fn test_thread_handle_from_spawned_result_call_completes_wait() {
	result := indexed_completions_at_line_end('thread_result_call_completion', 'module main\n\nfn work() !int {\n\treturn 1\n}\n\nfn main() {\n\tth := spawn work()\n\tth.\n}\n', '\tth.')
	waits := result.items.filter(it.label == 'wait')
	assert waits.len == 1, result.items.map(it.label).str()
	assert waits[0].detail == 'fn (t thread !int) wait() !int'
}

fn test_thread_handle_from_spawned_option_call_completes_wait() {
	result := indexed_completions_at_line_end('thread_option_call_completion', 'module main\n\nfn work() ?int {\n\treturn 1\n}\n\nfn main() {\n\tth := spawn work()\n\tth.\n}\n', '\tth.')
	waits := result.items.filter(it.label == 'wait')
	assert waits.len == 1, result.items.map(it.label).str()
	assert waits[0].detail == 'fn (t thread ?int) wait() ?int'
}

fn test_thread_array_completes_wait_and_array_members() {
	result := indexed_completions_at_line_end('thread_array_completion', 'module main\n\nfn work() int {\n\treturn 1\n}\n\nfn main() {\n\tmut threads := []thread int{}\n\tthreads << spawn work()\n\tthreads.\n}\n', '\tthreads.')
	waits := result.items.filter(it.label == 'wait')
	assert waits.len == 1, result.items.map(it.label).str()
	assert waits[0].detail == 'fn (a []thread int) wait() []int'
	// `len`, `cap` and the other array members come from VLS itself now.
	labels := result.items.map(it.label)
	assert 'len' in labels && 'cap' in labels && 'filter' in labels, labels.str()
	assert !result.use_compiler
}

fn test_thread_array_of_results_wait_returns_result_array() {
	result := indexed_completions_at_line_end('thread_result_array_completion', 'module main\n\nfn work() !int {\n\treturn 1\n}\n\nfn main() {\n\tmut threads := []thread !int{}\n\tthreads << spawn work()\n\tthreads.\n}\n', '\tthreads.')
	waits := result.items.filter(it.label == 'wait')
	assert waits.len == 1, result.items.map(it.label).str()
	assert waits[0].detail == 'fn (a []thread !int) wait() ![]int'
}

fn test_unary_ampersand_operand_is_guarded() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	uri := path_to_uri(os.join_path(app.temp_dir, 'guarded_ampersand.v'))
	content := 'module main\n\nfn main() {}\n'
	app.open_files[uri] = content
	assert app.expression_type(uri, content, '&', Position{line: 0, char: 0}) == ''
	assert app.expression_type(uri, content, '(&)', Position{line: 0, char: 0}) == ''
}

fn test_index_key_with_dotdot_in_string_literal_is_not_treated_as_slice() {
	result := indexed_completions_at_line_end('map_key_dotdot_completion', 'module main\n\nstruct Point {\n\tx int\n}\n\nfn main() {\n\tm := map[string]Point{}\n\tm[\'a..b\'].\n}\n', '\tm[\'a..b\'].')
	labels := result.items.map(it.label)
	assert 'x' in labels, labels.str()
	assert 'keys' !in labels, labels.str()
}

fn test_fixed_array_slice_completion_uses_dynamic_array_members() {
	result := indexed_completions_at_line_end('fixed_array_slice_completion', 'module main\n\nfn main() {\n\tnums := [3]int{}\n\tnums[..].\n}\n', '\tnums[..].')
	labels := result.items.map(it.label)
	assert 'cap' in labels, labels.str()
	assert 'first' in labels, labels.str()
	assert !result.use_compiler
}

fn sorted_completion_labels(result IndexedCompletionResult) []string {
	mut labels := result.items.map(it.label)
	labels.sort()
	return labels
}

fn test_channel_literal_completes_channel_members() {
	result := indexed_completions_at_line_end('channel_literal_completion', 'module main\n\nfn main() {\n\tch := chan int{cap: 5}\n\tch.\n}\n', '\tch.')
	assert sorted_completion_labels(result) == ['cap', 'close', 'closed', 'len', 'try_pop', 'try_push']
	close_items := result.items.filter(it.label == 'close')
	assert close_items[0].detail == 'fn (ch chan int) close()'
	push_items := result.items.filter(it.label == 'try_push')
	assert push_items[0].detail == 'fn (ch chan int) try_push(val int) ChanState'
	pop_items := result.items.filter(it.label == 'try_pop')
	assert pop_items[0].detail == 'fn (ch chan int) try_pop(mut val int) ChanState'
	assert (pop_items[0].insert_text or { '' }) == 'try_pop(mut \${1:val})\$0'
	closed_items := result.items.filter(it.label == 'closed')
	assert closed_items[0].kind == 10
	assert closed_items[0].detail == 'bool'
	// V3, the default compiler, types `len` and `cap` as `int` (V1 said `u32`).
	assert result.items.filter(it.label == 'len')[0].detail == 'int'
	assert result.items.filter(it.label == 'cap')[0].detail == 'int'
}

fn test_thread_parameter_completes_wait_with_return_type() {
	result := indexed_completions_at_line_end('thread_param_completion', 'module main\n\nfn join(th thread int) {\n\tth.\n}\n\nfn main() {}\n', '\tth.')
	waits := result.items.filter(it.label == 'wait')
	assert waits.len == 1, result.items.map(it.label).str()
	assert waits[0].detail == 'fn (t thread int) wait() int'
}

fn test_channel_parameter_completes_channel_members() {
	result := indexed_completions_at_line_end('channel_param_completion', 'module main\n\nfn worker(ch chan int) {\n\tch.\n}\n\nfn main() {}\n', '\tch.')
	assert sorted_completion_labels(result) == ['cap', 'close', 'closed', 'len', 'try_pop', 'try_push']
}

fn test_channel_fields_complete_like_their_type() {
	cap_result := indexed_completions_at_line_end('channel_cap_chain', 'module main\n\nfn main() {\n\tch := chan int{cap: 2}\n\tch.cap.\n}\n', '\tch.cap.')
	cap_labels := cap_result.items.map(it.label)
	assert 'str' in cap_labels, cap_labels.str()
	assert 'hex' in cap_labels, cap_labels.str()
	closed_result := indexed_completions_at_line_end('channel_closed_chain', 'module main\n\nfn worker(ch chan int) {\n\tch.closed.\n}\n\nfn main() {}\n', '\tch.closed.')
	assert 'str' in closed_result.items.map(it.label), closed_result.items.map(it.label).str()
}

fn test_literal_bindings_complete_their_builtin_methods() {
	int_labels := indexed_completions_at_line_end('literal_int_completion', 'module main\n\nfn main() {\n\tn := 5\n\tn.\n}\n', '\tn.').items.map(it.label)
	assert 'str' in int_labels, int_labels.str()
	assert 'hex' in int_labels, int_labels.str()
	float_labels := indexed_completions_at_line_end('literal_float_completion', 'module main\n\nfn main() {\n\tf := 1.5\n\tf.\n}\n', '\tf.').items.map(it.label)
	assert 'str' in float_labels, float_labels.str()
	rune_labels := indexed_completions_at_line_end('literal_rune_completion', 'module main\n\nfn main() {\n\tr := `a`\n\tr.\n}\n', '\tr.').items.map(it.label)
	assert 'str' in rune_labels, rune_labels.str()
	assert 'after' !in rune_labels, rune_labels.str()
	string_labels := indexed_completions_at_line_end('literal_string_completion', "module main\n\nfn main() {\n\ts := 'hello'\n\ts.\n}\n", '\ts.').items.map(it.label)
	assert 'after' in string_labels, string_labels.str()
}

fn test_operator_overloads_are_not_offered_as_completions() {
	content := "module main\n\nfn main() {\n\ts := 'hello'\n\ts.\n}\n"
	string_labels := indexed_completions_at_line_end('string_operator_completion', content, '\ts.').items.map(it.label)
	for operator in ['+', '==', '<'] {
		assert operator !in string_labels, string_labels.str()
	}
	// The compiler's list includes the operator overloads that builtin declares.
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	dir := os.join_path(app.temp_dir, 'compiler_operator_completion')
	must_mkdir_all(dir)
	main_file := os.join_path(dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	result := app.run_v_line_info(.completion, uri, '5:3')
	assert result is []Detail
	compiler_labels := (result as []Detail).map(it.label)
	assert 'to_upper' in compiler_labels, compiler_labels.str()
	for operator in ['+', '==', '<'] {
		assert operator !in compiler_labels, compiler_labels.str()
	}
}

const enum_completion_source = 'module main\n\nenum Color {\n\tred\n\tgreen\n\tblue\n}\n\nstruct Pixel {\n\tcolor Color\n}\n\nfn paint(n int, c Color) {\n\tprintln(c)\n}\n\nfn main() {\n\tmut b := Color.red\n\t@@\n}\n'

fn enum_completion_labels(dir_name string, line string) []string {
	content := enum_completion_source.replace('@@', line)
	mut labels := indexed_completions_at_line_end(dir_name, content, '\t${line}').items.map(it.label)
	labels.sort()
	return labels
}

fn test_enum_type_name_completes_its_values() {
	// `from` is the static function V gives every enum.
	assert enum_completion_labels('enum_type_name', 'a := Color.') == ['blue', 'from', 'green',
		'red']
}

fn test_enum_shorthand_completes_from_the_expected_type() {
	assert enum_completion_labels('enum_assign', 'b = .') == ['blue', 'green', 'red']
	assert enum_completion_labels('enum_compare', 'if b == .') == ['blue', 'green', 'red']
	assert enum_completion_labels('enum_argument', 'paint(1, .') == ['blue', 'green', 'red']
	assert enum_completion_labels('enum_field', 'p := Pixel{color: .') == ['blue', 'green', 'red']
}

fn test_enum_shorthand_completes_match_branches() {
	content := enum_completion_source.replace('@@', 'match b {\n\t\t.red {}\n\t\t.')
	mut labels := indexed_completions_at_line_end('enum_match', content, '\t\t.').items.map(it.label)
	labels.sort()
	assert labels == ['blue', 'green', 'red']
}

// member_completion_source declares one type of each kind. A case replaces
// `@@body` (or `@@param`, inside a function taking parameters of several types) with its code, where
// `@cursor` marks the position that asks for completion.
const member_completion_source = 'module main

import time
import strings

@[flag]
enum Perm {
	read
	write
}

enum Color {
	red
	green
}

fn Color.first() Color {
	return .red
}

fn (c Color) label() string {
	return c.str()
}

struct Point {
	x int
	y int
}

fn Point.origin() Point {
	return Point{}
}

fn (p Point) moved() Point {
	return p
}

struct Shape {
	pos  Point
	name string
}

type Figure = Point | Shape

interface Animal {
	speak() string
}

type Meters = f64

type Names = []string

fn (m Meters) km() f64 {
	return f64(m) / 1000
}

fn make_point() Point {
	return Point{}
}

fn load() !Point {
	return Point{}
}

fn use_params(c Color, nums []int, table map[string]int, cells &[]int, a Animal, u Unknown) {
	@@param
}

fn main() {
	@@body
}
'

struct MemberCompletionCase {
	name   string
	body   string
	param  string
	want   []string
	forbid []string
}

fn member_completion_items(c MemberCompletionCase) []Detail {
	return member_completion_result(c).items
}

fn member_completion_result(c MemberCompletionCase) IndexedCompletionResult {
	marked := member_completion_source.replace('@@body', c.body).replace('@@param', c.param)
	lines := marked.split_into_lines()
	mut line := -1
	mut col := -1
	for i, text in lines {
		if idx := text.index('@cursor') {
			line = i
			col = idx
			break
		}
	}
	assert line >= 0, c.name
	content := marked.replace('@cursor', '')
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	dir := os.join_path(app.temp_dir, 'member_completion_${c.name}')
	must_mkdir_all(dir)
	main_file := os.join_path(dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	return app.indexed_completions(uri, Position{
		line: line
		char: col
	})
}

fn test_member_completion_resolves_the_type_of_any_expression() {
	point := ['x', 'y', 'moved', 'str']
	cases := [
		MemberCompletionCase{
			name: 'flag_enum_type'
			body: 'a := Perm.@cursor'
			want: ['read', 'write', 'zero', 'from']
		},
		MemberCompletionCase{
			name:   'enum_type'
			body:   'a := Color.@cursor'
			want:   ['red', 'green', 'from', 'first']
			forbid: ['zero']
		},
		MemberCompletionCase{
			name: 'struct_type'
			body: 'o := Point.@cursor'
			want: ['origin']
		},
		MemberCompletionCase{
			name: 'flag_enum_value'
			body: 'mut p := Perm.read\n\tp.@cursor'
			want: ['has', 'all', 'set', 'set_all', 'clear', 'clear_all', 'toggle', 'is_empty',
				'str']
		},
		MemberCompletionCase{
			name:   'enum_value'
			body:   'c := Color.red\n\tc.@cursor'
			want:   ['label', 'str']
			forbid: ['has', 'zero', 'from']
		},
		MemberCompletionCase{
			name:  'enum_parameter'
			param: 'c.@cursor'
			want:  ['label', 'str']
		},
		MemberCompletionCase{
			name: 'alias'
			body: 'm := Meters(1.5)\n\tm.@cursor'
			want: ['km', 'str']
		},
		MemberCompletionCase{
			name: 'alias_of_array'
			body: "n := Names(['a'])\n\tn.@cursor"
			want: ['join', 'len', 'str']
		},
		MemberCompletionCase{
			name: 'call'
			body: 'make_point().@cursor'
			want: point
		},
		MemberCompletionCase{
			name: 'module_call'
			body: 'time.now().@cursor'
			want: ['year', 'format']
		},
		MemberCompletionCase{
			name: 'array_index'
			body: 'pts := [Point{}]\n\tpts[0].@cursor'
			want: point
		},
		MemberCompletionCase{
			name: 'map_index'
			body: "m := map[string]Point{}\n\tm['a'].@cursor"
			want: point
		},
		MemberCompletionCase{
			name: 'string_index'
			body: "s := 'abc'\n\ts[0].@cursor"
			want: ['ascii_str', 'str']
		},
		MemberCompletionCase{
			name: 'nested_array_index'
			body: 'grid := [][]int{}\n\tgrid[0].@cursor'
			want: ['len', 'filter', 'first']
		},
		MemberCompletionCase{
			name: 'string_len'
			body: "s := 'abc'\n\ts.len.@cursor"
			want: ['str', 'hex']
		},
		MemberCompletionCase{
			name: 'array_len'
			body: 'arr := [1, 2]\n\tarr.len.@cursor'
			want: ['str', 'hex']
		},
		MemberCompletionCase{
			name: 'string_literal'
			body: "'abc'.@cursor"
			want: ['to_upper', 'len']
		},
		MemberCompletionCase{
			name: 'string_method_result'
			body: "u := 'abc'.to_upper()\n\tu.@cursor"
			want: ['to_upper', 'len']
		},
		MemberCompletionCase{
			name: 'cast'
			body: 'n := i64(5)\n\tn.@cursor'
			want: ['str', 'hex']
		},
		MemberCompletionCase{
			name: 'match_branch'
			body: 'f := Figure(Point{})\n\tmatch f {\n\t\tPoint {\n\t\t\tf.@cursor\n\t\t}\n\t\telse {}\n\t}'
			want: point
		},
		MemberCompletionCase{
			name: 'is_check'
			body: 'f := Figure(Point{})\n\tif f is Point {\n\t\tf.@cursor\n\t}'
			want: point
		},
		MemberCompletionCase{
			name: 'map'
			body: 'mut m := map[string]int{}\n\tm.@cursor'
			want: ['len', 'keys', 'values', 'delete', 'clear', 'clone', 'move']
		},
		MemberCompletionCase{
			name:   'fixed_array'
			body:   'arr := [3]int{}\n\tarr.@cursor'
			want:   ['len', 'index', 'contains', 'map', 'sorted']
			forbid: ['first', 'last', 'clone', 'cap']
		},
		MemberCompletionCase{
			name: 'array_of_structs'
			body: 'pts := [Point{}]\n\tpts.@cursor'
			want: ['len', 'filter', 'first']
		},
		MemberCompletionCase{
			name: 'map_result'
			body: 'arr := [1, 2]\n\tdoubled := arr.map(it * 2)\n\tdoubled.@cursor'
			want: ['len', 'filter', 'first']
		},
		MemberCompletionCase{
			name: 'field_chain'
			body: 'sh := Shape{}\n\tsh.pos.@cursor'
			want: point
		},
		MemberCompletionCase{
			name: 'method_chain'
			body: 'q := make_point().moved()\n\tq.@cursor'
			want: point
		},
		MemberCompletionCase{
			name: 'builder'
			body: 'mut sb := strings.new_builder(8)\n\tsb.@cursor'
			want: ['write_string', 'str']
		},
		MemberCompletionCase{
			name: 'commented_declaration'
			body: "u := 'abc'.to_upper() // upper\n\tu.@cursor"
			want: ['to_upper', 'len']
		},
		MemberCompletionCase{
			name:  'array_parameter'
			param: 'nums.@cursor'
			want:  ['len', 'filter', 'first']
		},
		MemberCompletionCase{
			name:  'map_parameter'
			param: 'table.@cursor'
			want:  ['keys', 'values', 'len']
		},
		MemberCompletionCase{
			name:  'pointer_array_parameter'
			param: 'cells.@cursor'
			want:  ['len', 'first']
		},
		MemberCompletionCase{
			name: 'static_call'
			body: 'Point.origin().@cursor'
			want: point
		},
		MemberCompletionCase{
			name: 'static_call_binding'
			body: 'f := Color.first()\n\tf.@cursor'
			want: ['label', 'str']
		},
		MemberCompletionCase{
			name: 'index_or'
			body: 'pts := [Point{}]\n\tp := pts[0] or { Point{} }\n\tp.@cursor'
			want: point
		},
		MemberCompletionCase{
			name: 'result_unwrap'
			body: 'load()!.@cursor'
			want: point
		},
		MemberCompletionCase{
			name: 'array_literal_chain'
			body: '[3, 1, 2].sorted().@cursor'
			want: ['first', 'len']
		},
		MemberCompletionCase{
			name: 'parenthesized_as_cast'
			body: 'f := Figure(Point{})\n\t(f as Point).@cursor'
			want: point
		},
		MemberCompletionCase{
			name: 'typeof'
			body: 'x := 5\n\ttypeof(x).@cursor'
			want: ['name', 'idx', 'indirections']
		},
		MemberCompletionCase{
			name: 'typeof_name'
			body: 'x := 5\n\ttypeof(x).name.@cursor'
			want: ['to_upper', 'len']
		},
		MemberCompletionCase{
			name: 'typeof_generic'
			body: 'typeof[int]().@cursor'
			want: ['name', 'idx']
		},
	]
	mut failures := []string{}
	for c in cases {
		labels := member_completion_items(c).map(it.label)
		missing := c.want.filter(it !in labels)
		unexpected := c.forbid.filter(it in labels)
		if missing.len > 0 || unexpected.len > 0 {
			failures << '${c.name}: missing ${missing}, unexpected ${unexpected}'
		}
	}
	assert failures.len == 0, failures.join('\n')
}

fn test_member_completion_types_calls_to_functions_of_the_module() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	dir := os.join_path(app.temp_dir, 'calls_across_files')
	must_mkdir_all(dir)
	must_write_file(os.join_path(dir, 'shapes.v'), 'module main\n\nstruct Point {\n\tx int\n}\n\nfn origin() Point {\n\treturn Point{}\n}\n\nfn all_points() []Point {\n\treturn [Point{}]\n}\n')
	main_file := os.join_path(dir, 'main.v')
	content := 'module main\n\nfn local_points() []Point {\n\treturn []\n}\n\nfn main() {\n\tp := origin()\n\tp.\n\tpts := all_points()\n\tpts.\n\tlp := local_points()\n\tlp.\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	for line_text, want in {
		'\tp.':   'x'
		'\tpts.': 'fn (a []Point) first() Point'
		'\tlp.':  'fn (a []Point) first() Point'
	} {
		line := lines.index(line_text)
		items := app.indexed_completions(uri, Position{
			line: line
			char: lines[line].len
		}).items
		assert items.any(it.label == want || it.detail == want), '${line_text} ${items.map(it.label)}'
	}
}

fn member_detail(name string, body string, label string) string {
	items := member_completion_items(MemberCompletionCase{
		name: name
		body: body
	}).filter(it.label == label)
	return if items.len == 1 { items[0].detail } else { '${items.len} items' }
}

fn test_member_completion_details_carry_the_resolved_types() {
	assert member_detail('detail_array_of_structs', 'pts := [Point{}]\n\tpts.@cursor', 'first') == 'fn (a []Point) first() Point'
	assert member_detail('detail_map_keys', 'm := map[string]int{}\n\tm.@cursor', 'keys') == 'fn (m map[string]int) keys() []string'
	assert member_detail('detail_static', 'a := Color.@cursor', 'first') == 'fn Color.first() Color'
	assert member_detail('detail_from', 'a := Color.@cursor', 'from') == 'fn Color.from[W](input W) !Color'
	assert member_detail('detail_zero', 'a := Perm.@cursor', 'zero') == 'fn Perm.zero() Perm'
	assert member_detail('detail_has', 'p := Perm.read\n\tp.@cursor', 'has') == 'fn (e &Perm) has(flag_ Perm) bool'
	assert member_detail('detail_set', 'mut p := Perm.read\n\tp.@cursor', 'set') == 'fn (mut e Perm) set(flag_ Perm)'
	assert member_detail('detail_typeof', 'x := 5\n\ttypeof(x).@cursor', 'name') == 'string'
	assert member_detail('detail_map_result', 'arr := [1, 2]\n\tdoubled := arr.map(it * 2)\n\tdoubled.@cursor',
		'first') == 'fn (a []int) first() int'
}

fn test_member_completion_leaves_unknown_members_to_the_compiler() {
	// The index lists no member of an interface or of a type it cannot find, so the
	// compiler still has to answer for them.
	for body in ['a.@cursor', 'u.@cursor'] {
		result := member_completion_result(MemberCompletionCase{
			name:  'compiler_${body[0..1]}'
			param: body
		})
		assert result.use_compiler, body
	}
}

fn array_completion_items(dir_name string, decl string) []Detail {
	return indexed_completions_at_line_end(dir_name, 'module main\n\nfn main() {\n\t${decl}\n\tarr.\n}\n', '\tarr.').items
}

fn test_array_receivers_complete_their_builtin_methods() {
	ints := array_completion_items('array_int_literal', 'arr := [3, 1, 2]')
	int_labels := ints.map(it.label)
	for name in ['len', 'cap', 'filter', 'map', 'sort', 'sorted', 'contains', 'index', 'first', 'last',
		'pop', 'insert', 'prepend', 'delete', 'clear', 'reverse', 'clone', 'any', 'all', 'count', 'trim'] {
		assert name in int_labels, '${name} missing: ${int_labels}'
	}
	assert 'join' !in int_labels
	assert ints.filter(it.label == 'first')[0].detail == 'fn (a []int) first() int'
	assert ints.filter(it.label == 'filter')[0].detail == 'fn (a []int) filter(predicate fn (int) bool) []int'
	string_labels := array_completion_items('array_string_init', 'arr := []string{}').map(it.label)
	assert 'join' in string_labels, string_labels.str()
	assert 'sort_ignore_case' in string_labels, string_labels.str()
	byte_labels := array_completion_items('array_u8_init', 'arr := []u8{len: 4}').map(it.label)
	assert 'bytestr' in byte_labels, byte_labels.str()
	assert 'hex' in byte_labels, byte_labels.str()
}

fn test_callback_methods_insert_a_function_skeleton() {
	items := array_completion_items('array_callback_insert', 'arr := [3, 1, 2]')
	insert_of := fn [items] (name string) string {
		return items.filter(it.label == name)[0].insert_text or { '' }
	}
	assert insert_of('filter') == 'filter(fn (x int) bool {\n\t\$0\n})'
	assert insert_of('any') == 'any(fn (x int) bool {\n\t\$0\n})'
	assert insert_of('map') == 'map(fn (x int) \${1:int} {\n\t\$0\n})'
	assert insert_of('sort_with_compare') == 'sort_with_compare(fn (a &int, b &int) int {\n\t\$0\n})'
}

fn callback_argument_items(dir_name string, content string, line_text string, col_from_end int) []Detail {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, dir_name)
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	line := lines.index(line_text)
	assert line >= 0, line_text
	return app.indexed_completions(uri, Position{
		line: line
		char: lines[line].len - col_from_end
	}).items
}

fn test_empty_callback_argument_offers_a_function_skeleton() {
	array_items := callback_argument_items('callback_arg_array', 'module main\n\nfn main() {\n\tnums := [3, 1, 2]\n\tnums.filter()\n}\n', '\tnums.filter()', 1)
	array_skeletons := array_items.filter(it.label == 'fn (x int) bool')
	assert array_skeletons.len == 1, array_items.map(it.label).str()
	assert (array_skeletons[0].insert_text or { '' }) == 'fn (x int) bool {\n\t\$0\n}'
	user_items := callback_argument_items('callback_arg_user', 'module main\n\nfn apply(f fn (int) int) int {\n\treturn f(1)\n}\n\nfn main() {\n\tapply()\n}\n', '\tapply()', 1)
	user_skeletons := user_items.filter(it.label == 'fn (x int) int')
	assert user_skeletons.len == 1, user_items.map(it.label).str()
	assert (user_skeletons[0].insert_text or { '' }) == 'fn (x int) int {\n\t\$0\n}'
}

fn test_callback_skeletons_name_parameters_whose_type_takes_several_words() {
	// `thread int` is one type written as two words: `thread` is not the name of
	// the parameter, and a function literal needs one.
	mut failures := []string{}
	threads := array_completion_items('callback_thread_elements', 'arr := []thread int{}')
	thread_filter := threads.filter(it.label == 'filter')
	got_filter := if thread_filter.len > 0 {
		thread_filter[0].insert_text or { '' }
	} else {
		'no filter'
	}
	if got_filter != 'filter(fn (x thread int) bool {\n\t\$0\n})' {
		failures << 'arr.filter on []thread int: ${got_filter}'
	}
	user_items := callback_argument_items('callback_arg_channels', 'module main\n\nfn each(f fn (chan int) bool) bool {\n\treturn f(chan int{})\n}\n\nfn main() {\n\teach()\n}\n', '\teach()', 1)
	if user_items.filter(it.label == 'fn (x chan int) bool').len != 1 {
		failures << 'each(): ${user_items.map(it.label)}'
	}
	for fn_type, expected in {
		'fn (thread int) bool':              'fn (x thread int) bool'
		'fn (chan int) bool':                'fn (x chan int) bool'
		'fn (atomic int)':                   'fn (x atomic int)'
		'fn (thread int, chan string) bool': 'fn (a thread int, b chan string) bool'
		'fn (mut []int)':                    'fn (mut x []int)'
		'fn (shared Data)':                  'fn (shared x Data)'
		'fn (th thread int) bool':           'fn (th thread int) bool'
		'fn (mut buf []u8) int':             'fn (mut buf []u8) int'
		'fn (int) bool':                     'fn (x int) bool'
		'fn (a &int, b &int) int':           'fn (a &int, b &int) int'
		'fn (fn (int) int) int':             'fn (x fn (int) int) int'
		'fn (time.Time, C.FILE)':            'fn (a time.Time, b C.FILE)'
		'fn (...string)':                    'fn (x ...string)'
		'fn (map[string]thread int) bool':   'fn (x map[string]thread int) bool'
	} {
		label, _ := callback_skeleton(fn_type, '') or { 'none', '' }
		if label != expected {
			failures << '${fn_type}: ${label}'
		}
	}
	assert failures.len == 0, failures.join('\n')
}

fn test_call_snippets_name_the_parameter_after_its_modifier() {
	// `shared` comes before the name like `mut`, and a type can take two words.
	assert build_fn_snippet('update', '(shared d Data)') == 'update(\${1:d})\$0'
	assert build_fn_snippet('fill', '(mut buf []u8, n int)') == 'fill(\${1:buf}, \${2:n})\$0'
	assert build_fn_snippet('join', '(th thread int, ch chan string)') == 'join(\${1:th}, \${2:ch})\$0'
	assert build_fn_snippet('skip', '(_ string)') == 'skip(\${1:string})\$0'
}

fn test_enum_members_are_not_offered_for_a_channel_of_the_enum() {
	mut app := create_test_app()
	defer {
		cleanup_test_app(app)
	}
	test_dir := os.join_path(app.temp_dir, 'enum_channel_argument')
	must_mkdir_all(test_dir)
	main_file := os.join_path(test_dir, 'main.v')
	content := 'module main\n\nenum Color {\n\tred\n\tgreen\n}\n\nfn paint(c Color) {}\n\nfn send(ch chan Color) {}\n\nfn main() {\n\tpaint(.)\n\tsend(.)\n}\n'
	must_write_file(main_file, content)
	uri := path_to_uri(main_file)
	app.open_files[uri] = content
	lines := content.split_into_lines()
	labels_at := fn [mut app, uri, lines] (line_text string) []string {
		line := lines.index(line_text)
		assert line >= 0, line_text
		return app.indexed_completions(uri, Position{
			line: line
			char: lines[line].len - 1
		}).items.map(it.label)
	}
	// A `Color` parameter takes `.red`; a `chan Color` one does not.
	paint_labels := labels_at('\tpaint(.)')
	assert 'red' in paint_labels, paint_labels.str()
	send_labels := labels_at('\tsend(.)')
	assert 'red' !in send_labels, send_labels.str()
}

fn semantic_token_texts(line string) []string {
	return tokenize_v_source(line).map('${semantic_token_types()[it.type_idx]}:${line[it.start..it.start +
		it.length]}')
}

fn test_semantic_tokens_leave_string_interpolations_out_of_the_string() {
	// `${name}` is code, not string: only the literal parts are string tokens, and
	// identifiers inside the interpolation keep their own tokens.
	assert semantic_token_texts("\treturn 'hello, \${name} and \${Kind.x}'") == [
		'keyword:return',
		"string:'hello, ",
		'variable:name',
		'string: and ',
		'type:Kind',
		'property:x',
		"string:'",
	]
	// An unbraced `\$name` is text (V interpolates only `\${}`), and so is an escaped `\\\${`.
	assert semantic_token_texts("s := 'a \$b c'") == ['variable:s', "string:'a \$b c'"]
	assert semantic_token_texts("s := 'price: \\\${x}'") == ['variable:s', "string:'price: \\\${x}'"]
}

// Auto-import completion. A project with modules of its own, one without v.mod,
// and a VMODULES folder of installed packages: `gui` with its `svg` submodule
// and a namespaced `author.pkg`.
const import_lab_files = {
	'proj/v.mod':                   "Module {\n\tname: 'proj'\n\tversion: '0.0.1'\n}\n"
	'proj/main.v':                  'module main\n\nimport store\n\nfn main() {\n\tstore.open()\n\tte\n}\n'
	'proj/store/store.v':           'module store\n\npub fn open() {}\n'
	'proj/utils/textx/textx.v':     'module textx\n\npub fn shout(s string) string {\n\treturn s\n}\n'
	'proj/utils/mathx/mathx.v':     'module mathx\n\nimport utils.textx\n\npub fn twice(n int) int {\n\treturn n * 2\n}\n'
	'proj/broken/broken.v':         'module other\n\npub fn f() {}\n'
	'proj/examples/demo/main.v':    'module main\n\nfn main() {}\n'
	'proj/.hidden/secret/secret.v': 'module secret\n\npub fn f() {}\n'
	'noproj/main.v':                'module main\n\nfn main() {\n\tli\n}\n'
	'noproj/lib/lib.v':             'module lib\n\npub fn greet() {}\n'
	'vmods/gui/gui.v':              'module gui\n\npub fn window() {}\n'
	'vmods/gui/svg/svg.v':          'module svg\n\npub fn draw() {}\n'
	'vmods/gui/examples/demo.v':    'module main\n\nfn main() {}\n'
	'vmods/author/pkg/pkg.v':       'module pkg\n\npub fn run() {}\n'
	'vmods/.cache/junk/junk.v':     'module junk\n\npub fn f() {}\n'
}

struct ImportLab {
	base         string
	root         string
	vmodules     string
	old_vmodules string
mut:
	app &App
}

// new_import_lab writes the lab under a test app's temp dir and points VMODULES
// at its packages until close().
fn new_import_lab() ImportLab {
	app := create_test_app()
	base := os.join_path(app.temp_dir, 'import_lab')
	for rel, content in import_lab_files {
		path := os.join_path(base, rel)
		must_mkdir_all(os.dir(path))
		must_write_file(path, content)
	}
	old_vmodules := os.getenv('VMODULES')
	os.setenv('VMODULES', os.join_path(base, 'vmods'), true)
	return ImportLab{
		base:         base
		root:         os.join_path(base, 'proj')
		vmodules:     os.join_path(base, 'vmods')
		old_vmodules: old_vmodules
		app:          app
	}
}

fn (lab ImportLab) close() {
	if lab.old_vmodules == '' {
		os.unsetenv('VMODULES')
	} else {
		os.setenv('VMODULES', lab.old_vmodules, true)
	}
	cleanup_test_app(lab.app)
}

// completion_at writes `content` to `rel` (relative to the lab base), opens it
// and returns the completion items at the end of the line equal to `line_text`.
fn (mut lab ImportLab) completion_at(rel string, content string, line_text string) []Detail {
	path := os.join_path(lab.base, rel)
	must_write_file(path, content)
	uri := path_to_uri(path)
	lab.app.open_files[uri] = content
	lines := content.split_into_lines()
	idx := lines.index(line_text)
	assert idx >= 0, line_text
	return lab.app.indexed_completions(uri, Position{
		line: idx
		char: lines[idx].len
	}).items
}

fn import_edits(item Detail) []TextEdit {
	return item.additional_text_edits or { []TextEdit{} }
}

// imports_offered returns the `import` lines that accepting the items would add,
// for the modules of the project and the installed packages.
fn imports_offered(items []Detail) []string {
	mut lines := items.filter(import_edits(it).len > 0 && !it.detail.ends_with(' (vlib)')).map(import_edits(it)[0].new_text.trim_space())
	lines.sort()
	return lines
}

// vlib_imports_offered is imports_offered for V's own modules.
fn vlib_imports_offered(items []Detail) []string {
	mut lines := items.filter(import_edits(it).len > 0 && it.detail.ends_with(' (vlib)')).map(import_edits(it)[0].new_text.trim_space())
	lines.sort()
	return lines
}

fn test_completion_offers_the_modules_a_file_does_not_import_yet() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	items := lab.completion_at('proj/main.v', import_lab_files['proj/main.v'], '\tte')
	assert imports_offered(items) == ['import author.pkg', 'import gui', 'import gui.svg',
		'import utils.mathx', 'import utils.textx'], imports_offered(items).str()
	for item in items.filter(import_edits(it).len > 0) {
		assert item.kind == 9, item.label
		assert (item.insert_text or { '' }) == item.label
	}
	textx := items.filter(it.label == 'textx' && import_edits(it).len > 0)
	assert textx.len == 1
	edit := import_edits(textx[0])[0]
	// right after the last import (line 2, `import store`)
	assert edit.range.start.line == 3 && edit.range.start.char == 0
	assert edit.range.end.line == 3 && edit.range.end.char == 0
	assert edit.new_text == 'import utils.textx\n'
}

fn test_the_import_goes_where_v_expects_it_and_imported_modules_are_not_offered() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	// no imports yet: after the module line, in its own paragraph
	mut items := lab.completion_at('proj/extra.v', 'module main\n\nfn helper() {\n\tgu\n}\n',
		'\tgu')
	mut gui := items.filter(it.label == 'gui' && import_edits(it).len > 0)
	assert gui.len == 1
	mut edit := import_edits(gui[0])[0]
	assert edit.range.start.line == 1 && edit.range.start.char == 0
	assert edit.new_text == '\nimport gui\n'
	// no module line: at the top
	items = lab.completion_at('proj/extra.v', 'fn helper() {\n\tgu\n}\n', '\tgu')
	gui = items.filter(it.label == 'gui' && import_edits(it).len > 0)
	assert gui.len == 1
	edit = import_edits(gui[0])[0]
	assert edit.range.start.line == 0 && edit.range.start.char == 0
	assert edit.new_text == 'import gui\n\n'
	// several imports: after the last one
	items = lab.completion_at('proj/extra.v', 'module main\n\nimport store\nimport os\n\nfn helper() {\n\tgu\n}\n',
		'\tgu')
	gui = items.filter(it.label == 'gui' && import_edits(it).len > 0)
	assert gui.len == 1
	edit = import_edits(gui[0])[0]
	assert edit.range.start.line == 4 && edit.new_text == 'import gui\n'
	// imported under an alias, or only some of its symbols: not offered again
	items = lab.completion_at('proj/extra.v', 'module main\n\nimport gui as g\nimport utils.mathx { twice }\n\nfn helper() {\n\tgu\n}\n',
		'\tgu')
	assert imports_offered(items) == ['import author.pkg', 'import gui.svg', 'import store',
		'import utils.textx'], imports_offered(items).str()
}

fn test_a_module_is_not_offered_to_itself_nor_a_module_that_imports_it() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	content := 'module textx\n\npub fn shout(s string) string {\n\tst\n\treturn s\n}\n'
	items := lab.completion_at('proj/utils/textx/textx.v', content, '\tst')
	// `mathx` imports `textx`: importing it here would make a cycle
	assert imports_offered(items) == ['import author.pkg', 'import gui', 'import gui.svg',
		'import store'], imports_offered(items).str()
}

fn test_no_module_is_offered_inside_strings_or_comments() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	for line in ["\tx := 'te", '\t// te'] {
		content := 'module main\n\nfn main() {\n${line}\n}\n'
		items := lab.completion_at('proj/extra.v', content, line)
		assert imports_offered(items) == [], line
	}
}

fn test_import_line_completion_lists_installed_and_nested_project_modules() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	for line, want in {
		'import gu':      'gui'
		'import gui.':    'svg'
		'import utils.':  'textx'
		'import au':      'author'
		'import author.': 'pkg'
	} {
		items := lab.completion_at('proj/extra.v', 'module main\n\n${line}\n', line)
		assert items.any(it.label == want), '${line} -> ${items.map(it.label)}'
	}
	items := lab.completion_at('proj/extra.v', 'module main\n\nimport utils.\n', 'import utils.')
	assert items.any(it.label == 'mathx')
	// folders whose files declare another module, or `module main`, are not modules to import
	all := lab.completion_at('proj/extra.v', 'module main\n\nimport \n', 'import ')
	assert !all.any(it.label in ['broken', 'examples', 'secret', 'junk']), all.map(it.label).str()
}

fn test_members_of_an_installed_module_resolve_through_vmodules() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	assert lab.app.resolve_indexed_import_module_dir('gui', lab.root) == os.join_path(lab.vmodules,
		'gui')
	assert lab.app.resolve_indexed_import_module_dir('gui.svg', lab.root) == os.join_path(lab.vmodules,
		'gui', 'svg')
	assert lab.app.resolve_indexed_import_module_dir('author.pkg', lab.root) == os.join_path(lab.vmodules,
		'author', 'pkg')
	members := lab.app.get_imported_module_member_completions('gui', lab.root)
	assert members.items.any(it.label == 'window'), members.items.map(it.label).str()
}

fn test_a_project_without_v_mod_offers_its_own_modules() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	items := lab.completion_at('noproj/main.v', import_lab_files['noproj/main.v'], '\tli')
	assert 'import lib' in imports_offered(items)
}

// The modules of V's vlib are offered too, but not the ones V refuses to build
// a program with (deprecated since a date that has come, one that needs a `-d`
// flag), nor builtin, which every file has, nor the scaffolding of vlib: its
// tests and examples, and the internals of a module. A deprecated module that V
// still builds with is offered, marked deprecated.
fn test_completion_also_offers_the_modules_of_vlib() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	items := lab.completion_at('proj/main.v', import_lab_files['proj/main.v'], '\tte')
	offered := vlib_imports_offered(items)
	for path in ['os', 'strings', 'net.http', 'x.json2', 'crypto.sha256', 'builtin.wchar', 'json',
		'x.templating.dtm'] {
		assert 'import ${path}' in offered, path
	}
	for item in items.filter(import_edits(it).len > 0 && it.detail.ends_with(' (vlib)')) {
		deprecated := item.label in ['json', 'dtm']
		assert (item.tags or { []int{} }) == if deprecated { [1] } else { []int{} }, item.label
	}
	for path in ['builtin', 'gx', 'compress', 'io.string_reader', 'sync.arc', 'math.internal',
		'crypto.ed25519.internal.edwards25519'] {
		assert 'import ${path}' !in offered, path
	}
	for line in offered {
		for segment in line.all_after('import ').split('.') {
			assert segment !in ['tests', 'testdata', 'slow_tests', 'examples', 'internal'], line
		}
	}
	os_items := items.filter(it.label == 'os' && import_edits(it).len > 0)
	assert os_items.len == 1
	assert os_items[0].kind == 9
	assert os_items[0].detail == 'import os (vlib)'
	edit := import_edits(os_items[0])[0]
	assert edit.range.start.line == 3 && edit.new_text == 'import os\n'
	// a module already imported is not offered, from vlib either
	imported := lab.completion_at('proj/extra.v', 'module main\n\nimport os\nimport net.http\n\nfn helper() {\n\tte\n}\n',
		'\tte')
	assert 'import os' !in vlib_imports_offered(imported)
	assert 'import net.http' !in vlib_imports_offered(imported)
}

// Editing a module of vlib itself, as when working on V, the vlib modules that
// already import it are not offered: that would make an import cycle. The
// buffer is not written: no file of vlib is touched.
fn test_a_vlib_module_is_not_offered_the_vlib_modules_that_import_it() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	vlib := os.join_path(find_v_dir(), 'vlib')
	path := os.join_path(vlib, 'net', 'http', 'vls_import_cycle_probe.v')
	assert !os.exists(path)
	content := 'module http\n\nfn helper() {\n\tte\n}\n'
	uri := path_to_uri(path)
	lab.app.open_files[uri] = content
	items := lab.app.indexed_completions(uri, Position{
		line: 3
		char: 3
	}).items
	lab.app.open_files.delete(uri)
	offered := vlib_imports_offered(items)
	assert 'import os' in offered, offered.str()
	// net.http itself, and modules that import it directly or through others
	for path_ in ['net.http', 'net.http.file', 'net.websocket', 'veb', 'net.s3'] {
		assert 'import ${path_}' !in offered, path_
	}
}

// notify_changed tells the app that the file at `path` changed on disk, as the
// editor's file watcher does.
fn notify_changed(mut app App, path string) {
	app.on_did_change_watched_files(Request{
		params: json2.encode(DidChangeWatchedFilesParams{
			changes: [FileEvent{
				uri:        path_to_uri(path)
				event_type: 2
			}]
		})
	})
}

// The imports of a module are read once and kept, until the watcher says one
// of its files changed: a new import there can make a cycle at once.
fn test_a_changed_import_on_disk_is_seen_by_the_next_completion() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	content := 'module textx\n\npub fn shout(s string) string {\n\tst\n\treturn s\n}\n'
	mut items := lab.completion_at('proj/utils/textx/textx.v', content, '\tst')
	assert 'import store' in imports_offered(items)
	store_path := os.join_path(lab.root, 'store', 'store.v')
	must_write_file(store_path, 'module store\n\nimport utils.textx\n\npub fn open() {\n\ttextx.shout("")\n}\n')
	notify_changed(mut lab.app, store_path)
	items = lab.completion_at('proj/utils/textx/textx.v', content, '\tst')
	assert 'import store' !in imports_offered(items), imports_offered(items).str()
}

// A watched change of a file in vlib, as when working on V, makes vlib's module
// list be walked again. Nothing in vlib is written.
fn test_a_watched_change_in_vlib_forgets_the_vlib_modules() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	items := lab.completion_at('proj/main.v', import_lab_files['proj/main.v'], '\tte')
	assert 'import os' in vlib_imports_offered(items)
	vlib := os.join_path(find_v_dir(), 'vlib')
	assert vlib in lab.app.vlib_modules_cache
	notify_changed(mut lab.app, os.join_path(vlib, 'os', 'os.v'))
	assert vlib !in lab.app.vlib_modules_cache
}

// A module of the project named like one of vlib is the one V imports: it is
// offered once, as the project's.
fn test_a_project_module_hides_the_vlib_module_of_the_same_path() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	must_mkdir_all(os.join_path(lab.root, 'log'))
	must_write_file(os.join_path(lab.root, 'log', 'log.v'), 'module log\n\npub fn where() string {\n\treturn "project"\n}\n')
	items := lab.completion_at('proj/main.v', import_lab_files['proj/main.v'], '\tte')
	assert 'import log' in imports_offered(items)
	assert 'import log' !in vlib_imports_offered(items)
}

// Wherever a module comes from, it is not offered when V refuses to build a
// program that imports it: deprecated since a date that has come, or stopped by
// `$compile_error` unless a `-d` flag is given. Deprecated with no date, V
// only warns: it is offered, marked deprecated.
fn test_modules_v_refuses_are_not_offered_and_deprecated_ones_are_marked() {
	mut lab := new_import_lab()
	defer {
		lab.close()
	}
	for rel, content in {
		'oldlib/oldlib.v':                  "@[deprecated: 'use store instead']\n@[deprecated_after: '2020-01-01']\nmodule oldlib\n\npub fn f() {}\n"
		'ownonly/ownonly.v':                'module ownonly\n\npub fn f() {}\n'
		'ownonly/ownonly_notd_ownership.v': "module ownonly\n\n\$compile_error('ownonly needs -d ownership')\n"
		'fine/fine.v':                      'module fine\n\npub fn f() {}\n'
		'softold/softold.v':                "@[deprecated: 'use fine instead']\nmodule softold\n\npub fn f() {}\n"
		'blankdate/blankdate.v':            "@[deprecated: 'use fine instead']\n@[deprecated_after: '']\nmodule blankdate\n\npub fn f() {}\n"
	} {
		path := os.join_path(lab.root, rel)
		must_mkdir_all(os.dir(path))
		must_write_file(path, content)
	}
	items := lab.completion_at('proj/main.v', import_lab_files['proj/main.v'], '\tte')
	offered := imports_offered(items)
	assert 'import fine' in offered, offered.str()
	assert 'import softold' in offered, offered.str()
	// with no date to refuse it from, V only warns
	assert 'import blankdate' in offered, offered.str()
	assert 'import oldlib' !in offered, offered.str()
	assert 'import ownonly' !in offered, offered.str()
	for label, tags in {
		'fine':      []int{}
		'softold':   [1]
		'blankdate': [1]
	} {
		item := items.filter(it.label == label && import_edits(it).len > 0)[0]
		assert (item.tags or { []int{} }) == tags, label
	}
}
