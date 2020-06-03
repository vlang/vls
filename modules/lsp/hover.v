module lsp

pub struct HoverSettings {
	dynamic_registration bool [json:dynamicRegistration]
	content_format []string [json:contentFormat]
}

// method: ‘textDocument/hover’
// response: Hover | none
// request: TextDocumentPositionParams

pub struct Hover {
	contents string [raw]
	range Range
}

// pub type MarkedString = string | MarkedStringS
pub struct MarkedString {
	language string
	value string
}

