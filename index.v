// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import sync
import time

// Persistent, incremental symbol index (audit Stage 4).
//
// The index parses every project `.v` file once into an IndexEntry and keeps it
// keyed by document URI. Consumers (workspace/document symbols, hover docs, call
// hierarchy) query the index instead of re-walking and re-reading the whole
// workspace on every request. Entries are maintained incrementally: document
// notifications and file-watcher events invalidate a single URI, which is then
// re-parsed lazily on the next query. Open documents are always indexed from
// their in-memory buffer (authoritative), unopened files from disk. A per-entry
// content fingerprint avoids re-parsing files that have not changed.

// IndexEntry is the parsed symbol information for one file.
struct IndexEntry {
	fingerprint                        int // content.hash(); used to skip re-parsing unchanged files
	module_name                        string
	doc_symbols                        []DocumentSymbol  // hierarchical symbols (as parse_document_symbols returns)
	docs                               map[string]string // simple symbol name -> leading vdoc comment
	fn_completions                     []Detail          // free-function completion items for this file
	module_completions                 []Detail          // all same-module top-level completion items
	public_module_completions          []Detail          // exported completion items for imported modules
	has_conditional_module_completions bool
	has_conditional_public_completions bool
	conditional_lines                  []bool              // declarations guarded by $if/$else or @[if]
	symbol_trigrams                    map[string][]string // display name -> capped trigram list for fuzzy ranking (see fuzzy_index.v)
}

// build_index_entry parses `content` into an IndexEntry. Symbol ranges are
// re-encoded into `enc` so document/workspace symbol positions match the
// negotiated encoding for non-ASCII lines (P0-01).
fn build_index_entry(content string, enc PositionEncoding) IndexEntry {
	lines := content.split_into_lines()
	doc_syms := encode_document_symbols(parse_document_symbols(content), lines, enc)
	code_lines := source_code_lines(content)
	conditional_lines := compile_time_conditional_lines(content)
	module_completion_index := parse_module_member_completions_from_lines(code_lines, conditional_lines, false)
	public_module_completion_index := parse_module_member_completions_from_lines(code_lines, conditional_lines, true)
	mut docs := map[string]string{}
	for sym in doc_syms {
		// A method is documented where its value's type is known, never by its
		// name alone (see find_bare_declaration_line).
		if sym.kind == sym_kind_method {
			continue
		}
		// Each symbol's declaration line is range.start.line; read its vdoc.
		doc := extract_doc_comment(lines, sym.range.start.line)
		if doc != '' {
			simple := extract_simple_fn_name(sym.name)
			if simple != '' && simple !in docs {
				docs[simple] = doc
			}
		}
	}
	return IndexEntry{
		fingerprint:                        content.hash()
		module_name:                        get_module_name(content)
		doc_symbols:                        doc_syms
		docs:                               docs
		fn_completions:                     module_completion_index.items.filter(it.kind == 3)
		module_completions:                 module_completion_index.items
		public_module_completions:          public_module_completion_index.items
		has_conditional_module_completions: module_completion_index.has_conditional
		has_conditional_public_completions: public_module_completion_index.has_conditional
		conditional_lines:                  conditional_lines
		symbol_trigrams:                    fuzzy_entry_trigrams(doc_syms)
	}
}

// encode_document_symbols re-encodes the character offsets of `syms` (produced
// as UTF-8 byte offsets by parse_document_symbols) into `enc` units, using
// `lines` for the per-line conversion. Recurses into children (fields, members).
fn encode_document_symbols(syms []DocumentSymbol, lines []string, enc PositionEncoding) []DocumentSymbol {
	if enc == .utf8 {
		return syms // already byte offsets
	}
	mut out := []DocumentSymbol{cap: syms.len}
	for sym in syms {
		out << DocumentSymbol{
			name:            sym.name
			kind:            sym.kind
			tags:            sym.tags
			range:           encode_range_chars(sym.range, lines, enc)
			selection_range: encode_range_chars(sym.selection_range, lines, enc)
			children:        encode_document_symbols(sym.children, lines, enc)
		}
	}
	return out
}

// encode_range_chars converts the byte-offset character fields of `r` into `enc`
// units using the corresponding source lines.
fn encode_range_chars(r LSPRange, lines []string, enc PositionEncoding) LSPRange {
	start_line := if r.start.line >= 0 && r.start.line < lines.len {
		lines[r.start.line]
	} else {
		''
	}
	end_line := if r.end.line >= 0 && r.end.line < lines.len {
		lines[r.end.line]
	} else {
		''
	}
	return LSPRange{
		start: Position{
			line: r.start.line
			char: byte_to_encoded_col(start_line, r.start.char, enc)
		}
		end:   Position{
			line: r.end.line
			char: byte_to_encoded_col(end_line, r.end.char, enc)
		}
	}
}

// index_source_for returns the authoritative content for `uri`: the open buffer
// when the document is open, otherwise the on-disk file. Returns none when the
// file is neither open nor readable.
fn (app &App) index_source_for(uri string) ?string {
	if content := app.open_files[uri] {
		return content
	}
	return os.read_file(uri_to_path(uri)) or { none }
}

// TokenOccurrence is one identifier occurrence in a file, with its position in
// the client's negotiated encoding.
struct TokenOccurrence {
	line       int
	start_char int
	end_char   int
}

// OccEntry caches the identifier occurrences of one file, keyed by content
// fingerprint so unchanged files are not re-tokenized.
struct OccEntry {
	fingerprint int
	occ         map[string][]TokenOccurrence
}

struct OccurrenceInterpolationState {
	quote u8
mut:
	brace_depth int
}

struct OccurrenceScanState {
mut:
	block_comment_depth int
	quote               u8
	raw_string          bool
	interpolations      []OccurrenceInterpolationState
}

fn add_identifier_occurrence(line_text string, line_idx int, start int, end int, enc PositionEncoding, mut occ map[string][]TokenOccurrence) {
	if line_text[start] >= `0` && line_text[start] <= `9` {
		return
	}
	name := line_text[start..end]
	occ[name] << TokenOccurrence{
		line:       line_idx
		start_char: byte_to_encoded_col(line_text, start, enc)
		end_char:   byte_to_encoded_col(line_text, end, enc)
	}
}

// scan_literal_identifier_occurrences skips string and rune literal text while
// indexing V string interpolation expressions. It preserves an unterminated
// quote across source lines and returns the byte after the closing quote or the
// end of the line.
fn scan_literal_identifier_occurrences(line_text string, line_idx int, start int, enc PositionEncoding, mut state OccurrenceScanState, mut occ map[string][]TokenOccurrence) int {
	mut col := start
	if state.quote == 0 {
		state.quote = line_text[start]
		col++
	}
	quote := state.quote
	for col < line_text.len {
		if line_text[col] == `\\` && !state.raw_string {
			col += 2
			continue
		}
		if line_text[col] == quote {
			state.quote = 0
			state.raw_string = false
			return col + 1
		}
		if !state.raw_string && line_text[col] == `$` && col + 1 < line_text.len
			&& line_text[col + 1] == `{` {
			state.quote = 0
			state.interpolations << OccurrenceInterpolationState{
				quote: quote
			}
			return scan_code_identifier_occurrences(line_text, line_idx, col + 2, enc, mut state, mut occ)
		}
		col++
	}
	return col
}

// scan_code_identifier_occurrences indexes code between `start` and the end of
// the line. Braced interpolation state is retained across lines, including its
// nested brace depth, and the suspended literal resumes after the matching `}`.
fn scan_code_identifier_occurrences(line_text string, line_idx int, start int, enc PositionEncoding, mut state OccurrenceScanState, mut occ map[string][]TokenOccurrence) int {
	mut col := start
	for col < line_text.len {
		if state.quote != 0 {
			col = scan_literal_identifier_occurrences(line_text, line_idx, col, enc, mut state, mut occ)
			continue
		}
		c := line_text[col]
		if state.block_comment_depth > 0 {
			if col + 1 < line_text.len && c == `/` && line_text[col + 1] == `*` {
				state.block_comment_depth++
				col += 2
				continue
			}
			if col + 1 < line_text.len && c == `*` && line_text[col + 1] == `/` {
				state.block_comment_depth--
				col += 2
				continue
			}
			col++
			continue
		}
		if col + 1 < line_text.len && c == `/` && line_text[col + 1] == `/` {
			return line_text.len
		}
		if col + 1 < line_text.len && c == `/` && line_text[col + 1] == `*` {
			state.block_comment_depth = 1
			col += 2
			continue
		}
		if c in [`r`, `c`] && col + 1 < line_text.len
			&& (line_text[col + 1] == `"` || line_text[col + 1] == `'`) {
			state.raw_string = c == `r`
			col = scan_literal_identifier_occurrences(line_text, line_idx, col + 1, enc, mut state, mut occ)
			continue
		}
		if c == `"` || c == `'` || c == 96 {
			col =
				scan_literal_identifier_occurrences(line_text, line_idx, col, enc, mut state, mut occ)
			continue
		}
		if c == `{` {
			if state.interpolations.len > 0 {
				last := state.interpolations.len - 1
				state.interpolations[last].brace_depth++
			}
			col++
			continue
		}
		if c == `}` && state.interpolations.len > 0 {
			last := state.interpolations.len - 1
			if state.interpolations[last].brace_depth == 0 {
				interpolation := state.interpolations.pop()
				state.quote = interpolation.quote
			} else {
				state.interpolations[last].brace_depth--
			}
			col++
			continue
		}
		if is_ident_char(c) {
			ident_start := col
			col++
			for col < line_text.len && is_ident_char(line_text[col]) {
				col++
			}
			add_identifier_occurrence(line_text, line_idx, ident_start, col, enc, mut occ)
			continue
		}
		col++
	}
	return col
}

// extract_identifier_occurrences returns every identifier occurrence in `content`
// grouped by name, positioned in `enc` units. Comments and string literal text
// are skipped across source lines, interpolation expressions are scanned, and
// number literals are ignored. This is the reference-index tokenizer:
// references/rename read candidates from here instead of re-walking and
// re-tokenizing files per request (P1-05).
fn extract_identifier_occurrences(content string, enc PositionEncoding) map[string][]TokenOccurrence {
	mut occ := map[string][]TokenOccurrence{}
	mut state := OccurrenceScanState{}
	for line_idx, line_text in content.split_into_lines() {
		scan_code_identifier_occurrences(line_text, line_idx, 0, enc, mut state, mut occ)
	}
	return occ
}

// occurrences_for returns the identifier occurrences of `uri`, building and
// caching them from the authoritative source (open buffer or disk) and reusing
// the cache while the content fingerprint is unchanged.
fn (mut app App) occurrences_for(uri string) map[string][]TokenOccurrence {
	content := app.index_source_for(uri) or {
		app.ref_occurrences.delete(uri)
		return map[string][]TokenOccurrence{}
	}
	fp := content.hash()
	if existing := app.ref_occurrences[uri] {
		if existing.fingerprint == fp {
			return existing.occ
		}
	}
	occ := extract_identifier_occurrences(content, app.position_encoding)
	app.ref_occurrences[uri] = OccEntry{
		fingerprint: fp
		occ:         occ
	}
	return occ
}

// drop_index_uri removes all cached index data for `uri`.
fn (mut app App) drop_index_uri(uri string) {
	app.symbol_index.delete(uri)
	app.ref_occurrences.delete(uri)
}

// drop_index_aliases_for_path removes cached URI spellings for the same physical
// file, retaining `keep_uri` when it is the canonical disk key or another open
// buffer still owns the file.
fn (mut app App) drop_index_aliases_for_path(path string, keep_uri string) {
	target_path := normalized_index_path(path)
	for uri in app.symbol_index.keys() {
		if uri != keep_uri && normalized_index_path(uri_to_path(uri)) == target_path {
			app.symbol_index.delete(uri)
		}
	}
	for uri in app.ref_occurrences.keys() {
		if uri != keep_uri && normalized_index_path(uri_to_path(uri)) == target_path {
			app.ref_occurrences.delete(uri)
		}
	}
	for uri in app.index_skipped_uris.keys() {
		if uri != keep_uri && normalized_index_path(uri_to_path(uri)) == target_path {
			app.index_skipped_uris.delete(uri)
		}
	}
}

// normalized_index_path returns a stable filesystem key for matching a path
// discovered by a directory walk to an already-open document URI. Resolving the
// real path collapses equivalent URI spellings such as file://localhost/tmp/a.v
// and file:///tmp/a.v. Windows filesystem paths are case-insensitive.
fn normalized_index_path(path string) string {
	mut normalized := os.real_path(path).replace('\\', '/')
	$if windows {
		normalized = normalized.to_lower()
	}
	return normalized
}

// open_index_uris_by_path maps normalized filesystem paths to the original URI
// supplied by the client. Open buffers are authoritative, so index entries and
// result locations must retain that URI rather than a reconstructed equivalent.
fn (app &App) open_index_uris_by_path() map[string]string {
	mut uris := map[string]string{}
	for uri, _ in app.open_files {
		uris[normalized_index_path(uri_to_path(uri))] = uri
	}
	return uris
}

// index_uri_for_path returns the client's URI when `path` names an open
// document, otherwise it constructs the canonical file URI used for disk files.
fn index_uri_for_path(path string, open_uris_by_path map[string]string) string {
	return open_uris_by_path[normalized_index_path(path)] or { path_to_uri(path) }
}

// path_is_in_removed_workspace reports whether `path` is under a workspace root
// explicitly removed by the client. A currently active root takes precedence,
// allowing a nested folder to be added again under a removed parent.
fn (app &App) path_is_in_removed_workspace(path string) bool {
	return path_is_under_removed_root(path, app.workspace_roots, app.removed_workspace_roots)
}

// path_is_under_removed_root is path_is_in_removed_workspace for a snapshot of
// the roots. The background index worker carries one: the request thread may
// replace the App's root slices at any time, and the worker must not read a
// slice while that happens.
fn path_is_under_removed_root(path string, active_roots []string, removed_roots []string) bool {
	p := path.replace('\\', '/')
	for root in active_roots {
		if path_is_within(p, root.replace('\\', '/')) {
			return false
		}
	}
	for root in removed_roots {
		if path_is_within(p, root.replace('\\', '/')) {
			return true
		}
	}
	return false
}

// reindex_uri (re)parses `uri` from its authoritative source, skipping work when
// the content fingerprint is unchanged. Open buffers are always authoritative.
// Disk-backed entries obey the same file-size and total-entry limits as workspace
// walks, including when this function is reached through file-watcher events.
fn (mut app App) reindex_uri(uri string) {
	mut content := ''
	if open_content := app.open_files[uri] {
		// Open buffers bypass the disk size gate below; apply it here so a
		// huge buffer cannot force an unbounded index build.
		if u64(open_content.len) > index_max_file_bytes {
			app.drop_index_uri(uri)
			app.index_skipped_uris[uri] = true
			return
		}
		content = open_content
		app.index_skipped_uris.delete(uri)
	} else {
		path := uri_to_path(uri)
		if app.path_is_in_removed_workspace(path) {
			app.drop_index_uri(uri)
			app.index_skipped_uris.delete(uri)
			return
		}
		if !os.is_file(path) {
			app.drop_index_uri(uri)
			app.index_skipped_uris.delete(uri)
			return
		}
		if os.file_size(path) > index_max_file_bytes {
			app.drop_index_uri(uri)
			app.index_skipped_uris[uri] = true
			return
		}
		if uri !in app.symbol_index && app.symbol_index.len >= index_max_files {
			app.ref_occurrences.delete(uri)
			app.index_skipped_uris[uri] = true
			return
		}
		content = os.read_file(path) or {
			app.drop_index_uri(uri)
			app.index_skipped_uris[uri] = true
			return
		}
		app.index_skipped_uris.delete(uri)
	}
	fp := content.hash()
	if existing := app.symbol_index[uri] {
		if existing.fingerprint == fp {
			return
		}
	}
	app.symbol_index[uri] = build_index_entry(content, app.position_encoding)
}

// invalidate_index_uri drops a URI's entry so it is re-parsed on next access.
fn (mut app App) invalidate_index_uri(uri string) {
	app.symbol_index.delete(uri)
}

// drop_index_under removes indexed symbols and occurrence caches for every file
// whose path is inside `dir_path`, and marks all project dirs for re-walk. Used
// when a workspace folder is removed so its entries do not linger stale. Any
// still-open files are re-indexed from their buffers on the next query.
fn (mut app App) drop_index_under(dir_path string) {
	d := dir_path.replace('\\', '/')
	for uri in app.symbol_index.keys() {
		if path_is_within(uri_to_path(uri).replace('\\', '/'), d) {
			app.symbol_index.delete(uri)
		}
	}
	for uri in app.ref_occurrences.keys() {
		if path_is_within(uri_to_path(uri).replace('\\', '/'), d) {
			app.ref_occurrences.delete(uri)
		}
	}
	for uri in app.index_skipped_uris.keys() {
		if path_is_within(uri_to_path(uri).replace('\\', '/'), d) {
			app.index_skipped_uris.delete(uri)
		}
	}
	// Re-walk on next query (a removed folder must not be re-indexed).
	app.indexed_dirs.clear()
	app.indexed_dir_walk_ms.clear()
	app.index_incomplete_scopes.clear()
}

// Bounds and exclusions for the workspace walk. Without these a stray file
// opened at a large directory (a home dir, /tmp, or the filesystem root) would
// pull the entire tree into the index (audit: "unbounded workspace traversal").
const index_max_files = 20000
const index_max_file_bytes = u64(2 * 1024 * 1024)
const index_excluded_dirs = ['.git', '.svn', '.hg', 'node_modules', '.vmodules', 'thirdparty',
	'_build', 'build', 'target', '.cache']

// find_project_root walks up from `dir` looking for a `v.mod` file and returns
// the directory that contains it, or '' if none is found before the filesystem
// root. This models the nearest V project root (audit P1-01).
fn find_project_root(dir string) string {
	mut d := dir
	for d != '' && d != '/' && d != '.' {
		if os.exists(os.join_path(d, 'v.mod')) {
			return d
		}
		parent := os.dir(d)
		if parent == d {
			break
		}
		d = parent
	}
	return ''
}

// collect_v_files recursively gathers `.v` files under `root`, skipping hidden
// and known heavy directories and stopping once `index_max_files` is reached.
// It returns false when a limit or filesystem error prevents a complete walk.
fn collect_v_files(root string, mut acc []string) bool {
	return collect_v_files_bounded(root, index_max_files, mut acc)
}

// index_reserve_target is how many index entries a walk should pre-size for,
// bounded by the global file cap. A partial walk reserves what it found, so
// the growth toward that cap stays bounded in both cases; 0 means reserve
// nothing.
fn index_reserve_target(indexed int, found int) int {
	want := indexed + found
	if want <= 0 || want > index_max_files {
		return 0
	}
	return want
}

// collect_v_files_bounded stops at the caller's file limit, and at four times
// that many directory entries so trees without V files are bounded too.
fn collect_v_files_bounded(root string, max_files int, mut acc []string) bool {
	mut visited := map[string]bool{}
	canonical_root := os.real_path(root).replace('\\', '/')
	mut entries_seen := IndexWalkBudget{}
	return collect_v_files_rec(root, canonical_root, max_files, mut acc, mut visited, mut entries_seen)
}

struct IndexWalkBudget {
mut:
	entries int
}

// collect_v_files_rec is the recursive worker; `visited` holds canonical
// directories and files already seen, so symlink cycles and file aliases cannot
// cause infinite recursion or duplicate index entries. `canonical_root` bounds
// the walk to the workspace: a resolved path that escapes it is skipped.
fn collect_v_files_rec(dir string, canonical_root string, max_files int, mut acc []string, mut visited map[string]bool, mut entries_seen IndexWalkBudget) bool {
	if acc.len >= max_files {
		return false
	}
	real := os.real_path(dir).replace('\\', '/')
	if real in visited {
		return true
	}
	// Containment: os.real_path resolves symlinks, so a symlinked directory whose
	// target lies outside the workspace root is rejected here rather than walked.
	if !path_is_within(real, canonical_root) {
		return true
	}
	visited[real] = true
	entries := os.ls(dir) or { return false }
	for entry in entries {
		if acc.len >= max_files {
			return false
		}
		if entries_seen.entries >= max_files * 4 {
			return false
		}
		entries_seen.entries++
		full := os.join_path(dir, entry)
		if os.is_dir(full) {
			if entry.starts_with('.') || entry in index_excluded_dirs {
				continue
			}
			if !collect_v_files_rec(full, canonical_root, max_files, mut acc, mut visited, mut entries_seen) {
				return false
			}
		} else if entry.ends_with('.v') {
			// Directory containment is not enough: an in-tree file symlink can
			// point outside the workspace. Resolve every candidate and retain it
			// only when its canonical target remains under the canonical root.
			real_file := os.real_path(full).replace('\\', '/')
			if path_is_within(real_file, canonical_root) && real_file !in visited {
				visited[real_file] = true
				acc << full
			}
		}
	}
	return true
}

// index_refresh_interval_ms bounds how often a directory is re-walked when the
// client provides no file watchers. Without watcher notifications the index would
// otherwise never discover files created after the first walk, nor pick up disk
// edits to unopened files, until the server restarts.
const index_refresh_interval_ms = i64(10_000)

// index_dir_needs_refresh reports whether an already-walked `dir` should be
// re-scanned. Only once the client has actually acknowledged watcher
// registration do we rely on didChangeWatchedFiles and stop re-walking; if the
// client never supported it, or advertised it but rejected the registration
// request, watcher notifications will not arrive, so we keep re-walking on a
// throttled interval to stay fresh.
fn (app &App) index_dir_needs_refresh(dir string) bool {
	if app.watched_files_active {
		return false
	}
	last := app.indexed_dir_walk_ms[dir] or { return true }
	return time.now().unix_milli() - last > index_refresh_interval_ms
}

// reconcile_indexed_dir removes stale entries only after a complete recursive
// walk. A partial walk cannot distinguish deleted files from files it did not
// reach, so reconciling it would incorrectly discard valid indexed symbols.
fn (mut app App) reconcile_indexed_dir(dir string, present map[string]bool, walk_complete bool) {
	if !walk_complete {
		return
	}
	dir_norm := dir.replace('\\', '/')
	for uri in app.symbol_index.keys() {
		if uri in app.open_files || uri in present {
			continue
		}
		if path_is_within(uri_to_path(uri).replace('\\', '/'), dir_norm) {
			app.symbol_index.delete(uri)
			app.ref_occurrences.delete(uri)
		}
	}
}

// ensure_dirs_indexed makes sure every open buffer and every `.v` file under the
// given project `dirs` has an up-to-date index entry. A dir is walked once and
// then, when no client file watchers are available, re-walked on a throttled
// interval (see index_dir_needs_refresh) so new and changed unopened files are
// still discovered. Unchanged files are skipped via a fingerprint check, so a
// refresh walk only re-parses what actually changed.
fn (mut app App) ensure_dirs_indexed(dirs []string) {
	// Open buffers are authoritative; keep their entries fresh (cheap fingerprint
	// check skips unchanged content).
	for uri, _ in app.open_files {
		app.reindex_uri(uri)
	}
	open_uris_by_path := app.open_index_uris_by_path()
	for dir in dirs {
		if dir == '' || dir == '/' || app.path_is_in_removed_workspace(dir) || !os.is_dir(dir) {
			continue
		}
		if dir in app.indexed_dirs && !app.index_dir_needs_refresh(dir) {
			continue
		}
		mut files := []string{}
		scope := 'recursive:${dir}'
		app.index_incomplete_scopes.delete(scope)
		walk_complete := collect_v_files(dir, mut files)
		if !walk_complete {
			app.index_incomplete_scopes[scope] = true
		}
		// Pre-size once: inserting thousands of entries one by one would
		// otherwise double the backing store repeatedly, and a late doubling
		// can fail under a fragmented heap (GC_alloc_large abort on big trees).
		target := index_reserve_target(app.symbol_index.len, files.len)
		if target > 0 {
			app.symbol_index.reserve(u32(target))
		}
		mut present := map[string]bool{}
		for f in files {
			present[index_uri_for_path(f, open_uris_by_path)] = true
		}
		// Reconcile the existing index against what is actually on disk: drop
		// entries for non-open files under `dir` that the walk no longer found.
		// Without client watchers there is no delete notification, so a removed
		// unopened file would otherwise linger in symbol/hover/call results. A
		// partial walk must retain old entries it may simply not have reached.
		app.reconcile_indexed_dir(dir, present, walk_complete)
		for f in files {
			uri := index_uri_for_path(f, open_uris_by_path)
			if uri in app.open_files {
				continue
			}
			if uri in app.symbol_index {
				// Already indexed: on a refresh walk, re-read from disk so edits to
				// unopened files are picked up (the fingerprint check skips work
				// when the content is unchanged).
				app.reindex_uri(uri)
				continue
			}
			if app.symbol_index.len >= index_max_files {
				app.index_incomplete_scopes[scope] = true
				break
			}
			app.reindex_uri(uri)
		}
		app.indexed_dirs[dir] = true
		app.indexed_dir_walk_ms[dir] = time.now().unix_milli()
	}
}

// ensure_dir_shallow_indexed indexes the `.v` files directly in `dir` (no
// recursion). A V module occupies a single directory, so this is all that is
// needed for same-module lookups such as completion, and it is cheap enough to
// run on a keystroke. New files are always picked up; when the client provides
// no file watchers, already-indexed siblings are also refreshed on a throttled
// interval (fingerprint check skips unchanged content) and entries for files
// deleted from `dir` are reconciled out — otherwise a stale or removed unopened
// sibling would keep contributing completions until restart.
fn (mut app App) ensure_dir_shallow_indexed(dir string) {
	if dir == '' || dir == '/' || app.path_is_in_removed_workspace(dir) || !os.is_dir(dir) {
		return
	}
	scope := 'shallow:${dir}'
	app.index_incomplete_scopes.delete(scope)
	refresh := app.index_dir_needs_refresh(dir)
	canonical_dir := os.real_path(dir).replace('\\', '/')
	open_uris_by_path := app.open_index_uris_by_path()
	mut present := map[string]bool{}
	mut entries := os.ls(dir) or {
		app.index_incomplete_scopes[scope] = true
		return
	}
	entries.sort()
	mut scan_complete := true
	for entry in entries {
		if !entry.ends_with('.v') {
			continue
		}
		full := os.join_path(dir, entry)
		if !os.is_file(full) {
			continue
		}
		// os.is_file follows symlinks. Resolve the candidate as well so a
		// directly contained link cannot pull an external source into this
		// loose-module scope.
		real_file := os.real_path(full).replace('\\', '/')
		if !path_is_within(real_file, canonical_dir) {
			continue
		}
		uri := index_uri_for_path(full, open_uris_by_path)
		present[uri] = true
		if uri in app.open_files {
			continue
		}
		if uri in app.symbol_index {
			// Already indexed: on a throttled refresh re-read from disk so external
			// edits to unopened siblings are picked up (fingerprint skips no-ops).
			if refresh {
				app.reindex_uri(uri)
			}
			continue
		}
		if app.symbol_index.len >= index_max_files {
			app.index_incomplete_scopes[scope] = true
			scan_complete = false
			break
		}
		app.reindex_uri(uri)
	}
	if refresh && scan_complete {
		// Reconcile deletions: drop non-open entries for files that were directly
		// in `dir` (shallow, not recursive) but the walk no longer found.
		dir_norm := dir.replace('\\', '/').trim_right('/')
		for uri in app.symbol_index.keys() {
			if uri in app.open_files || uri in present {
				continue
			}
			if os.dir(uri_to_path(uri)).replace('\\', '/').trim_right('/') == dir_norm {
				app.symbol_index.delete(uri)
				app.ref_occurrences.delete(uri)
			}
		}
		for uri in app.index_skipped_uris.keys() {
			if uri in present {
				continue
			}
			if os.dir(uri_to_path(uri)).replace('\\', '/').trim_right('/') == dir_norm {
				app.index_skipped_uris.delete(uri)
			}
		}
	}
	if refresh {
		app.indexed_dir_walk_ms[dir] = time.now().unix_milli()
	}
}

// IndexScope identifies the project or loose module relevant to one source file.
// Recursive scopes are project/workspace roots; shallow scopes are loose-file
// module directories.
struct IndexScope {
	dir       string
	recursive bool
}

// index_scope_for_uri returns the narrowest configured project scope containing
// `uri`. A nested v.mod inside an active workspace root wins; a v.mod outside a
// configured root does not expand that root. Loose and explicitly removed files
// are limited to their immediate directory.
fn (app &App) index_scope_for_uri(uri string) IndexScope {
	path := uri_to_path(uri).replace('\\', '/')
	dir := os.dir(path).replace('\\', '/')
	if dir == '' || dir == '/' {
		return IndexScope{}
	}
	if app.path_is_in_removed_workspace(path) {
		return IndexScope{
			dir: dir
		}
	}
	mut workspace_root := ''
	for root in app.workspace_roots {
		root_norm := root.replace('\\', '/')
		if path_is_within(path, root_norm) && root_norm.len > workspace_root.len {
			workspace_root = root_norm
		}
	}
	project_root := find_project_root(dir).replace('\\', '/')
	if project_root != '' && project_root != '/'
		&& (workspace_root == '' || path_is_within(project_root, workspace_root)) {
		return IndexScope{
			dir:       project_root
			recursive: true
		}
	}
	if workspace_root != '' {
		return IndexScope{
			dir:       workspace_root
			recursive: true
		}
	}
	return IndexScope{
		dir: dir
	}
}

// path_is_in_index_scope reports whether a file belongs to `scope`.
fn path_is_in_index_scope(path string, scope IndexScope) bool {
	if scope.dir == '' {
		return false
	}
	p := path.replace('\\', '/')
	if scope.recursive {
		return path_is_within(p, scope.dir.replace('\\', '/'))
	}
	return normalized_index_path(os.dir(p)) == normalized_index_path(scope.dir)
}

fn uri_is_in_index_scope(uri string, scope IndexScope) bool {
	return path_is_in_index_scope(uri_to_path(uri), scope)
}

// A read request must not pay for the refresh it finds due. A hover, a
// workspace/symbol, a reference or a prepareRename used to walk the workspace
// on the request thread; they now answer from the index as it stands and leave
// the rebuild to one background worker. The worker walks and parses, but it
// never writes the shared index: a request handler may be reading it, and V
// maps are not safe to read while another thread inserts. Its result is merged
// by the request thread at a point where nothing else is reading the index
// (apply_index_refresh_results), which is the same split the diagnostics worker
// uses when it publishes through the scheduler's mutex.

// IndexRefreshJob is one directory a read request found stale, carrying the
// state the refresh needs. That state is snapshotted on the request thread,
// because the worker must reach the index only through this job: the index it
// rebuilds is the one the request handlers read.
struct IndexRefreshJob {
	dir               string
	indexed_count     int             // entries the index held, for the total entry cap
	fingerprints      map[string]int  // uri -> fingerprint of the entry held
	open_uris         map[string]bool // open buffers, which the request thread indexes
	open_uris_by_path map[string]string
	workspace_roots   []string
	removed_roots     []string
	started_ms        i64
}

// IndexRefreshResult is what one refresh walk decided. Nothing in it refers to
// the App, so the request thread can merge it after the worker has stopped.
struct IndexRefreshResult {
mut:
	dir           string
	started_ms    i64
	entries       map[string]IndexEntry // built from the content the walk read
	deletions     []string              // indexed uris whose file the walk no longer found
	skipped       []string              // files left out of the bounded index
	reindexed     int                   // files this walk parsed
	skipped_files int                   // files whose fingerprint was unchanged
	incomplete    bool
	walk_ms       i64
}

// IndexRefreshScheduler owns the single background index worker. It mirrors
// DiagnosticsScheduler: one worker at a time, a done channel the worker closes,
// and a stop that joins it.
@[heap]
struct IndexRefreshScheduler {
mut:
	mutex   sync.Mutex
	pending []IndexRefreshJob
	// outstanding holds every directory with a refresh queued, running, or
	// finished and awaiting its merge. A directory leaves it when the request
	// thread merges the refresh's result, which is what makes a directory's
	// refresh happen once per stale generation however many requests asked.
	outstanding     map[string]bool
	results         []IndexRefreshResult
	worker_running  bool
	worker_started  bool
	worker_done     chan bool
	stopped         bool
	workers_started u64
	refreshes       u64
	reindexed_files u64
	skipped_files   u64
}

fn new_index_refresh_scheduler() &IndexRefreshScheduler {
	return &IndexRefreshScheduler{
		outstanding: map[string]bool{}
	}
}

// enqueue records a job and reports whether the caller must start the single
// background worker. A directory that is outstanding is not queued again, so a
// burst of requests coalesces into one refresh, and the one worker ends when
// the queue runs dry instead of lingering.
fn (mut scheduler IndexRefreshScheduler) enqueue(job IndexRefreshJob) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	if scheduler.stopped || scheduler.outstanding[job.dir] {
		return false
	}
	scheduler.outstanding[job.dir] = true
	scheduler.pending << job
	should_start := !scheduler.worker_running
	if should_start {
		scheduler.worker_started = true
		scheduler.worker_done = chan bool{}
		scheduler.workers_started++
	}
	scheduler.worker_running = true
	return should_start
}

// is_outstanding reports whether a refresh of `dir` is already queued, running,
// or finished and awaiting its merge. The request thread asks first, so a burst
// of requests builds one job snapshot instead of one per request.
fn (mut scheduler IndexRefreshScheduler) is_outstanding(dir string) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	return scheduler.outstanding[dir]
}

// take_next_job removes the scope to refresh next, and reports that there is
// none by stopping the worker, exactly as the diagnostics scheduler does.
fn (mut scheduler IndexRefreshScheduler) take_next_job() ?IndexRefreshJob {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	if scheduler.pending.len == 0 {
		scheduler.worker_running = false
		return none
	}
	job := scheduler.pending[0]
	scheduler.pending.delete(0)
	return job
}

// publish_result records a finished refresh, which the request thread merges.
fn (mut scheduler IndexRefreshScheduler) publish_result(result IndexRefreshResult) {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	scheduler.results << result
	scheduler.refreshes++
	scheduler.reindexed_files += u64(result.reindexed)
	scheduler.skipped_files += u64(result.skipped_files)
}

// take_results hands the finished refreshes over, clears them, and releases the
// directories they covered so a later request can refresh them again.
fn (mut scheduler IndexRefreshScheduler) take_results() []IndexRefreshResult {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	if scheduler.results.len == 0 {
		return []IndexRefreshResult{}
	}
	for result in scheduler.results {
		scheduler.outstanding.delete(result.dir)
	}
	finished := scheduler.results.clone()
	scheduler.results.clear()
	return finished
}

// stop_and_wait joins the background index worker, so the process cannot exit
// while a refresh is still reading files. A refresh that is still queued is not
// dropped: the worker drains it before it ends, so what the index is left with
// does not depend on when the shutdown happened to arrive. This is
// DiagnosticsScheduler's stop_and_wait for the index worker; the diagnostics one
// is untouched.
fn (mut scheduler IndexRefreshScheduler) stop_and_wait() {
	scheduler.mutex.lock()
	scheduler.stopped = true
	started := scheduler.worker_started
	done := scheduler.worker_done
	scheduler.mutex.unlock()
	if started {
		_ := <-done or {}
	}
}

// ensure_indexed_for_request is what a read request calls instead of
// ensure_dirs_indexed. It answers from the index as it stands: not one directory
// is listed on the request thread, and the refresh of whatever is stale is left
// to the background worker, whose result a later request merges.
fn (mut app App) ensure_indexed_for_request(dirs []string) {
	// Open buffers are authoritative, and didOpen/didChange invalidate their
	// entry, so refresh them here. That is one fingerprint comparison per open
	// file: no directory walk, and no parse of unchanged content.
	for uri, _ in app.open_files {
		app.reindex_uri(uri)
	}
	// A refresh that already finished is merged before this request answers, so
	// the request after the one that scheduled it sees what it asked for.
	app.apply_index_refresh_results()
	app.schedule_index_refresh(app.stale_index_dirs(dirs))
}

// stale_index_dirs returns the project directories a read request needs indexed:
// those that were never walked, or whose throttle has expired because the client
// has no file watchers (see index_dir_needs_refresh).
fn (mut app App) stale_index_dirs(dirs []string) []string {
	mut stale := []string{}
	for dir in dirs {
		if dir == '' || dir == '/' || app.path_is_in_removed_workspace(dir) || !os.is_dir(dir) {
			continue
		}
		if dir in app.indexed_dirs && !app.index_dir_needs_refresh(dir) {
			continue
		}
		stale << dir
	}
	return stale
}

// schedule_index_refresh queues `dirs` for the single background worker. Without
// a scheduler — every App built by a test, and none other — the refresh runs on
// the request thread instead, which is what these paths did before.
fn (mut app App) schedule_index_refresh(dirs []string) {
	if dirs.len == 0 {
		return
	}
	if mut scheduler := app.index_refresh {
		for dir in dirs {
			if scheduler.is_outstanding(dir) {
				continue
			}
			job := app.index_refresh_job(dir)
			if scheduler.enqueue(job) {
				spawn run_index_refresh_worker(mut app, mut scheduler)
			}
		}
		return
	}
	app.ensure_dirs_indexed(dirs)
}

// index_refresh_job snapshots the index state a refresh of `dir` needs. It runs
// on the request thread, so the snapshot is consistent.
fn (app &App) index_refresh_job(dir string) IndexRefreshJob {
	mut fingerprints := map[string]int{}
	for uri, entry in app.symbol_index {
		fingerprints[uri] = entry.fingerprint
	}
	mut open_uris := map[string]bool{}
	for uri, _ in app.open_files {
		open_uris[uri] = true
	}
	return IndexRefreshJob{
		dir:               dir
		indexed_count:     app.symbol_index.len
		fingerprints:      fingerprints
		open_uris:         open_uris
		open_uris_by_path: app.open_index_uris_by_path()
		workspace_roots:   app.workspace_roots.clone()
		removed_roots:     app.removed_workspace_roots.clone()
		started_ms:        time.now().unix_milli()
	}
}

// run_index_refresh_worker is the single background index worker. It refreshes
// one directory at a time and returns once the queue is empty, so a burst of
// requests costs one thread that ends with the work.
fn run_index_refresh_worker(mut app App, mut scheduler IndexRefreshScheduler) {
	scheduler.mutex.lock()
	done := scheduler.worker_done
	scheduler.mutex.unlock()
	defer {
		done.close()
	}
	for {
		if job := scheduler.take_next_job() {
			scheduler.publish_result(app.run_recursive_index_refresh(job))
			continue
		}
		return
	}
}

// run_recursive_index_refresh is ensure_dirs_indexed for one directory, with the
// writes collected into a result instead of applied. It reads the filesystem and
// parses, and it touches no App state.
fn (mut app App) run_recursive_index_refresh(job IndexRefreshJob) IndexRefreshResult {
	mut result := IndexRefreshResult{
		dir:        job.dir
		started_ms: job.started_ms
		walk_ms:    time.now().unix_milli()
	}
	mut files := []string{}
	walk_complete := collect_v_files(job.dir, mut files)
	result.incomplete = !walk_complete
	mut entries := map[string]IndexEntry{}
	mut present := map[string]bool{}
	for f in files {
		present[index_uri_for_path(f, job.open_uris_by_path)] = true
	}
	// Reconcile before the file loop, while `walk_complete` still says whether
	// every file of the directory was seen: an incomplete walk could simply not
	// have reached a file that is still there (see reconcile_indexed_dir).
	if walk_complete {
		dir_norm := job.dir.replace('\\', '/')
		for uri, _ in job.fingerprints {
			if uri in present || uri in job.open_uris {
				continue
			}
			if path_is_within(uri_to_path(uri).replace('\\', '/'), dir_norm) {
				result.deletions << uri
			}
		}
	}
	for f in files {
		uri := index_uri_for_path(f, job.open_uris_by_path)
		if uri in job.open_uris {
			continue
		}
		if app.index_refresh_file(uri, job, mut result, mut entries) {
			break
		}
	}
	result.entries = entries.move()
	return result
}

// index_refresh_file decides what a refresh does with the file at `uri`: build
// its entry, skip it because its content fingerprint is unchanged or it is out
// of the index's bounds, or drop it because it is gone. It returns true when the
// walk must stop, which is only at the total entry cap.
fn (mut app App) index_refresh_file(uri string, job IndexRefreshJob, mut result IndexRefreshResult, mut entries map[string]IndexEntry) bool {
	path := uri_to_path(uri)
	if path_is_under_removed_root(path, job.workspace_roots, job.removed_roots) {
		result.deletions << uri
		return false
	}
	if !os.is_file(path) {
		result.deletions << uri
		return false
	}
	if os.file_size(path) > index_max_file_bytes {
		result.skipped << uri
		return false
	}
	content := os.read_file(path) or {
		result.skipped << uri
		return false
	}
	fingerprint := content.hash()
	if previous := job.fingerprints[uri] {
		if previous == fingerprint {
			result.skipped_files++
			return false
		}
	}
	if uri !in job.fingerprints && job.indexed_count + entries.len >= index_max_files {
		result.incomplete = true
		result.skipped << uri
		return true
	}
	entries[uri] = build_index_entry(content, app.position_encoding)
	result.reindexed++
	return false
}

// apply_index_refresh_results merges the refreshes the background worker
// finished. It runs on the request thread, where no other thread is reading the
// index, which is why the worker never writes the index itself.
fn (mut app App) apply_index_refresh_results() {
	mut scheduler := app.index_refresh or { return }
	for mut result in scheduler.take_results() {
		app.merge_index_refresh(mut result)
	}
}

fn (mut app App) merge_index_refresh(mut result IndexRefreshResult) {
	dir := result.dir
	scope := 'recursive:${dir}'
	if dir == '' || dir == '/' || app.path_is_in_removed_workspace(dir) {
		// A root removed while the refresh ran: nothing it found belongs here.
		return
	}
	if !os.is_dir(dir) {
		// The folder vanished during the walk, so the walk found nothing in it,
		// which is what a complete walk of it would have recorded.
		result.incomplete = true
	}
	if result.entries.len > 0 {
		// Pre-size once, for the same reason ensure_dirs_indexed does.
		app.symbol_index.reserve(u32(index_reserve_target(app.symbol_index.len, result.entries.len)))
	}
	for uri, entry in result.entries {
		if uri in app.open_files {
			continue // the request thread indexes open buffers itself
		}
		app.symbol_index[uri] = entry
	}
	for uri in result.skipped {
		if uri in app.open_files {
			continue
		}
		app.drop_index_uri(uri)
		app.index_skipped_uris[uri] = true
	}
	for uri in result.deletions {
		if uri in app.open_files {
			continue
		}
		app.drop_index_uri(uri)
		app.index_skipped_uris.delete(uri)
	}
	app.indexed_dirs[dir] = true
	if result.walk_ms > 0 {
		app.indexed_dir_walk_ms[dir] = result.walk_ms
	}
	if result.incomplete {
		app.index_incomplete_scopes[scope] = true
	} else {
		app.index_incomplete_scopes.delete(scope)
	}
	if os.getenv('VLS_PERF_LOG') != '' {
		elapsed_ms := time.now().unix_milli() - result.started_ms
		app.send_log_message('index-refresh scope=${scope} indexed=${result.reindexed} skipped=${result.skipped_files} deleted=${result.deletions.len} elapsed_ms=${elapsed_ms}',
			4)
	}
}

// stop_index_refresh joins the background index worker, so the process cannot
// exit while a refresh is still reading files. It is the equivalent of
// stop_diagnostics_servers for the index worker.
fn (mut app App) stop_index_refresh() {
	if mut scheduler := app.index_refresh {
		scheduler.stop_and_wait()
	}
}

// index_scope_key names a scope the way the index already stores it: a
// recursive walk of a project root and a shallow walk of a loose module
// directory are different scopes, even for the same directory.
fn index_scope_key(scope IndexScope) string {
	kind := if scope.recursive { 'recursive' } else { 'shallow' }
	return '${kind}:${scope.dir}'
}

// ensure_index_scope indexes only the project/module relevant to a request, on
// the thread that asked. A destructive request (rename, linked editing) must
// not answer before its own scope is indexed; a read request uses
// ensure_index_scope_for_request instead.
fn (mut app App) ensure_index_scope(scope IndexScope) {
	if scope.dir == '' || scope.dir == '/' {
		return
	}
	if scope.recursive {
		app.ensure_dirs_indexed([scope.dir])
		return
	}
	app.ensure_shallow_scope_indexed(scope)
}

// ensure_shallow_scope_indexed indexes the open buffers of `scope` and the
// directory itself, shallowly: a V module occupies one directory, so this is
// all a same-module lookup needs and it costs one listing.
fn (mut app App) ensure_shallow_scope_indexed(scope IndexScope) {
	for uri, _ in app.open_files {
		if uri_is_in_index_scope(uri, scope) {
			app.reindex_uri(uri)
		}
	}
	app.ensure_dir_shallow_indexed(scope.dir)
}

// ensure_index_scope_for_request is the read-request answer to
// ensure_index_scope: the open buffers are refreshed (a fingerprint check per
// open file, no walk), and the scope's walk is left to the background worker.
// A shallow scope stays on the request thread, because it has always been the
// cost of one directory listing.
fn (mut app App) ensure_index_scope_for_request(scope IndexScope) {
	if scope.dir == '' || scope.dir == '/' {
		return
	}
	if scope.recursive {
		app.ensure_indexed_for_request([scope.dir])
		return
	}
	app.ensure_shallow_scope_indexed(scope)
}

// index_is_complete_for_scope reports whether every source relevant to a
// destructive operation in `scope` was indexed.
fn (app &App) index_is_complete_for_scope(scope IndexScope) bool {
	if scope.dir == '' {
		return false
	}
	if index_scope_key(scope) in app.index_incomplete_scopes {
		return false
	}
	for uri, _ in app.index_skipped_uris {
		if uri_is_in_index_scope(uri, scope) && os.is_file(uri_to_path(uri)) {
			return false
		}
	}
	return true
}

// index_is_complete reports whether every discovered disk source was indexed.
// Non-destructive queries may use a partial bounded index.
fn (app &App) index_is_complete() bool {
	if app.index_incomplete_scopes.len > 0 {
		return false
	}
	for uri, _ in app.index_skipped_uris {
		if os.is_file(uri_to_path(uri)) {
			return false
		}
	}
	return true
}

// query_module_fn_completions returns free-function completion items from the
// indexed files in `dir` that belong to `module_name`, excluding `exclude_uri`
// and test files. A V module occupies a single directory, so the results are
// constrained to `dir` as well as the module name: without that, distinct
// directories that share a common module name (e.g. `main`) would leak
// completions from unrelated indexed projects into each other. The index must
// already cover the relevant files.
fn (app &App) query_module_fn_completions(module_name string, exclude_uri string, dir string) []Detail {
	d := dir.replace('\\', '/').trim_right('/')
	mut items := []Detail{}
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		if uri == exclude_uri || uri.ends_with('_test.v') {
			continue
		}
		if d != '' && os.dir(uri_to_path(uri)).replace('\\', '/').trim_right('/') != d {
			continue
		}
		entry := app.symbol_index[uri] or { continue }
		if module_name != '' && entry.module_name != module_name {
			continue
		}
		items << entry.fn_completions
	}
	return items
}

// index_query_dirs returns the project directories to index: the configured
// workspace roots plus the nearest `v.mod` root of each open file. A loose file
// with no project root contributes only its own (already indexed) buffer, so an
// arbitrary parent directory is never recursively walked (P1-01).
fn (app &App) index_query_dirs() []string {
	mut seen := map[string]bool{}
	mut dirs := []string{}
	for root in app.workspace_roots {
		if root != '' && root != '/' && root !in seen {
			seen[root] = true
			dirs << root
		}
	}
	for uri, _ in app.open_files {
		open_path := uri_to_path(uri).replace('\\', '/')
		mut covered := false
		for workspace_root in app.workspace_roots {
			if path_is_within(open_path, workspace_root.replace('\\', '/')) {
				covered = true
				break
			}
		}
		if covered || app.path_is_in_removed_workspace(open_path) {
			continue
		}
		root := find_project_root(os.dir(open_path))
		if root != '' && root != '/' && root !in seen {
			seen[root] = true
			dirs << root
		}
	}
	dirs.sort()
	return dirs
}

// ensure_loose_file_dirs_shallow_indexed shallow-indexes the directory of every
// open file that no recursive project walk covers — a multi-file module opened
// with no `v.mod` and no workspace root. Its sibling `.v` files must be indexed
// so references and rename see every occurrence (a partial rename would leave
// the module uncompilable), but the parent may be an arbitrary directory (a home
// dir, `/tmp`), so it is indexed shallowly rather than walked recursively
// (P1-01). Files already covered by index_query_dirs are skipped.
fn (mut app App) ensure_loose_file_dirs_shallow_indexed() {
	query_dirs := app.index_query_dirs()
	mut done := map[string]bool{}
	for uri, _ in app.open_files {
		dir := os.dir(uri_to_path(uri)).replace('\\', '/')
		if dir == '' || dir == '/' || dir in done {
			continue
		}
		done[dir] = true
		mut covered := false
		for qd in query_dirs {
			if path_is_within(dir, qd.replace('\\', '/')) {
				covered = true
				break
			}
		}
		if !covered {
			if app.path_is_in_removed_workspace(dir) {
				continue
			}
			app.ensure_dir_shallow_indexed(dir)
		}
	}
}

// query_workspace_symbols returns indexed symbols matching `query`,
// ranked by trigram overlap first and by exact/prefix/substring/subsequence
// preference second (see fuzzy_index.v). An empty query lists every indexed
// symbol, including struct fields and enum members as `Parent.child`. The
// index must already be populated.
fn (app &App) query_workspace_symbols(query string) []WorkspaceSymbol {
	q := query.to_lower()
	mut uris := app.symbol_index.keys()
	uris.sort()
	if q == '' {
		mut results := []WorkspaceSymbol{}
		mut seen := map[string]bool{}
		for uri in uris {
			entry := app.symbol_index[uri] or { continue }
			for sym in entry.doc_symbols {
				add_workspace_symbol(mut results, mut seen, sym.name, sym.kind, uri, sym.selection_range)
				for child in sym.children {
					add_workspace_symbol(mut results, mut seen, '${sym.name}.${child.name}', child.kind, uri, child.selection_range)
				}
			}
		}
		return results
	}
	nq := fuzzy_normalize(query)
	use_fuzzy_recall := nq.len >= 3
	query_tris := fuzzy_trigrams(nq)
	mut ranked := []FuzzyRankedSymbol{}
	for uri in uris {
		entry := app.symbol_index[uri] or { continue }
		for sym in entry.doc_symbols {
			fuzzy_rank_symbol(mut ranked, uri, sym.name, sym.kind, sym.selection_range, entry.symbol_trigrams[sym.name], q, nq, query_tris, use_fuzzy_recall)
			for child in sym.children {
				child_name := '${sym.name}.${child.name}'
				fuzzy_rank_symbol(mut ranked, uri, child_name, child.kind, child.selection_range, entry.symbol_trigrams[child_name], q, nq, query_tris, use_fuzzy_recall)
			}
		}
	}
	ranked.sort_with_compare(fuzzy_rank_compare)
	mut results := []WorkspaceSymbol{}
	mut seen := map[string]bool{}
	for r in ranked {
		add_workspace_symbol(mut results, mut seen, r.name, r.kind, r.uri, r.sel)
	}
	return results
}

// find_indexed_doc_in_scope returns the vdoc comment for `name`. When
// `preferred_dir` is set (for a qualified imported symbol), only that module
// directory is searched. Otherwise the current module is preferred and the
// fallback is limited to `scope_root`.
fn (app &App) find_indexed_doc_in_scope(name string, cur_dir string, scope_root string, preferred_dir string) string {
	cd := cur_dir.replace('\\', '/').trim_right('/')
	pd := preferred_dir.replace('\\', '/').trim_right('/')
	mut uris := app.symbol_index.keys()
	uris.sort()
	if pd != '' {
		for uri in uris {
			if os.dir(uri_to_path(uri)).replace('\\', '/').trim_right('/') != pd {
				continue
			}
			entry := app.symbol_index[uri] or { continue }
			if doc := entry.docs[name] {
				if doc != '' {
					return doc
				}
			}
		}
		return ''
	}
	// Pass 1: the current module directory (where a same-module symbol lives).
	if cd != '' {
		for uri in uris {
			if os.dir(uri_to_path(uri)).replace('\\', '/').trim_right('/') != cd {
				continue
			}
			entry := app.symbol_index[uri] or { continue }
			if doc := entry.docs[name] {
				if doc != '' {
					return doc
				}
			}
		}
	}
	// Pass 2: elsewhere within the same project subtree (imported sibling module).
	sr := scope_root.replace('\\', '/').trim_right('/')
	if sr == '' {
		return ''
	}
	for uri in uris {
		p := uri_to_path(uri).replace('\\', '/')
		if !path_is_within(p, sr) || os.dir(p).trim_right('/') == cd {
			continue
		}
		entry := app.symbol_index[uri] or { continue }
		if doc := entry.docs[name] {
			if doc != '' {
				return doc
			}
		}
	}
	return ''
}

// uri_within_any reports whether `uri`'s path lies within any of `dirs`.
fn uri_within_any(uri string, dirs []string) bool {
	p := uri_to_path(uri).replace('\\', '/')
	for d in dirs {
		if path_is_within(p, d.replace('\\', '/')) {
			return true
		}
	}
	return false
}

// find_indexed_fn returns the (uri, symbol) of the first indexed function or
// method whose simple name matches `name`. `_test.v` declarations are skipped
// unless `include_tests` is set, so call hierarchy from production code never
// resolves into a same-named test helper just because of URI ordering; a query
// originating in a test file passes include_tests so its own helpers resolve.
// When `dirs` is non-empty the search is confined to files within those
// directories, so a same-named function in an unrelated indexed root is not
// returned (P1-04) — the global index can span multiple workspace roots.
fn (app &App) find_indexed_fn(name string, include_tests bool, dirs []string) ?(string, DocumentSymbol) {
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		if !include_tests && uri.ends_with('_test.v') {
			continue
		}
		if dirs.len > 0 && !uri_within_any(uri, dirs) {
			continue
		}
		entry := app.symbol_index[uri] or { continue }
		for sym in entry.doc_symbols {
			if sym.kind != sym_kind_function && sym.kind != sym_kind_method {
				continue
			}
			if extract_simple_fn_name(sym.name) == name {
				return uri, sym
			}
		}
	}
	return none
}
