module server

import lsp
import jsonrpc

// log_message sends a window/logMessage notification to the client
fn (mut ls Vls) log_message(message string, typ lsp.MessageType) {
	ls.notify(jsonrpc.NotificationMessage<lsp.LogMessageParams>{
		method: 'window/logMessage'
		params: lsp.LogMessageParams{
			@type: typ
			message: message
		}
	})
}

// show_message sends a window/showMessage notification to the client
fn (mut ls Vls) show_message(message string, typ lsp.MessageType) {
	ls.notify(jsonrpc.NotificationMessage<lsp.ShowMessageParams>{
		method: 'window/showMessage'
		params: lsp.ShowMessageParams{
			@type: typ
			message: message
		}
	})
}

fn (mut ls Vls) show_message_request(message string, actions []lsp.MessageActionItem, typ lsp.MessageType) {
	ls.notify(jsonrpc.NotificationMessage<lsp.ShowMessageRequestParams>{
		method: 'window/showMessageRequest'
		params: lsp.ShowMessageRequestParams{
			@type: typ
			message: message
			actions: actions
		}
	})
}
