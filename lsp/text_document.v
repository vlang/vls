module lsp

pub struct Position {
pub:
    line int
    character int
}

pub struct Range {
    start Position
    end Position
}

pub struct TextEdit {
	range Range
	new_text string
}

pub struct TextDocumentIdentifier {
pub:
	uri string
}

pub struct TextDocumentEdit {
	text_document VersionedTextDocumentIdentifier [json:textDocument]
	edits []TextEdit
}

pub struct TextDocumentItem {
pub:
	uri string
	language_id string [json:languageId]
	version int
	text string
}

pub struct VersionedTextDocumentIdentifier {
pub:
	uri string
	version int
}

pub struct Location {
	uri string
	range Range
}

pub struct LocationLink {
	origin_selection_range Range [json:originSelectionRange]
	target_uri string [json:targetUri]
	target_range Range [json:targetRange]
	target_selection_range Range [json:targetSelectionRange]
}

// pub struct TextDocumentContentChangeEvent {
// 	range Range
// 	text string
// }

pub struct TextDocumentPositionParams {
pub:
	text_document TextDocumentIdentifier [json:textDocument]
	position Position
}

pub const (
	markup_kind_plaintext = 'plaintext'
	markup_kind_markdown = 'markdown'
)

pub struct MarkupContent {
	kind string // MarkupKind
	value string
}

pub struct TextDocument {
	uri DocumentUri
	language_id string
	version int
	line_count int
}

pub struct FullTextDocument {
	uri DocumentUri
	language_id string
	version int
	content string
	line_offsets []int
}