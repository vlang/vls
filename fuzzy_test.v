module main

fn test_fuzzy_match_exact() {
	m := fuzzy_match('hello', 'hello') or { panic('expected match') }
	assert m.score > 0
	assert m.matched.len == 5
}

fn test_fuzzy_match_subsequence() {
	m := fuzzy_match('hlo', 'hello') or { panic('expected match') }
	assert m.score > 0
	assert m.matched.len == 3
}

fn test_fuzzy_match_case_insensitive() {
	m := fuzzy_match('HLO', 'hello') or { panic('expected match') }
	assert m.score > 0
}

fn test_fuzzy_match_empty_pattern() {
	m := fuzzy_match('', 'hello') or { panic('expected match') }
	assert m.score == 0
}

fn test_fuzzy_match_no_match() {
	assert fuzzy_match('xyz', 'hello') == none
}

fn test_fuzzy_match_empty_text() {
	assert fuzzy_match('hello', '') == none
}

fn test_fuzzy_match_consecutive_bonus() {
	consecutive := fuzzy_match('ell', 'hello') or { panic('expected match') }
	non_consecutive := fuzzy_match('elo', 'hello') or { panic('expected match') }
	assert consecutive.score > non_consecutive.score
}

fn test_fuzzy_match_word_start_bonus() {
	word_start := fuzzy_match('hel', 'hello') or { panic('expected match') }
	mid_word := fuzzy_match('ell', 'hello') or { panic('expected match') }
	assert word_start.score > mid_word.score
}

fn test_fuzzy_filter_empty_pattern() {
	items := ['apple', 'banana', 'cherry']
	result := fuzzy_filter('', items)
	assert result.len == 3
}

fn test_fuzzy_filter_filters_non_matching() {
	items := ['apple', 'banana', 'cherry']
	result := fuzzy_filter('an', items)
	assert result.len == 1
	assert result[0] == 'banana'
}

fn test_fuzzy_filter_ranks_by_score() {
	items := ['hello', 'hallo', 'hxllo']
	result := fuzzy_filter('he', items)
	assert result[0] == 'hello'
}

fn test_fuzzy_filter_empty_items() {
	result := fuzzy_filter('test', []string{})
	assert result.len == 0
}
