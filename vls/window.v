module vls

import lsp

// log_message sends a window/logMessage notification to the client
fn (mut ls Vls) log_message(message string, typ lsp.MessageType) {
	ls.notify('window/logMessage', lsp.LogMessageParams{
		@type: typ
		message: message
	})
}

// show_message sends a window/showMessage notification to the client
fn (mut ls Vls) show_message(message string, typ lsp.MessageType) {
	ls.notify('window/showMessage', lsp.ShowMessageParams{
		@type: typ
		message: message
	})
}

fn (mut ls Vls) show_message_request(message string, actions []lsp.MessageActionItem, typ lsp.MessageType) {
	ls.notify('window/showMessageRequest', lsp.ShowMessageRequestParams{
		@type: typ
		message: message
		actions: actions
	})
}
