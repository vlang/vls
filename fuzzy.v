module main

struct FuzzyMatch {
	score   int
	matched []int
}

struct ScoredItem {
	item  string
	score int
}

/*
fn fuzzy_match(pattern string, text string) ?FuzzyMatch {
	if pattern == '' {
		return FuzzyMatch{ score: 0, matched: []int{} }
	}
	if text == '' {
		return none
	}
	pattern_lower := pattern.to_lower()
	text_lower := text.to_lower()
	mut pattern_idx := 0
	mut score := 0
	mut matched := []int{}
	mut last_match_idx := -1
	for text_idx in 0 .. text_lower.len {
		if pattern_idx >= pattern_lower.len {
			break
		}
		if text_lower[text_idx] == pattern_lower[pattern_idx] {
			mut match_score := 1
			if last_match_idx >= 0 && text_idx == last_match_idx + 1 {
				match_score += 5
			}
			if text_idx == 0 || text_lower[text_idx - 1] in [` `, `_`, `.`, `(`, `[`, `{`] {
				match_score += 3
			}
			score += match_score
			matched << text_idx
			last_match_idx = text_idx
			pattern_idx++
		}
	}
	if pattern_idx < pattern_lower.len {
		return none
	}
	score -= text.len / 4
	return FuzzyMatch{ score: score, matched: matched }
}
*/

// fuzzy_score returns the match score for `pattern` against `text` without
// allocating the matched-index slice that fuzzy_match keeps for highlighting.
// Completion and other hot paths only need the score, so this avoids one
// allocation per candidate.
// fuzzy_score_lowered is the hot path used by fuzzy_filter, where the pattern is
// constant across all candidates: it avoids re-lowercasing the pattern for
// every item.
fn fuzzy_score_lowered(pattern_lower string, text string) ?int {
	if pattern_lower == '' {
		return 0
	}
	if text == '' {
		return none
	}
	text_lower := text.to_lower()
	mut pattern_idx := 0
	mut score := 0
	mut last_match_idx := -1
	for text_idx in 0 .. text_lower.len {
		if pattern_idx >= pattern_lower.len {
			break
		}
		if text_lower[text_idx] == pattern_lower[pattern_idx] {
			mut match_score := 1
			if last_match_idx >= 0 && text_idx == last_match_idx + 1 {
				match_score += 5
			}
			if text_idx == 0 || text_lower[text_idx - 1] in [` `, `_`, `.`, `(`, `[`, `{`] {
				match_score += 3
			}
			score += match_score
			last_match_idx = text_idx
			pattern_idx++
		}
	}
	if pattern_idx < pattern_lower.len {
		return none
	}
	score -= text.len / 4
	return score
}

/*
fn fuzzy_score(pattern string, text string) ?int {
	if pattern == '' {
		return 0
	}
	return fuzzy_score_lowered(pattern.to_lower(), text)
}
*/

fn fuzzy_filter(pattern string, items []string) []string {
	if pattern == '' {
		return items.clone()
	}
	pattern_lower := pattern.to_lower()
	mut scored := []ScoredItem{}
	for item in items {
		if s := fuzzy_score_lowered(pattern_lower, item) {
			scored << ScoredItem{ item: item, score: s }
		}
	}
	scored.sort(a.score < b.score)
	return scored.map(it.item)
}
