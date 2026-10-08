module main

fn test_postfix_completions_count() {
	items := postfix_completions()
	assert items.len == 5
}

fn test_postfix_completions_labels() {
	items := postfix_completions()
	labels := items.map(it.label)
	assert '.if' in labels
	assert '.match' in labels
	assert '.for' in labels
	assert '.ptr' in labels
	assert '.unwrap' in labels
}

fn test_postfix_completions_have_snippets() {
	items := postfix_completions()
	for item in items {
		assert (item.insert_text or { '' }) != ''
		assert (item.insert_text_format or { 0 }) == 2
	}
}

fn test_postfix_completions_kind() {
	items := postfix_completions()
	for item in items {
		assert item.kind == 14
	}
}

fn test_postfix_if_snippet() {
	items := postfix_completions()
	if_item := items[0]
	assert if_item.label == '.if'
	assert (if_item.insert_text or { '' }).contains('if expr')
	assert (if_item.insert_text or { '' }).contains('$0')
}

fn test_postfix_match_snippet() {
	items := postfix_completions()
	match_item := items[1]
	assert match_item.label == '.match'
	assert (match_item.insert_text or { '' }).contains('match expr')
	assert (match_item.insert_text or { '' }).contains('$0')
}

fn test_postfix_for_snippet() {
	items := postfix_completions()
	for_item := items[2]
	assert for_item.label == '.for'
	assert (for_item.insert_text or { '' }).contains('for x in expr')
	assert (for_item.insert_text or { '' }).contains('$0')
}

fn test_postfix_ptr_snippet() {
	items := postfix_completions()
	ptr_item := items[3]
	assert ptr_item.label == '.ptr'
	assert (ptr_item.insert_text or { '' }) == '&expr'
}

fn test_postfix_unwrap_snippet() {
	items := postfix_completions()
	unwrap_item := items[4]
	assert unwrap_item.label == '.unwrap'
	assert (unwrap_item.insert_text or { '' }).contains('expr or')
	assert (unwrap_item.insert_text or { '' }).contains('$0')
}
