module server

import jsonrpc
import lsp
import term

fn (ls Vls) v_msg_to_diagnostic(from_file_path string, msg string) ?lsp.Diagnostic {
	if msg.len < 4 || msg[0].is_space() {
		return none
	}

	line_colon_idx := msg.index_after(':', 2) // deal with `d:/v/...:2:4: error: ...`
	if line_colon_idx < 0 {
		return none
	}
	file_path := msg[..line_colon_idx]
	if !from_file_path.ends_with(file_path) {
		return error('$file_path != $from_file_path')
	}

	col_colon_idx := msg.index_after(':', line_colon_idx + 1)
	colon_sep_idx := msg.index_after(':', col_colon_idx + 1)
	msg_type_colon_idx := msg.index_after(':', colon_sep_idx + 1)
	if msg_type_colon_idx == -1 || col_colon_idx == -1 || colon_sep_idx == -1 {
		return error('idx is -1')
	}

	line_nr := msg[line_colon_idx + 1..col_colon_idx].int() - 1
	col_nr := msg[col_colon_idx + 1..colon_sep_idx].int() - 1
	msg_type := msg[colon_sep_idx + 1..msg_type_colon_idx].trim_space()
	msg_content := msg[msg_type_colon_idx + 1..].trim_space()

	diag_kind := match msg_type {
		'error' { lsp.DiagnosticSeverity.error }
		'warning' { lsp.DiagnosticSeverity.warning }
		'notice' { lsp.DiagnosticSeverity.information }
		else { lsp.DiagnosticSeverity.warning }
	}

	mut target_range := lsp.Range{
		start: lsp.Position{line_nr, col_nr}
		end: lsp.Position{line_nr, col_nr}
	}

	if file := ls.files[from_file_path] {
		root_node := file.tree.root_node()
		node_point := C.TSPoint{u32(line_nr), u32(col_nr)}
		if target_node := root_node.descendant_for_point_range(node_point, node_point) {
			target_range = tsrange_to_lsp_range(target_node.range())
		}
	}

	return lsp.Diagnostic{
		range: target_range
		severity: diag_kind
		message: msg_content
	}
}

// exec_v_diagnostics returns a list of errors/warnings taken from `v -check`
fn (mut ls Vls) exec_v_diagnostics(uri lsp.DocumentUri) ?[]lsp.Diagnostic {
	if Feature.v_diagnostics !in ls.enabled_features {
		return none
	}

	dir_path := uri.dir_path()
	file_path := uri.path()
	input_path := if file_path.ends_with('.vv') { file_path } else { dir_path }
	mut p := ls.launch_v_tool('-enable-globals', '-shared', '-check', input_path)
	defer {
		p.close()
	}
	p.wait()
	if p.code == 0 {
		return none
	}

	err := p.stderr_slurp().split_into_lines().map(term.strip_ansi(it))
	mut res := []lsp.Diagnostic{cap: err.len}

	for line in err {
		res << ls.v_msg_to_diagnostic(file_path, line) or { continue }
	}

	return res
}

// show_diagnostics converts the file ast's errors and warnings and publishes them to the editor
fn (mut ls Vls) show_diagnostics(uri lsp.DocumentUri) {
	// TODO: make reports as a map, do not clear it
	// use
	mut diagnostics := []lsp.Diagnostic{}
	fs_path := uri.path()

	for msg in ls.store.messages {
		if msg.file_path != fs_path {
			continue
		}

		kind := match msg.kind {
			.error { lsp.DiagnosticSeverity.error }
			.warning { lsp.DiagnosticSeverity.warning }
			.notice { lsp.DiagnosticSeverity.information }
		}

		diagnostics << lsp.Diagnostic{
			range: tsrange_to_lsp_range(msg.range)
			severity: kind
			message: msg.content
		}
	}

	ls.publish_diagnostics(uri, diagnostics)
}

// publish_diagnostics sends errors, warnings and other diagnostics to the editor
fn (mut ls Vls) publish_diagnostics(uri lsp.DocumentUri, diagnostics []lsp.Diagnostic) {
	if Feature.diagnostics !in ls.enabled_features {
		return
	}

	ls.notify(jsonrpc.NotificationMessage<lsp.PublishDiagnosticsParams>{
		method: 'textDocument/publishDiagnostics'
		params: lsp.PublishDiagnosticsParams{
			uri: uri
			diagnostics: diagnostics
		}
	})
}
