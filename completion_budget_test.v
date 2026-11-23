module main

import os
import time

fn budget_test_items(n int) []Detail {
	mut items := []Detail{}
	for i in 0 .. n {
		items << Detail{
			kind:          6
			label:         'item_${i}'
			detail:        ''
			declaration:   ''
			documentation: ''
		}
	}
	return items
}

fn test_completion_budget_empty() {
	budgeted, truncated := apply_completion_budget([]Detail{})
	assert budgeted.len == 0
	assert truncated == false
}

fn test_completion_budget_under_limit() {
	items := budget_test_items(completion_item_budget - 1)
	budgeted, truncated := apply_completion_budget(items)
	assert budgeted.len == completion_item_budget - 1
	assert truncated == false
}

fn test_completion_budget_at_limit() {
	items := budget_test_items(completion_item_budget)
	budgeted, truncated := apply_completion_budget(items)
	assert budgeted.len == completion_item_budget
	assert truncated == false
}

fn test_completion_budget_truncates() {
	items := budget_test_items(completion_item_budget + 50)
	budgeted, truncated := apply_completion_budget(items)
	assert budgeted.len == completion_item_budget
	assert truncated == true
	for i in 0 .. completion_item_budget {
		assert budgeted[i].label == 'item_${i}'
	}
}

fn test_completion_budget_is_positive() {
	assert completion_item_budget > 0
}

fn test_optional_imports_return_after_local_completion() {
	root := make_unique_temp_path('vls_completion_imports', '/main.v')
	module_dir := os.join_path(root, 'latencyfixture')
	os.mkdir_all(module_dir) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'main.v')
	content := 'module main\n\nfn main() {\n\tlatencyfixture_local := 1\n\tlatencyfixture\n}\n'
	os.write_file(path, content) or { panic(err) }
	os.write_file(os.join_path(root, 'v.mod'), "Module { name: 'fixture' }\n") or { panic(err) }
	os.write_file(os.join_path(module_dir, 'latencyfixture.v'), 'module latencyfixture\n') or {
		panic(err)
	}
	uri := path_to_uri(path)
	mut app := &App{
		received_initialize: true
		open_files:          {
			uri: content
		}
	}
	defer { app.stop_index_refresh() }
	position := Position{ line: 4, char: 15 }
	first := app.indexed_completions(uri, position, 'latencyfixture')
	assert first.items.any(it.label == 'latencyfixture_local')
	assert first.imports_pending
	for _ in 0 .. 500 {
		result := app.indexed_completions(uri, position, 'latencyfixture')
		if !result.imports_pending {
			assert result.items.any(it.label == 'latencyfixture' && (it.additional_text_edits or { []TextEdit{} }).len == 1)
			return
		}
		time.sleep(10 * time.millisecond)
	}
	assert false, 'optional auto-import scan did not complete'
}
