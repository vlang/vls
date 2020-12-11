module lsp

type DocumentUri = string

pub struct NotificationMessage {
    method string
    params string [raw]
}

// // method: $/cancelRequest
pub struct CancelParams {
    id int
}

pub struct Command {
	title string
	command string
	arguments []string
}

pub struct DocumentFilter {
	language string
	scheme string
	pattern string
}


pub struct TextDocumentRegistrationOptions {
	document_selector []DocumentFilter [json:documentSelector]
}