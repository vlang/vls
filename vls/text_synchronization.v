module vls

import json
import lsp
import os
import analyzer

const (
	vroot         = os.dir(@VEXE)
	vlib_path     = os.join_path(vroot, 'vlib')
	vmodules_path = os.join_path(os.home_dir(), '.vmodules')
	builtin_path  = os.join_path(vlib_path, 'builtin')
)

fn analyze(mut store analyzer.Store, uri lsp.DocumentUri, root_uri lsp.DocumentUri, tree &C.TSTree, src []byte) {
	file_path := uri.path()
	dir := uri.dir_path()

	// TODO: use LSP's file versioning to avoid redeleting existing symbols
	for i, _ in store.symbols[dir] {
		if store.symbols[dir][i].file_path == file_path {
			unsafe { store.symbols[dir][i].free() }
			store.symbols[dir].delete(i)
		}
	}

	store.set_active_file_path(uri.path())
	store.import_modules_from_tree(tree, src,
		os.join_path(uri.dir_path(), 'modules'),
		root_uri.path()
	)

	store.register_symbols_from_tree(tree, src)
	store.cleanup_imports()
	store.analyze(tree, src)
}

fn (mut ls Vls) did_open(_ int, params string) {
	did_open_params := json.decode(lsp.DidOpenTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}

	src := did_open_params.text_document.text
	uri := did_open_params.text_document.uri

	new_src := src.bytes()
	new_tree := ls.parser.parse_string(src)

	analyze(mut ls.store, uri, ls.root_uri, new_tree, new_src)
	ls.show_diagnostics(uri)

	ls.sources[uri] = new_src
	ls.trees[uri] = new_tree
}

[manualfree]
fn (mut ls Vls) did_change(_ int, params string) {
	did_change_params := json.decode(lsp.DidChangeTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}

	uri := did_change_params.text_document.uri
	mut new_src := ls.sources[uri].clone()
	ls.publish_diagnostics(uri, []lsp.Diagnostic{})

	for content_change in did_change_params.content_changes {
		start_idx := compute_offset(new_src, content_change.range.start.line, content_change.range.start.character)
		old_end_idx := compute_offset(new_src, content_change.range.end.line, content_change.range.end.character)
		new_end_idx := start_idx + content_change.text.len
		start_pos := content_change.range.start
		old_end_pos := content_change.range.end
		new_end_pos := compute_position(new_src, new_end_idx)

		old_len := new_src.len
		new_len := old_len - (old_end_idx - start_idx) + content_change.text.len
		diff := new_len - old_len
		old_src := new_src.clone()
		// the new source should grow or shrink
		unsafe { new_src.grow_len(diff) }

		// This part should move all the characters to their new positions
		// TODO: improve the algo when possible, rename variables, merge two branches into one
		if new_len > old_len {
			mut j := 0
			mut k := old_end_idx
			for i := new_end_idx; j < old_len - old_end_idx; i++ {
				// TODO: not sure if its required
				if k == old_len {
					break
				}

				new_src[i] = old_src[k]
				j++
				k++
			}
		} else {
			mut j := new_end_idx
			for i := old_end_idx; i < old_src.len; i++ {
				// all the characters on the right side of the old index
				// will be transferred to the new index
				new_src[j] = old_src[i]
				j++
			}
		}
		unsafe { old_src.free() }

		// add the remaining characters to the remaining items
		if content_change.text.len > 0 {
			mut j := 0
			for i := start_idx; i < new_src.len; i++ {
				if j == content_change.text.len {
					break
				}

				new_src[i] = content_change.text[j]
				j++
			}
		}
		
		// edit the tree
		ls.trees[uri].edit({
			start_byte: u32(start_idx)
			old_end_byte: u32(old_end_idx)
			new_end_byte: u32(new_end_idx)
			start_point: C.TSPoint{u32(start_pos.line), u32(start_pos.character)}
			old_end_point: C.TSPoint{u32(old_end_pos.line), u32(old_end_pos.character)}
			new_end_point: C.TSPoint{u32(new_end_pos.line), u32(new_end_pos.character)}
		})

		unsafe { content_change.text.free() }
	}

	new_tree := ls.parser.parse_string_with_old_tree(new_src.bytestr(), ls.trees[uri])
	// ls.log_message('new tree: ${new_tree.root_node().sexpr_str()}', .info)

	ls.store.clear_messages()

	// TODO: incremental approach to analyzing (analyze only the parts that changed)
	// using `ts_tree_get_changed_ranges`. Sadly, it hangs at this moment.
	analyze(mut ls.store, uri, ls.root_uri, new_tree, new_src)

	unsafe { 
		ls.trees[uri].free()
		ls.sources[uri].free()
	}

	ls.trees[uri] = new_tree
	ls.sources[uri] = new_src

	ls.show_diagnostics(uri)

	// $if !test {
	// 	ls.log_message(ls.store.imports.str(), .info)
	// 	ls.log_message(ls.store.dependency_tree.str(), .info)
	// }
}

[manualfree]
fn (mut ls Vls) did_close(_ int, params string) {
	did_close_params := json.decode(lsp.DidCloseTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}

	uri := did_close_params.text_document.uri
	unsafe {
		ls.sources[uri].free()
		ls.trees[uri].free()
	}

	ls.store.delete(uri.dir_path())

	// unsafe { ls.store.opened_scopes[uri.path()].free() }
	ls.store.opened_scopes.delete(uri.path())

	// NB: The diagnostics will be cleared if:
	// - TODO: If a workspace has opened multiple programs with main() function and one of them is closed.
	// - If a file opened is outside the root path or workspace.
	// - If there are no remaining files opened on a specific folder.
	if ls.sources.len == 0 || !uri.starts_with(ls.root_uri) {
		ls.publish_diagnostics(uri, []lsp.Diagnostic{})
	}
}