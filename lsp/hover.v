module lsp

pub struct HoverSettings {
	dynamic_registration bool     [json: dynamicRegistration]
	content_format       []string [json: contentFormat]
}

// method: ‘textDocument/hover’
// response: Hover | none
// request: TextDocumentPositionParams
pub struct HoverParams {
pub:
	text_document TextDocumentIdentifier [json: textDocument]
	position      Position
}

type HoverResponseContent = MarkedString | []MarkedString | MarkupContent

pub struct Hover {
pub:
	contents HoverResponseContent
	range    Range
}

// pub type MarkedString = string | MarkedString
pub struct MarkedString {
	language string
	value    string
}

pub fn v_marked_string(text string) MarkedString {
	return MarkedString{
		language: 'v'
		value: text
	}
}
