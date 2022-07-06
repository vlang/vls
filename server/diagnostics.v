module server

import lsp
import term
import analyzer { ReporterPreferences, Report, ReportKind }
import os

struct DiagnosticReporter {
mut:
	prefs           ReporterPreferences
	version         int
	reports         map[string][]lsp.Diagnostic = map[string][]lsp.Diagnostic{}
}

fn (r &DiagnosticReporter) count() int {
	mut count := 0
	for _, reports in r.reports {
		count += reports.len
	}
	return count
}

fn (mut r DiagnosticReporter) clear_from_range(uri lsp.DocumentUri, start_line u32, end_line u32) {
	if uri !in r.reports || r.reports[uri].len == 0 {
		return
	}

	for i := 0; i < r.reports[uri].len; {
		report := r.reports[uri][i]
		if report.range.start.line >= start_line && report.range.start.line <= end_line {
			if report.range.end.line >= start_line && report.range.end.line <= end_line {
				r.reports[uri].delete(i)
				continue
			}
		}
		i++
	}
}

fn (mut r DiagnosticReporter) clear(uri lsp.DocumentUri) {
	if uri !in r.reports {
		return
	}

	r.reports[uri].clear()
}

fn (mut r DiagnosticReporter) report(report Report) {
	kind := match report.kind {
		.error { lsp.DiagnosticSeverity.error }
		.warning { lsp.DiagnosticSeverity.warning }
		.notice { lsp.DiagnosticSeverity.information }
	}

	file_uri := lsp.document_uri_from_path(report.file_path)
	if file_uri !in r.reports {
		r.reports[file_uri] = []lsp.Diagnostic{cap: 255}
	}

	r.reports[file_uri] << lsp.Diagnostic{
		range: tsrange_to_lsp_range(report.range)
		severity: kind
		message: report.message
	}
}

const empty_diagnostic = []lsp.Diagnostic{}

fn (mut r DiagnosticReporter) publish(mut wr ResponseWriter, uri lsp.DocumentUri) {
	wr.publish_diagnostics(uri: uri, diagnostics: empty_diagnostic)
	if uri !in r.reports {
		return
	}
	wr.publish_diagnostics(uri: uri, diagnostics: r.reports[uri])
}

fn parse_v_diagnostic(msg string) ?Report {
	if msg.len < 4 || msg[0].is_space() {
		return none
	}

	line_colon_idx := msg.index_after(':', 2) // deal with `d:/v/...:2:4: error: ...`
	if line_colon_idx < 0 {
		return none
	}
	file_path := msg[..line_colon_idx]
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
		'error' { ReportKind.error }
		'warning' { ReportKind.warning }
		'notice' { ReportKind.notice }
		else { ReportKind.notice }
	}

	point := C.TSPoint{
		row: u32(line_nr)
		column: u32(col_nr)
	}
	return Report{
		range: C.TSRange{
			start_point: point
			end_point: point
		}
		kind: diag_kind
		message: msg_content
		file_path: file_path
	}
}

// exec_v_diagnostics returns a list of errors/warnings taken from `v -check`
fn (mut ls Vls) exec_v_diagnostics(uri lsp.DocumentUri) ?int {
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
	p.run()
	if p.code == 0 {
		return none
	}

	err := p.stderr_slurp().split_into_lines().map(term.strip_ansi(it))
	mut count := 0
	for line in err {
		mut report := parse_v_diagnostic(line) or { continue }
		if start_idx := dir_path.index(os.dir(report.file_path)) {
			report = Report{
				...report
				file_path: dir_path[..start_idx] + report.file_path
			}
		}

		if file := ls.files[report.file_path] {
			root_node := file.tree.root_node()
			node_point := report.range.start_point
			if target_node := root_node.descendant_for_point_range(node_point, node_point) {
				report = Report{
					...report
					range: target_node.range()
				}
			}
		}
		ls.reporter.report(report)
		count++
	}
	return count
}

// publish_diagnostics sends errors, warnings and other diagnostics to the editor
fn (mut wr ResponseWriter) publish_diagnostics(params lsp.PublishDiagnosticsParams) {
	wr.write_notify('textDocument/publishDiagnostics', params)
}