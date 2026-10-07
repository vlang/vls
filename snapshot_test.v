module main

import os
import json2

const snapshot_dir = 'testdata/snapshots'

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
	temp_dir := os.join_path(os.temp_dir(), 'vls_snap_${os.getpid()}')
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
const update_env = 'VLS_UPDATE_SNAPSHOTS'

fn snapshot_path(name string) string {
	return os.join_path(snapshot_dir, '${name}.json')
}

fn should_update_snapshots() bool {
	return os.getenv(update_env) == '1'
}

fn save_snapshot(name string, content string) ! {
	os.mkdir_all(snapshot_dir) or { return err }
	os.write_file(snapshot_path(name), content) or { return err }
}

fn load_snapshot(name string) !string {
	return os.read_file(snapshot_path(name)) or { return err }
}

fn assert_snapshot(name string, actual string) {
	if should_update_snapshots() {
		save_snapshot(name, actual) or {}
		return
	}
	expected := load_snapshot(name) or {
		save_snapshot(name, actual) or {}
		return
	}
	assert actual == expected, 'snapshot mismatch for ${name}:\n--- expected ---\n${expected}\n--- actual ---\n${actual}'
}

fn response_to_json(resp Response) string {
	return json2.encode(resp, escape_unicode: true)
}

fn snapshot_completion(name string, content string, line int, ch int) {
	mut app := create_test_app()
	defer { cleanup_test_app(app) }

	tmp_dir := os.join_path(app.temp_dir, 'snap')
	must_mkdir_all(tmp_dir)
	file := os.join_path(tmp_dir, 'main.v')
	must_write_file(file, content)

	uri := path_to_uri(file)
	app.text = content
	app.open_files[uri] = content

	req := Request{
		id: 1
		method: 'textDocument/completion'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{ uri: uri }
			position: Position{ line: line, char: ch }
		}, escape_unicode: true)
	}

	resp := app.operation_at_pos(.completion, req)
	json := response_to_json(resp)
	assert_snapshot(name, json)
}

fn snapshot_hover(name string, content string, line int, ch int) {
	mut app := create_test_app()
	defer { cleanup_test_app(app) }

	tmp_dir := os.join_path(app.temp_dir, 'snap')
	must_mkdir_all(tmp_dir)
	file := os.join_path(tmp_dir, 'main.v')
	must_write_file(file, content)

	uri := path_to_uri(file)
	app.text = content
	app.open_files[uri] = content

	req := Request{
		id: 1
		method: 'textDocument/hover'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{ uri: uri }
			position: Position{ line: line, char: ch }
		}, escape_unicode: true)
	}

	resp := app.operation_at_pos(.hover, req)
	json := response_to_json(resp)
	assert_snapshot(name, json)
}

fn snapshot_definition(name string, content string, line int, ch int) {
	mut app := create_test_app()
	defer { cleanup_test_app(app) }

	tmp_dir := os.join_path(app.temp_dir, 'snap')
	must_mkdir_all(tmp_dir)
	file := os.join_path(tmp_dir, 'main.v')
	must_write_file(file, content)

	uri := path_to_uri(file)
	app.text = content
	app.open_files[uri] = content

	req := Request{
		id: 1
		method: 'textDocument/definition'
		params: json2.encode(Params{
			text_document: TextDocumentIdentifier{ uri: uri }
			position: Position{ line: line, char: ch }
		}, escape_unicode: true)
	}

	resp := app.operation_at_pos(.definition, req)
	json := response_to_json(resp)
	assert_snapshot(name, json)
}

fn test_snapshot_completion_basic() {
	content := 'module main\n\nfn main() {\n\tos.\n}\n'
	snapshot_completion('completion_basic', content, 3, 4)
}

fn test_snapshot_hover_basic() {
	content := 'module main\n\nfn greet(name string) string {\n\treturn name\n}\n\nfn main() {\n\tgreet("world")\n}\n'
	snapshot_hover('hover_basic', content, 7, 3)
}

fn test_snapshot_definition_basic() {
	content := 'module main\n\nfn greet(name string) string {\n\treturn name\n}\n\nfn main() {\n\tgreet("world")\n}\n'
	snapshot_definition('definition_basic', content, 7, 3)
}

fn test_snapshot_completion_member() {
	content := 'module main\n\nstruct User {\n\tname string\n\tage  int\n}\n\nfn main() {\n\tu := User{}\n\tu.\n}\n'
	snapshot_completion('completion_member', content, 10, 3)
}
