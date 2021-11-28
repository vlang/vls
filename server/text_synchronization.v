module server

import json
import lsp
import os
import analyzer

fn (mut ls Vls) analyze_file(tree &C.TSTree, file File) {
	ls.store.clear_messages()
	file_path := file.uri.path()
	ls.store.set_active_file_path(file_path, file.version)
	ls.store.import_modules_from_tree(tree, file.source, os.join_path(file.uri.dir_path(),
		'modules'), ls.root_uri.path(), os.dir(os.dir(file_path)))

	ls.store.register_symbols_from_tree(tree, file.source, false)
	ls.store.cleanup_imports()
	if Feature.analyzer_diagnostics in ls.enabled_features {
		ls.store.analyze(tree, file.source)
	}
}

fn (mut ls Vls) did_open(_ string, params string) {
	did_open_params := json.decode(lsp.DidOpenTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}
	ls.parser.reset()
	src := did_open_params.text_document.text
	uri := did_open_params.text_document.uri
	// ls.log_message('opening $uri ...', .info)
	// if project is not opened, analyze all the files available
	project_dir := uri.dir_path()
	if uri.ends_with('.v') && project_dir != '.' && !ls.store.dependency_tree.has(project_dir) {
		mut files := os.ls(project_dir) or { [] }
		for file_name in files {
			if !analyzer.should_analyze_file(file_name) {
				continue
			}

			full_path := os.join_path(project_dir, file_name)
			file_uri := lsp.document_uri_from_path(full_path)

			if file_uri != uri {
				ls.sources[file_uri] = File{
					uri: file_uri
					source: os.read_bytes(full_path) or { [] }
				}
				source_str := ls.sources[file_uri].source.bytestr()
				ls.trees[file_uri] = ls.parser.parse_string(source_str)
				unsafe { source_str.free() }
			} else {
				ls.sources[uri] = File{
					source: src.bytes()
					uri: uri
				}
				ls.trees[uri] = ls.parser.parse_string(src)
			}

			// V's interop with tree sitter's parse_string is buggy sometimes
			// especially if the code is incomplete. It reattempts to re-parse
			// an appropriate tree by reducing decrement the source length by 1
			if !isnil(ls.trees[file_uri]) && ls.trees[file_uri].root_node().type_name() == 'ERROR' {
				unsafe { ls.trees[file_uri].free() }
				ls.trees[file_uri] = ls.parser.parse_string_with_old_tree_and_len(src,
					&C.TSTree(0), u32(src.len - 1))
			}

			ls.analyze_file(ls.trees[file_uri], ls.sources[file_uri])
			ls.show_diagnostics(file_uri)

			// unsafe {
			// 	full_path.free()
			// 	file_uri.free()
			// }
		}
		ls.store.set_active_file_path(uri.path(), ls.sources[uri].version)
		unsafe { files.free() }
	} else if uri !in ls.sources && uri !in ls.trees {
		ls.sources[uri] = File{
			source: src.bytes()
			uri: uri
		}
		ls.trees[uri] = ls.parser.parse_string(src)

		if !ls.store.has_file_path(uri.path()) || uri.path() !in ls.store.opened_scopes {
			ls.analyze_file(ls.trees[uri], ls.sources[uri])
		}

		ls.show_diagnostics(uri)
	}

	if v_check_results := ls.exec_v_diagnostics(uri) {
		ls.publish_diagnostics(uri, v_check_results)
	}
}

[manualfree]
fn (mut ls Vls) did_change(_ string, params string) {
	did_change_params := json.decode(lsp.DidChangeTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}

	uri := did_change_params.text_document.uri
	if !ls.store.is_file_active(uri.path()) {
		ls.parser.reset()
	}

	ls.store.set_active_file_path(uri.path(), did_change_params.text_document.version)

	mut new_src := ls.sources[uri].source
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
		right_text := new_src[old_end_idx ..].clone()

		// remove immediately the symbol
		if content_change.text.len == 0 && diff < 0 {
			ls.store.delete_symbol_at_node(ls.trees[uri].root_node(), new_src,
				start_point: lsp_pos_to_tspoint(start_pos)
				end_point: lsp_pos_to_tspoint(old_end_pos)
				start_byte: u32(start_idx)
				end_byte: u32(old_end_idx)
			)
		}

		// the new source should grow or shrink
		unsafe { new_src.grow_len(diff) }

		// copy(new_src[new_end_idx ..], old_src[old_end_idx ..])
		mut new_idx, mut right_idx := new_end_idx, 0
		for new_idx < new_src.len && right_idx < right_text.len {
			new_src[new_idx] = right_text[right_idx]
			new_idx++
			right_idx++
		}

		// add the remaining characters to the remaining items
		mut insert_idx, mut change_idx := start_idx, 0
		for insert_idx < new_src.len && change_idx < content_change.text.len {
			new_src[insert_idx] = content_change.text[change_idx]
			change_idx++
			insert_idx++
		}

		// edit the tree
		ls.trees[uri].edit(
			start_byte: u32(start_idx)
			old_end_byte: u32(old_end_idx)
			new_end_byte: u32(new_end_idx)
			start_point: lsp_pos_to_tspoint(start_pos)
			old_end_point: lsp_pos_to_tspoint(old_end_pos)
			new_end_point: lsp_pos_to_tspoint(new_end_pos)
		)
	}

	// See comment in `did_open`.
	mut new_tree := ls.parser.parse_string_with_old_tree(new_src.bytestr(), ls.trees[uri])
	if !isnil(new_tree) && new_tree.root_node().type_name() == 'ERROR' {
		unsafe { new_tree.free() }
		new_tree = ls.parser.parse_string_with_old_tree_and_len(new_src.bytestr(), ls.trees[uri],
			u32(new_src.len - 1))
	}

	// ls.log_message('new tree: ${new_tree.root_node().sexpr_str()}', .info)
	ls.trees[uri] = new_tree
	ls.sources[uri].source = new_src
	ls.sources[uri].version = did_change_params.text_document.version

	// $if !test {
	// 	ls.log_message(ls.store.imports.str(), .info)
	// 	ls.log_message(ls.store.dependency_tree.str(), .info)
	// }
}

[manualfree]
fn (mut ls Vls) did_close(_ string, params string) {
	did_close_params := json.decode(lsp.DidCloseTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}

	uri := did_close_params.text_document.uri
	// unsafe {
	// 	ls.sources[uri].free()
	// 	ls.trees[uri].free()
	// 	ls.store.opened_scopes[uri.path()].free()
	// }
	ls.sources.delete(uri)
	ls.trees.delete(uri)
	ls.store.opened_scopes.delete(uri.path())

	if ls.sources.count(uri.dir()) == 0 {
		ls.store.delete(uri.dir_path())
	}

	// NB: The diagnostics will be cleared if:
	// - TODO: If a workspace has opened multiple programs with main() function and one of them is closed.
	// - If a file opened is outside the root path or workspace.
	// - If there are no remaining files opened on a specific folder.
	if ls.sources.len == 0 || !uri.starts_with(ls.root_uri) {
		ls.publish_diagnostics(uri, []lsp.Diagnostic{})
	}
}

fn (mut ls Vls) did_save(id string, params string) {
	did_save_params := json.decode(lsp.DidSaveTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}
	uri := did_save_params.text_document.uri
	if v_check_results := ls.exec_v_diagnostics(uri) {
		ls.publish_diagnostics(uri, v_check_results)
	}
}
