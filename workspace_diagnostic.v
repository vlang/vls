// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2

// handle_workspace_diagnostic answers workspace/diagnostic (LSP 3.17): one
// report per document the server has diagnostics for, from the same cache the
// per-file pull reads. No compiler runs, no check is waited for, and the
// dedup and cap are the push's own, so a workspace report cannot disagree with
// what a per-file pull of the same document returns.
fn (mut app App) handle_workspace_diagnostic(request Request) Response {
	params := json2.decode[WorkspaceDiagnosticParams](request.params) or {
		$if debug {
			log('Failed to decode WorkspaceDiagnosticParams: ${err}')
		}
		return Response{
			id:     request.id
			result: []WorkspaceDiagnosticReport{}
		}
	}
	uris := app.uris_with_diagnostics()
	// The wire shape is an array; the lookup below stays a map.
	mut previous_ids := map[string]string{}
	for held in params.previous_result_ids {
		previous_ids[held.uri] = held.value
	}
	mut reports, dropped := app.workspace_diagnostic_reports(uris, previous_ids)
	if dropped > 0 {
		// The truncation is a report of its own rather than a silent gap: a
		// client that sees it knows the pane is partial.
		reports << WorkspaceDocumentReport{
			uri:   workspace_diagnostic_truncated_uri
			items: [
				LSPDiagnostic{
					range:    LSPRange{
						start: Position{
							line: 0
							char: 0
						}
						end:   Position{
							line: 0
							char: 0
						}
					}
					message:  'the workspace report is truncated: ${dropped} documents with diagnostics were not reported'
					severity: 3
				},
			]
		}
	}
	return Response{
		id:     request.id
		result: reports
	}
}

// workspace_diagnostic_truncated_uri is the identifier the truncation report
// carries. It is not a file, so no client resolves it to a buffer.
const workspace_diagnostic_truncated_uri = 'vls.workspace.diagnosticTruncated'

// workspace_diagnostic_max_documents bounds how many documents one workspace
// report describes. A Problems pane that asked for everything gets a bounded
// answer and a report saying so, rather than a payload that grows with the
// project.
const workspace_diagnostic_max_documents = 500

// uris_with_diagnostics lists the documents a check has answered for. A file
// checked and found clean is left out: a workspace report answers what the
// client asked about, and listing every clean file of a project would flood it.
// The order is the cache's own, and only the count is bounded.
fn (app &App) uris_with_diagnostics() []string {
	mut uris := []string{cap: app.diag_cache.len}
	for uri, cached in app.diag_cache {
		if cached.errors.len == 0 {
			continue
		}
		uris << uri
	}
	uris.sort()
	return uris
}

// workspace_diagnostic_reports answers one report per document, unchanged when
// the id the client holds still describes it. The second result is how many
// documents were left out by the cap.
fn (mut app App) workspace_diagnostic_reports(uris []string, previous_ids map[string]string) ([]WorkspaceDiagnosticReport, int) {
	mut limit := uris.len
	if limit > workspace_diagnostic_max_documents {
		limit = workspace_diagnostic_max_documents
	}
	mut reports := []WorkspaceDiagnosticReport{cap: limit}
	for idx, uri in uris {
		if idx >= limit {
			return reports, uris.len - idx
		}
		items := app.pull_diagnostics_items(uri)
		result_id := pull_diagnostics_result_id(uri, items)
		if previous_id := previous_ids[uri] {
			if previous_id == result_id {
				reports << WorkspaceUnchangedReport{
					uri:       uri
					result_id: result_id
				}
				continue
			}
		}
		reports << WorkspaceDocumentReport{
			uri:       uri
			version:   if uri in app.open_files_versions {
				?i64(app.open_files_versions[uri])
			} else {
				none
			}
			result_id: result_id
			items:     items
		}
	}
	return reports, 0
}
