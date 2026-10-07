module main

fn budget_test_items(n int) []Detail {
	mut items := []Detail{}
	for i in 0 .. n {
		items << Detail{
			kind: 6
			label: 'item_${i}'
			detail: ''
			declaration: ''
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
