// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
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
	fingerprint    int // content.hash(); used to skip re-parsing unchanged files
	module_name    string
	doc_symbols    []DocumentSymbol  // hierarchical symbols (as parse_document_symbols returns)
	docs           map[string]string // simple symbol name -> leading vdoc comment
	fn_completions []Detail          // free-function completion items for this file
}

// build_index_entry parses `content` into an IndexEntry. Symbol ranges are
// re-encoded into `enc` so document/workspace symbol positions match the
// negotiated encoding for non-ASCII lines (P0-01).
fn build_index_entry(content string, enc PositionEncoding) IndexEntry {
	lines := content.split_into_lines()
	doc_syms := encode_document_symbols(parse_document_symbols(content), lines, enc)
	mut docs := map[string]string{}
	for sym in doc_syms {
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
		fingerprint:    content.hash()
		module_name:    get_module_name(content)
		doc_symbols:    doc_syms
		docs:           docs
		fn_completions: parse_module_fn_completions(content)
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

// scan_string_identifier_occurrences skips literal text while indexing V string
// interpolation expressions. It returns the byte after the closing quote.
fn scan_string_identifier_occurrences(line_text string, line_idx int, start int, enc PositionEncoding, mut occ map[string][]TokenOccurrence) int {
	quote := line_text[start]
	mut col := start + 1
	for col < line_text.len {
		if line_text[col] == `\\` {
			col += 2
			continue
		}
		if line_text[col] == quote {
			return col + 1
		}
		if line_text[col] == `$` && col + 1 < line_text.len {
			if line_text[col + 1] == `{` {
				col =
					scan_code_identifier_occurrences(line_text, line_idx, col + 2, enc, true, mut occ)
				continue
			}
			if is_ident_char(line_text[col + 1]) && !(line_text[col + 1] >= `0`
				&& line_text[col + 1] <= `9`) {
				ident_start := col + 1
				col = ident_start + 1
				for col < line_text.len && is_ident_char(line_text[col]) {
					col++
				}
				add_identifier_occurrence(line_text, line_idx, ident_start, col, enc, mut occ)
				continue
			}
		}
		col++
	}
	return col
}

// scan_code_identifier_occurrences indexes code between `start` and the end of
// the line, or through the matching `}` for a braced interpolation expression.
fn scan_code_identifier_occurrences(line_text string, line_idx int, start int, enc PositionEncoding, stop_at_closing_brace bool, mut occ map[string][]TokenOccurrence) int {
	mut col := start
	mut brace_depth := 0
	for col < line_text.len {
		c := line_text[col]
		if col + 1 < line_text.len && c == `/` && line_text[col + 1] == `/` {
			return line_text.len
		}
		if c == `"` || c == `'` {
			col = scan_string_identifier_occurrences(line_text, line_idx, col, enc, mut occ)
			continue
		}
		if c == `{` {
			brace_depth++
			col++
			continue
		}
		if c == `}` && stop_at_closing_brace {
			if brace_depth == 0 {
				return col + 1
			}
			brace_depth--
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
// grouped by name, positioned in `enc` units. Line comments and string literal
// text are skipped, interpolation expressions are scanned, and number literals
// are ignored. This is the reference-index tokenizer: references/rename read
// candidates from here instead of re-walking and re-tokenizing files per request
// (P1-05).
fn extract_identifier_occurrences(content string, enc PositionEncoding) map[string][]TokenOccurrence {
	mut occ := map[string][]TokenOccurrence{}
	for line_idx, line_text in content.split_into_lines() {
		scan_code_identifier_occurrences(line_text, line_idx, 0, enc, false, mut occ)
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
	p := path.replace('\\', '/')
	for root in app.workspace_roots {
		if path_is_within(p, root.replace('\\', '/')) {
			return false
		}
	}
	for root in app.removed_workspace_roots {
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
const index_max_file_bytes = 2 * 1024 * 1024
const index_excluded_dirs = ['.git', '.svn', '.hg', 'node_modules', '.vmodules', 'thirdparty',
	'_build', 'build', 'target', '.cache']

// find_project_root walks up from `dir` looking for a `v.mod` file and returns
// the directory that contains it, or '' if none is found before the filesystem
// root. This models the nearest V project root (audit P1-01).
fn find_project_root(dir string) string {
	mut d := dir
	for d != '' && d != '/' {
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
	mut visited := map[string]bool{}
	canonical_root := os.real_path(root).replace('\\', '/')
	return collect_v_files_rec(root, canonical_root, mut acc, mut visited)
}

// collect_v_files_rec is the recursive worker; `visited` holds the canonical
// (realpath-resolved) directories already walked, so a symlink cycle cannot
// cause infinite recursion or double-indexing. `canonical_root` bounds the walk
// to the workspace: a directory whose resolved path escapes it (e.g. a symlink
// `external -> /home`) is skipped so an out-of-tree directory cannot pull an
// unrelated file tree into the index (P1-01).
fn collect_v_files_rec(dir string, canonical_root string, mut acc []string, mut visited map[string]bool) bool {
	if acc.len >= index_max_files {
		return false
	}
	real := os.real_path(dir)
	if real in visited {
		return true
	}
	// Containment: os.real_path resolves symlinks, so a symlinked directory whose
	// target lies outside the workspace root is rejected here rather than walked.
	if !path_is_within(real.replace('\\', '/'), canonical_root) {
		return true
	}
	visited[real] = true
	entries := os.ls(dir) or { return false }
	for entry in entries {
		if acc.len >= index_max_files {
			return false
		}
		full := os.join_path(dir, entry)
		if os.is_dir(full) {
			if entry.starts_with('.') || entry in index_excluded_dirs {
				continue
			}
			if !collect_v_files_rec(full, canonical_root, mut acc, mut visited) {
				return false
			}
		} else if entry.ends_with('.v') {
			// Directory containment is not enough: an in-tree file symlink can
			// point outside the workspace. Resolve every candidate and retain it
			// only when its canonical target remains under the canonical root.
			real_file := os.real_path(full).replace('\\', '/')
			if path_is_within(real_file, canonical_root) {
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

// ensure_index_scope indexes only the project/module relevant to a request.
fn (mut app App) ensure_index_scope(scope IndexScope) {
	if scope.dir == '' || scope.dir == '/' {
		return
	}
	if scope.recursive {
		app.ensure_dirs_indexed([scope.dir])
		return
	}
	for uri, _ in app.open_files {
		if uri_is_in_index_scope(uri, scope) {
			app.reindex_uri(uri)
		}
	}
	app.ensure_dir_shallow_indexed(scope.dir)
}

// index_is_complete_for_scope reports whether every source relevant to a
// destructive operation in `scope` was indexed.
fn (app &App) index_is_complete_for_scope(scope IndexScope) bool {
	if scope.dir == '' {
		return false
	}
	scope_kind := if scope.recursive { 'recursive' } else { 'shallow' }
	if '${scope_kind}:${scope.dir}' in app.index_incomplete_scopes {
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

// query_workspace_symbols returns all indexed symbols whose name contains
// `query` (case-insensitive; empty matches all), including struct fields and
// enum members as `Parent.child`. The index must already be populated.
fn (app &App) query_workspace_symbols(query string) []WorkspaceSymbol {
	q := query.to_lower()
	mut results := []WorkspaceSymbol{}
	mut seen := map[string]bool{}
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		entry := app.symbol_index[uri] or { continue }
		for sym in entry.doc_symbols {
			if q == '' || sym.name.to_lower().contains(q) {
				add_workspace_symbol(mut results, mut seen, sym.name, sym.kind, uri,
					sym.selection_range)
			}
			for child in sym.children {
				if q == '' || child.name.to_lower().contains(q) {
					add_workspace_symbol(mut results, mut seen, '${sym.name}.${child.name}',
						child.kind, uri, child.selection_range)
				}
			}
		}
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
