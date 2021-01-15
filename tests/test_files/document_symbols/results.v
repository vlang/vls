module document_symbols

import lsp

// file_uris will be replaced inside the test case
// because the uri may be different in each platform
pub const doc_symbols_result = {
	'simple.vv': [
		lsp.SymbolInformation{
			name: 'Uri'
			kind: .type_parameter
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{2, 0}
					end: lsp.Position{2, 8}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'text'
			kind: .constant
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{5, 2}
					end: lsp.Position{5, 6}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'two'
			kind: .constant
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{6, 2}
					end: lsp.Position{6, 5}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'Color'
			kind: .enum_
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{9, 0}
					end: lsp.Position{13, 10}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'Person'
			kind: .struct_
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{15, 0}
					end: lsp.Position{17, 13}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'Person.say'
			kind: .method
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{19, 0}
					end: lsp.Position{21, 19}
				}
			}
		},
		lsp.SymbolInformation{
			name: 'main'
			kind: .function
			location: lsp.Location{
				range: lsp.Range{
					start: lsp.Position{23, 0}
					end: lsp.Position{26, 9}
				}
			}
		}
	]
}
