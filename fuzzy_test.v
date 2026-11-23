module main

fn test_fuzzy_subsequence_matches() {
	assert fuzzy_subsequence_matches('he', 'hello')
	assert fuzzy_subsequence_matches('hlo', 'Hello')
	assert fuzzy_subsequence_matches('an', 'banana')
	assert fuzzy_subsequence_matches('å', 'Ångström')
	assert fuzzy_subsequence_matches('', '')
	assert !fuzzy_subsequence_matches('an', 'apple')
	assert !fuzzy_subsequence_matches('an', 'cherry')
	assert !fuzzy_subsequence_matches('ol', 'hello')
	assert !fuzzy_subsequence_matches('test', '')
}
