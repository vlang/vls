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

// extract_identifier_occurrences returns every identifier occurrence in `content`
// grouped by name, positioned in `enc` units. Line comments and string literals
// are skipped (matching the reference scanner), and number literals are ignored.
// This is the reference-index tokenizer: references/rename read candidate
// occurrences from here instead of re-walking and re-tokenizing files per request
// (P1-05).
fn extract_identifier_occurrences(content string, enc PositionEncoding) map[string][]TokenOccurrence {
	mut occ := map[string][]TokenOccurrence{}
	for line_idx, line_text in content.split_into_lines() {
		n := line_text.len
		mut col := 0
		for col < n {
			c := line_text[col]
			// Skip line comments.
			if col + 1 < n && c == `/` && line_text[col + 1] == `/` {
				break
			}
			// Skip string literals.
			if c == `"` || c == `'` {
				quote := c
				col++
				for col < n {
					if line_text[col] == `\\` {
						col += 2
						continue
					}
					if line_text[col] == quote {
						col++
						break
					}
					col++
				}
				continue
			}
			if is_ident_char(c) {
				start := col
				col++
				for col < n && is_ident_char(line_text[col]) {
					col++
				}
				// Identifiers cannot start with a digit; skip number literals.
				if line_text[start] >= `0` && line_text[start] <= `9` {
					continue
				}
				name := line_text[start..col]
				occ[name] << TokenOccurrence{
					line:       line_idx
					start_char: byte_to_encoded_col(line_text, start, enc)
					end_char:   byte_to_encoded_col(line_text, col, enc)
				}
				continue
			}
			col++
		}
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

// reindex_uri (re)parses `uri` from its authoritative source, skipping work when
// the content fingerprint is unchanged. Removes the entry if the file is gone.
fn (mut app App) reindex_uri(uri string) {
	content := app.index_source_for(uri) or {
		app.symbol_index.delete(uri)
		return
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
	// Re-walk on next query (a removed folder must not be re-indexed).
	app.indexed_dirs.clear()
	app.indexed_dir_walk_ms.clear()
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
fn collect_v_files(root string, mut acc []string) {
	mut visited := map[string]bool{}
	collect_v_files_rec(root, mut acc, mut visited)
}

// collect_v_files_rec is the recursive worker; `visited` holds the canonical
// (realpath-resolved) directories already walked, so a symlink cycle cannot
// cause infinite recursion or double-indexing.
fn collect_v_files_rec(dir string, mut acc []string, mut visited map[string]bool) {
	if acc.len >= index_max_files {
		return
	}
	real := os.real_path(dir)
	if real in visited {
		return
	}
	visited[real] = true
	entries := os.ls(dir) or { return }
	for entry in entries {
		if acc.len >= index_max_files {
			return
		}
		full := os.join_path(dir, entry)
		if os.is_dir(full) {
			if entry.starts_with('.') || entry in index_excluded_dirs {
				continue
			}
			collect_v_files_rec(full, mut acc, mut visited)
		} else if entry.ends_with('.v') {
			acc << full
		}
	}
}

// index_refresh_interval_ms bounds how often a directory is re-walked when the
// client provides no file watchers. Without watcher notifications the index would
// otherwise never discover files created after the first walk, nor pick up disk
// edits to unopened files, until the server restarts.
const index_refresh_interval_ms = i64(10_000)

// index_dir_needs_refresh reports whether an already-walked `dir` should be
// re-scanned. When the client supports dynamic watched-file registration we rely
// on didChangeWatchedFiles for freshness and never re-walk; otherwise we re-walk
// on a throttled interval so a watcher-less client still sees new/changed files.
fn (app &App) index_dir_needs_refresh(dir string) bool {
	if app.supports_dynamic_watched_files_registration {
		return false
	}
	last := app.indexed_dir_walk_ms[dir] or { return true }
	return time.now().unix_milli() - last > index_refresh_interval_ms
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
	for dir in dirs {
		if dir == '' || dir == '/' || !os.is_dir(dir) {
			continue
		}
		if dir in app.indexed_dirs && !app.index_dir_needs_refresh(dir) {
			continue
		}
		mut files := []string{}
		collect_v_files(dir, mut files)
		mut present := map[string]bool{}
		for f in files {
			present[path_to_uri(f)] = true
		}
		// Reconcile the existing index against what is actually on disk: drop
		// entries for non-open files under `dir` that the walk no longer found.
		// Without client watchers there is no delete notification, so a removed
		// unopened file would otherwise linger in symbol/hover/call results.
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
		for f in files {
			uri := path_to_uri(f)
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
			if os.file_size(f) > index_max_file_bytes {
				continue
			}
			content := os.read_file(f) or { continue }
			app.symbol_index[uri] = build_index_entry(content, app.position_encoding)
		}
		app.indexed_dirs[dir] = true
		app.indexed_dir_walk_ms[dir] = time.now().unix_milli()
	}
}

// ensure_dir_shallow_indexed indexes the `.v` files directly in `dir` (no
// recursion). A V module occupies a single directory, so this is all that is
// needed for same-module lookups such as completion, and it is cheap enough to
// run on a keystroke. Already-indexed files are skipped.
fn (mut app App) ensure_dir_shallow_indexed(dir string) {
	if dir == '' || dir == '/' || !os.is_dir(dir) {
		return
	}
	for entry in os.ls(dir) or { return } {
		if !entry.ends_with('.v') {
			continue
		}
		full := os.join_path(dir, entry)
		if !os.is_file(full) {
			continue
		}
		uri := path_to_uri(full)
		if uri in app.open_files || uri in app.symbol_index {
			continue
		}
		if os.file_size(full) > index_max_file_bytes {
			continue
		}
		content := os.read_file(full) or { continue }
		app.symbol_index[uri] = build_index_entry(content, app.position_encoding)
	}
}

// query_module_fn_completions returns free-function completion items from every
// indexed file that belongs to `module_name`, excluding `exclude_uri` and test
// files. The index must already cover the relevant files.
fn (app &App) query_module_fn_completions(module_name string, exclude_uri string) []Detail {
	mut items := []Detail{}
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		if uri == exclude_uri || uri.ends_with('_test.v') {
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
		root := find_project_root(os.dir(uri_to_path(uri)))
		if root != '' && root != '/' && root !in seen {
			seen[root] = true
			dirs << root
		}
	}
	dirs.sort()
	return dirs
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

// find_indexed_doc returns the vdoc comment for the first indexed declaration
// whose simple name matches `name`, or '' when none is found.
fn (app &App) find_indexed_doc(name string) string {
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
		entry := app.symbol_index[uri] or { continue }
		if doc := entry.docs[name] {
			if doc != '' {
				return doc
			}
		}
	}
	return ''
}

// find_indexed_fn returns the (uri, symbol) of the first indexed function or
// method whose simple name matches `name`.
fn (app &App) find_indexed_fn(name string) ?(string, DocumentSymbol) {
	mut uris := app.symbol_index.keys()
	uris.sort()
	for uri in uris {
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
