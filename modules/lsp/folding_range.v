module lsp

// /**
//  * Folding range provider options.
//  */
// export interface FoldingRangeProviderOptions {
// }

// method: ‘textDocument/foldingRange’
// response: []FoldingRange | none
pub struct FoldingRangeParams {
	text_document TextDocumentIdentifier [json:textDocument]
}

pub const (
	FoldingRangeKindComment = 'comment'
	FoldingRangeKindImports = 'imports'
	FoldingRangeKindRegion = 'region'
)

pub struct FoldingRange {
	start_line int [json:startLine]
	start_character int [json:startCharacter]
	end_line int [json:endLine]
	end_character int [json:endCharacter]
	kind string
}

