module workspace_symbols

import lsp
import os

const base_dir = os.dir(@FILE)

pub const workspace_symbols_result = [
	lsp.SymbolInformation{
		name: 'main'
		kind: .function
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file1.vv'))
			range: lsp.Range{
				start: lsp.Position{2, 0}
				end: lsp.Position{4, 9}
			}
		}
	},
	lsp.SymbolInformation{
		name: 'Person'
		kind: .struct_
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file2.vv'))
			range: lsp.Range{
				start: lsp.Position{2, 0}
				end: lsp.Position{4, 13}
			}
		}
	},
	lsp.SymbolInformation{
		name: 'hello'
		kind: .function
		location: lsp.Location{
			uri: lsp.document_uri_from_path(os.join_path(base_dir, 'file2.vv'))
			range: lsp.Range{
				start: lsp.Position{6, 0}
				end: lsp.Position{8, 21}
			}
		}
	}
]
