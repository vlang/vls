module main

struct FuzzyMatch {
	score   int
	matched []int
}

struct ScoredItem {
	item  string
	score int
}

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

fn fuzzy_filter(pattern string, items []string) []string {
	if pattern == '' {
		return items.clone()
	}
	mut scored := []ScoredItem{}
	for item in items {
		if m := fuzzy_match(pattern, item) {
			scored << ScoredItem{ item: item, score: m.score }
		}
	}
	scored.sort(a.score < b.score)
	return scored.map(it.item)
}
