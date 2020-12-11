module lsp

pub struct SignatureHelpOptions {
	trigger_characters []string [json:triggerCharacters]
	retrigger_characters []string [json:retriggerCharacters]
}

pub enum SignatureHelpTriggerKind {
	invoked = 1
	trigger_character = 2
	content_change = 3
}

// method: ‘textDocument/signatureHelp’
// response: SignatureHelp | none
pub struct SignatureHelpParams {
pub:
	TextDocumentPositionParams
	context SignatureHelpContext
}

pub struct SignatureHelpContext {
	trigger_kind SignatureHelpTriggerKind [json:triggerKind]
	trigger_character string
	is_retrigger bool [json:isRetrigger]
	active_signature_help SignatureHelp [json:activeSignatureHelp]
}

pub struct SignatureHelp {
pub:
	signatures []SignatureInformation
	active_signature int [json:activeSignature]
	active_parameter int [json:activeParameter]
}

pub struct SignatureInformation {
pub mut:
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
