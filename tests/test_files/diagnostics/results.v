module diagnostics

import lsp
import os

const base_dir = os.dir(@FILE)

pub const diagnostics_result = lsp.PublishDiagnosticsParams{
	uri: lsp.document_uri_from_path(os.join_path(base_dir, 'simple.vv'))
	diagnostics: [
		lsp.Diagnostic{
			message: 'unexpected `eof`, expecting `}`'
			severity: .error
			range: lsp.Range{
				start: lsp.Position{4, 10}
				end: lsp.Position{4, 11}
			}
		},
		lsp.Diagnostic{
			message: 'function `main` must be declared in the main module'
			severity: .error
			range: lsp.Range{
				start: lsp.Position{0, 0}
				end: lsp.Position{0, 0}
			}
		},
		lsp.Diagnostic{
			message: 'module \'os\' is imported but never used'
			severity: .warning
			range: lsp.Range{
				start: lsp.Position{2, 7}
				end: lsp.Position{2, 9}
			}
		}
	]
}