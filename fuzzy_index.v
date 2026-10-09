module main

// Trigram/fuzzy ranking for workspace symbols (see query_workspace_symbols).
//
// Per-symbol trigrams are extracted lowercased and underscore-insensitive, and
// cached in IndexEntry.symbol_trigrams keyed by display name (`Parent.child`
// for members, mirroring the query traversal). The trigram-to-symbols reverse
// map is assembled per query from that cache and used to score candidates by
// trigram overlap; matches are then ranked by overlap first and by
// exact/prefix/substring/subsequence preference second.
//
// The cache is maintained incrementally by construction: build_index_entry
// fills it on every (re)parse, the content fingerprint in reindex_uri skips
// rebuilds for unchanged files, and every drop path (drop_index_uri,
// drop_index_aliases_for_path, drop_index_under, reconcile_indexed_dir,
// invalidate_index_uri) deletes the entry and its trigrams together — the same
// lifecycle as symbol_index/ref_occurrences. No separate bookkeeping map is
// kept: this repo builds without `-enable-globals`, and the App struct lives
// in main.v, so an index-side global reverse map is not available.

// fuzzy_trigram_max_per_symbol caps the stored trigram list per symbol, so the
// cache grows with the symbol count and never with name length.
const fuzzy_trigram_max_per_symbol = 32

// Match classes, best first. Only classes 0..3 are returned; anything else is
// not a match.
const fuzzy_class_exact = 0
const fuzzy_class_prefix = 1
const fuzzy_class_substring = 2
const fuzzy_class_subsequence = 3

// fuzzy_normalize lowercases and drops underscores so `helper_name` also
// matches `helpername`-style queries.
fn fuzzy_normalize(s string) string {
	return s.to_lower().replace('_', '')
}

// fuzzy_trigrams returns the distinct trigrams of an already-normalized name
// in first-seen order, capped at fuzzy_trigram_max_per_symbol. Names shorter
// than 3 characters contribute no trigrams.
fn fuzzy_trigrams(normalized string) []string {
	if normalized.len < 3 {
		return []string{}
	}
	mut out := []string{cap: fuzzy_trigram_max_per_symbol}
	mut seen := map[string]bool{}
	for i in 0 .. normalized.len - 2 {
		if out.len >= fuzzy_trigram_max_per_symbol {
			break
		}
		tri := normalized[i..i + 3]
		if tri in seen {
			continue
		}
		seen[tri] = true
		out << tri
	}
	return out
}

// fuzzy_entry_trigrams flattens `doc_symbols` (top-level symbols plus one
// level of `Parent.child` members, mirroring query_workspace_symbols) into
// display-name to trigram lists for IndexEntry.symbol_trigrams.
fn fuzzy_entry_trigrams(doc_symbols []DocumentSymbol) map[string][]string {
	mut out := map[string][]string{}
	for sym in doc_symbols {
		out[sym.name] = fuzzy_trigrams(fuzzy_normalize(sym.name))
		for child in sym.children {
			child_name := '${sym.name}.${child.name}'
			out[child_name] = fuzzy_trigrams(fuzzy_normalize(child_name))
		}
	}
	return out
}

// fuzzy_is_subsequence reports whether every byte of `needle` appears in
// `haystack` in order. Both sides must already be normalized.
fn fuzzy_is_subsequence(needle string, haystack string) bool {
	if needle.len == 0 {
		return true
	}
	mut ni := 0
	for hi in 0 .. haystack.len {
		if haystack[hi] == needle[ni] {
			ni++
			if ni >= needle.len {
				return true
			}
		}
	}
	return false
}

// fuzzy_match_class ranks how one symbol relates to the query: exact, prefix,
// or substring on the normalized (and raw-lowercased) name, else
// subsequence-only, else -1 for no match.
fn fuzzy_match_class(normalized_name string, raw_lower_name string, q string, nq string) int {
	if normalized_name == nq {
		return fuzzy_class_exact
	}
	if normalized_name.starts_with(nq) {
		return fuzzy_class_prefix
	}
	if raw_lower_name.contains(q) || normalized_name.contains(nq) {
		return fuzzy_class_substring
	}
	if fuzzy_is_subsequence(nq, normalized_name) {
		return fuzzy_class_subsequence
	}
	return -1
}

// FuzzyRankedSymbol is one workspace-symbol candidate with its ranking keys.
struct FuzzyRankedSymbol {
	overlap int
	cls     int
	name    string
	uri     string
	kind    int
	sel     LSPRange
}

// fuzzy_rank_compare orders candidates by trigram overlap (best first), then
// match class, then name/uri/position/kind so the order is total and stable
// across runs.
fn fuzzy_rank_compare(a &FuzzyRankedSymbol, b &FuzzyRankedSymbol) int {
	if a.overlap != b.overlap {
		return b.overlap - a.overlap
	}
	if a.cls != b.cls {
		return a.cls - b.cls
	}
	if a.name != b.name {
		return if a.name < b.name { -1 } else { 1 }
	}
	if a.uri != b.uri {
		return if a.uri < b.uri { -1 } else { 1 }
	}
	if a.sel.start.line != b.sel.start.line {
		return a.sel.start.line - b.sel.start.line
	}
	if a.sel.start.char != b.sel.start.char {
		return a.sel.start.char - b.sel.start.char
	}
	if a.kind != b.kind {
		return a.kind - b.kind
	}
	return 0
}

// fuzzy_rank_symbol scores one display name against the query and appends it
// to `ranked` when it matches. `cached_tris` is the symbol's trigram list from
// IndexEntry.symbol_trigrams (empty when the entry predates the cache).
// Subsequence-only recall needs a normalized query of at least 3 characters;
// shorter queries keep the legacy substring behavior exactly.
fn fuzzy_rank_symbol(mut ranked []FuzzyRankedSymbol, uri string, name string, kind int, sel LSPRange, cached_tris []string, q string, nq string, query_tris []string, use_fuzzy_recall bool) {
	raw_lower := name.to_lower()
	normalized := fuzzy_normalize(name)
	cls := fuzzy_match_class(normalized, raw_lower, q, nq)
	if cls < 0 || cls > fuzzy_class_subsequence {
		return
	}
	if cls == fuzzy_class_subsequence && !use_fuzzy_recall {
		return
	}
	mut overlap := 0
	if query_tris.len > 0 && cached_tris.len > 0 {
		mut sym_set := map[string]bool{}
		for tri in cached_tris {
			sym_set[tri] = true
		}
		for tri in query_tris {
			if tri in sym_set {
				overlap++
			}
		}
	}
	ranked << FuzzyRankedSymbol{
		overlap: overlap
		cls:     cls
		name:    name
		uri:     uri
		kind:    kind
		sel:     sel
	}
}
