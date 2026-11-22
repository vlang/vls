module main

// fuzzy_subsequence_matches tests a lowercase query against the candidate with
// the same case-insensitive subsequence rule used for completion filtering.
fn fuzzy_subsequence_matches(query string, candidate string) bool {
	if query == '' {
		return true
	}
	mut matched := 0
	for c in candidate.to_lower() {
		if c == query[matched] {
			matched++
			if matched == query.len {
				return true
			}
		}
	}
	return false
}
