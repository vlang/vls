// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os

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
	fingerprint int // content.hash(); used to skip re-parsing unchanged files
	module_name string
	doc_symbols []DocumentSymbol  // hierarchical symbols (as parse_document_symbols returns)
	docs        map[string]string // simple symbol name -> leading vdoc comment
}

// build_index_entry parses `content` into an IndexEntry.
fn build_index_entry(content string) IndexEntry {
	lines := content.split_into_lines()
	doc_syms := parse_document_symbols(content)
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
		fingerprint: content.hash()
		module_name: get_module_name(content)
		doc_symbols: doc_syms
		docs:        docs
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
	app.symbol_index[uri] = build_index_entry(content)
}

// invalidate_index_uri drops a URI's entry so it is re-parsed on next access.
fn (mut app App) invalidate_index_uri(uri string) {
	app.symbol_index.delete(uri)
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
	if acc.len >= index_max_files {
		return
	}
	entries := os.ls(root) or { return }
	for entry in entries {
		if acc.len >= index_max_files {
			return
		}
		full := os.join_path(root, entry)
		if os.is_dir(full) {
			if entry.starts_with('.') || entry in index_excluded_dirs {
				continue
			}
			collect_v_files(full, mut acc)
		} else if entry.ends_with('.v') {
			acc << full
		}
	}
}

// ensure_dirs_indexed makes sure every open buffer and every `.v` file under the
// given project `dirs` has an up-to-date index entry. Each dir is walked at most
// once (tracked in indexed_dirs); already-indexed files are skipped, so only new
// or changed files are read and parsed rather than the whole workspace.
fn (mut app App) ensure_dirs_indexed(dirs []string) {
	// Open buffers are authoritative; keep their entries fresh (cheap fingerprint
	// check skips unchanged content).
	for uri, _ in app.open_files {
		app.reindex_uri(uri)
	}
	for dir in dirs {
		if dir == '' || dir == '/' || dir in app.indexed_dirs || !os.is_dir(dir) {
			continue
		}
		mut files := []string{}
		collect_v_files(dir, mut files)
		for f in files {
			uri := path_to_uri(f)
			if uri in app.open_files || uri in app.symbol_index {
				continue
			}
			if os.file_size(f) > index_max_file_bytes {
				continue
			}
			content := os.read_file(f) or { continue }
			app.symbol_index[uri] = build_index_entry(content)
		}
		app.indexed_dirs[dir] = true
	}
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
