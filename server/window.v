module server

import lsp

// log_message sends a window/logMessage notification to the client
pub fn (mut wr ResponseWriter) log_message(message string, typ lsp.MessageType) {
	wr.write_notify('window/logMessage', lsp.LogMessageParams{
		@type: typ
		message: message
	})
}

// show_message sends a window/showMessage notification to the client
pub fn (mut wr ResponseWriter) show_message(message string, typ lsp.MessageType) {
	wr.write_notify('window/showMessage', lsp.ShowMessageParams{
		@type: typ
		message: message
	})
}

pub fn (mut wr ResponseWriter) show_message_request(message string, actions []lsp.MessageActionItem, typ lsp.MessageType) {
	wr.write_notify('window/showMessageRequest', lsp.ShowMessageRequestParams{
		@type: typ
		message: message
		actions: actions
	})
}
