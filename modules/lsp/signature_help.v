module lsp

pub struct SignatureHelpOptions {
	trigger_characters []string [json:triggerCharacters]
}

// method: ‘textDocument/signatureHelp’
// response: SignatureHelp | none
// request: TextDocumentPositionParams

pub struct SignatureHelp {
	signatures []SignatureInformation
	active_signature int [json:activeSignature]
	active_parameter int [json:activeParameter]
}

pub struct SignatureInformation {
	label string
	// document: string | MarkedContent
	document string [raw]
	parameters []ParameterInformation
}

pub struct ParameterInformation {
	// label string | [int, int]
	label string [raw]
	// document: string | MarkedContent
	document string
}

pub struct SignatureHelpRegistrationOptions {
	document_selector []DocumentFilter [json:documentSelector]
	trigger_characters []string [json:triggerCharacters]
}
