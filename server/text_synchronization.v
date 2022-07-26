module server

import lsp
import os
import analyzer
import structures.ropes
import tree_sitter_v as v

fn (mut ls Vls) analyze_file(file File, affected_node_type v.NodeType, affected_line u32) {
	if Feature.v_diagnostics in ls.enabled_features {
		ls.reporter.clear(file.uri)
	}

	is_import := affected_node_type == .import_declaration
	file_path := file.uri.path()
	ls.store.set_active_file_path(file_path, file.version)

	// skip analyzing imports when affected is not an import declaration
	if is_import || affected_line == 0 {
		ls.store.import_modules_from_tree(file.tree, file.source, os.join_path(file.uri.dir_path(),
			'modules'), ls.root_uri.path(), os.dir(os.dir(file_path)))

		ls.store.cleanup_imports()
	}

	ls.store.register_symbols_from_tree(file.tree, file.source, false, start_line_nr: affected_line)
	if !is_import && Feature.analyzer_diagnostics in ls.enabled_features {
		ls.store.analyze(file.tree, file.source, start_line_nr: affected_line)
	}

	ls.reporter.publish(mut ls.writer, file.uri)
}

pub fn (mut ls Vls) did_open(params lsp.DidOpenTextDocumentParams, mut wr ResponseWriter) {
	ls.parser.reset()
	src := params.text_document.text
	uri := params.text_document.uri
	project_dir := uri.dir_path()
	mut should_scan_whole_dir := false

	// should_scan_whole_dir is toggled if
	// - it's V file ending with .v format
	// - the project directory does not end with a dot (.)
	// - and has not been present in the dependency tree
	if uri.ends_with('.v') && project_dir != '.' && !ls.store.dependency_tree.has(project_dir) {
		should_scan_whole_dir = true
	}

	mut files_to_analyze := if should_scan_whole_dir { os.ls(project_dir) or {
			[
				uri.path(),
			]} } else { [
			uri.path(),
		] }

	for file_name in files_to_analyze {
		if should_scan_whole_dir && !analyzer.should_analyze_file(file_name) {
			continue
		}

		file_path := if file_name.starts_with(project_dir) {
			file_name
		} else {
			os.join_path(project_dir, file_name)
		}
		file_uri := lsp.document_uri_from_path(file_path)

		mut has_file := file_uri in ls.files
		mut should_be_analyzed := has_file

		// Create file only if source does not exist
		if !has_file {
			source_str := if file_uri != uri { os.read_file(file_path) or { '' } } else { src }
			ls.files[file_uri] = File{
				uri: file_uri
				source: ropes.new(source_str)
				tree: ls.parser.parse_string(source: source_str)
				version: 1
			}

			has_file = true
		}

		// If data about the document/file has recently been created,
		// mark it as "should_be_analyzed" (hence the variable name).
		if !should_be_analyzed && has_file {
			should_be_analyzed = true
		}

		// Analyze only if both source and tree exists
		if should_be_analyzed {
			ls.analyze_file(ls.files[file_uri], .unknown, 0)
		}

		// wr.log_message('$file_uri | has_file: $has_file | should_be_analyzed: $should_be_analyzed',
		// 	.info)
	}

	ls.store.set_active_file_path(uri.path(), ls.files[uri].version)
	ls.exec_v_diagnostics(uri) or {}
	ls.reporter.publish(mut wr, uri)
}

pub fn (mut ls Vls) did_change(params lsp.DidChangeTextDocumentParams, mut wr ResponseWriter) {
	uri := params.text_document.uri
	if !ls.store.is_file_active(uri.path()) {
		ls.parser.reset()
	}

	ls.store.set_active_file_path(uri.path(), params.text_document.version)

	ls.store.delete_symbol_at_node(
		ls.files[uri].tree.root_node(), 
		ls.files[uri].source,
		u32(params.content_changes.first().range.start.line), 
		u32(params.content_changes.last().range.start.line)
	)

	mut new_src := ls.files[uri].source
	mut new_tree := ls.files[uri].tree.raw_tree.copy()
	mut first_affected_start_offset := u32(0)

	for change_i, content_change in params.content_changes {
		change_text := content_change.text
		start_idx := compute_offset(new_src, content_change.range.start.line, content_change.range.start.character)
		old_end_idx := compute_offset(new_src, content_change.range.end.line, content_change.range.end.character)
		new_end_idx := start_idx + change_text.len
		start_pos := content_change.range.start
		old_end_pos := content_change.range.end
		new_end_pos := compute_position(new_src, new_end_idx)

		if change_i == 0 {
			first_affected_start_offset = u32(start_idx)
		}

		// NOTES ON REMOVING TEXT:
		// remove the specific portion of a document's source text if:
		// - there's no text to be added (remove/delete only)
		// - a specific portion of the text is replaced with another text
		//   regardless of the length (e.g. completion, formatting)
		// 
		// NOTES ON INSERTING TEXT:
		// insert only on the starting index if the to-be-inserted text
		// has content.
		new_src = new_src.delete(start_idx, old_end_idx - start_idx).insert(start_idx, change_text)

		// edit the tree
		new_tree.edit(
			start_byte: u32(start_idx)
			old_end_byte: u32(old_end_idx)
			new_end_byte: u32(new_end_idx)
			start_point: lsp_pos_to_tspoint(start_pos)
			old_end_point: lsp_pos_to_tspoint(old_end_pos)
			new_end_point: lsp_pos_to_tspoint(new_end_pos)
		)
	}

	new_src = new_src.rebalance_if_needed()
	// wr.log_message('${ls.files[uri].tree.get_changed_ranges(new_tree)}', .info)

	// wr.log_message('new tree: ${new_tree.root_node().sexpr_str()}', .info)
	ls.files[uri].tree = ls.parser.parse_string(source: new_src.string(), tree: new_tree)
	ls.files[uri].source = new_src
	ls.files[uri].version = params.text_document.version

	// record last first content change line for partial analysis
	if first_affected_direct_node := ls.files[uri].tree.root_node().first_named_child_for_byte(first_affected_start_offset) {
		ls.last_modified_line = first_affected_direct_node.raw_node.start_point().row
		ls.last_affected_node = first_affected_direct_node.type_name
	} else {
		ls.last_modified_line = u32(params.content_changes[0].range.start.line)
		ls.last_affected_node = .unknown
	}

	if Feature.v_diagnostics !in ls.enabled_features {
		ls.reporter.clear_from_range(
			uri, 
			u32(params.content_changes.first().range.start.line), 
			u32(params.content_changes.last().range.start.line)
		)
	}

	// $if !test {
	// 	wr.log_message(ls.store.imports.str(), .info)
	// 	wr.log_message(ls.store.dependency_tree.str(), .info)
	// }
}

pub fn (mut ls Vls) did_close(params lsp.DidCloseTextDocumentParams, mut wr ResponseWriter) {
	uri := params.text_document.uri
	ls.files.delete(uri)
	ls.store.opened_scopes.delete(uri.path())

	if ls.files.count(uri.dir()) == 0 {
		ls.store.delete(uri.dir_path())
	}

	// NB: The diagnostics will be cleared if:
	// - TODO: If a workspace has opened multiple programs with main() function and one of them is closed.
	// - If a file opened is outside the root path or workspace.
	// - If there are no remaining files opened on a specific folder.
	if ls.files.len == 0 || !uri.starts_with(ls.root_uri) {
		wr.publish_diagnostics(uri: uri, diagnostics: empty_diagnostic)
		ls.reporter.clear(uri)
	}
}

pub fn (mut ls Vls) did_save(params lsp.DidSaveTextDocumentParams, mut wr ResponseWriter) {
	uri := params.text_document.uri
	ls.reporter.clear(uri)
	ls.exec_v_diagnostics(uri) or {}
	ls.reporter.publish(mut wr, uri)
}

pub fn (mut ls Vls) will_save(params lsp.WillSaveTextDocumentParams, mut wr ResponseWriter) {}