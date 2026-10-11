// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import json2
import os

// handle_pull_diagnostic answers textDocument/diagnostic (LSP 3.17) from the
// diagnostics the last check already published for the document: a pull starts
// no compiler and waits for no check. What the cache holds is what the push
// published, so the items are rebuilt through the same function the push builds
// its notification with — one dedup, one cap — and never through a second copy
// of either.
fn (mut app App) handle_pull_diagnostic(request Request) Response {
	params := json2.decode[DocumentDiagnosticParams](request.params) or {
		$if debug {
			log('Failed to decode DocumentDiagnosticParams: ${err}')
		}
		return Response{
			id:     request.id
			result: 'null'
		}
	}
	uri := params.text_document.uri
	items := app.pull_diagnostics_items(uri)
	result_id := pull_diagnostics_result_id(uri, items)
	if previous_id := params.previous_result_id {
		if previous_id == result_id {
			return Response{
				id:     request.id
				result: UnchangedDocumentDiagnosticReport{
					result_id: result_id
				}
			}
		}
	}
	return Response{
		id:     request.id
		result: FullDocumentDiagnosticReport{
			result_id: result_id
			items:     items
		}
	}
}

// pull_diagnostics_items rebuilds the item list last published for `uri`. An
// absent cache entry is a document no check has answered for yet, which is an
// empty list rather than an error. The buffer is read for the encoding step, so
// a pull of a file on disk that was never opened answers from disk.
fn (mut app App) pull_diagnostics_items(uri string) []LSPDiagnostic {
	mut v_errors := []JsonError{}
	if cached := app.diag_cache[uri] {
		v_errors = cached.errors
	}
	content := app.open_files[uri] or { os.read_file(uri_to_path(uri)) or { '' } }
	return app.diagnostics_notification_for(uri, content, v_errors).params.diagnostics
}

// pull_diagnostics_result_id names the item list published for a document. Both
// sides agree because the id is derived the same way on both: the URI and the
// encoded list, so a client that echoes back the id it holds compares equal
// exactly while nothing changed. Two digests over one string instead of one, so
// a collision cannot alias another document's list onto this id.
fn pull_diagnostics_result_id(uri string, items []LSPDiagnostic) string {
	return '${uri.hash().hex()}${json2.encode(items).hash().hex()}'
}
