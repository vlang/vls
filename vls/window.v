module vls

import lsp
import json
import jsonrpc

// send outputs the response on the desired connection type
fn (mut vls Vls) send(data string) {
	if data.len == 0 {
		if vls.test_mode {
			vls.response = ''
		}

		return
	}

	if vls.test_mode {
		vls.response = data
	}

	response := 'Content-Length: ${data.len}\r\n\r\n$data'
	match vls.connection_type {
		.tcp {
			// TODO: tcp
		}
		.stdio {
			print(response)
		}
	}
}

// log_message sends a window/logMessage notification to the client
fn (mut ls Vls) log_message(message string, typ lsp.MessageType) {
	result := jsonrpc.NotificationMessage<lsp.LogMessageParams>{
		method: 'window/logMessage'
		params: lsp.LogMessageParams{
			@type: typ
			message: message
		}
	}
	ls.send(json.encode(result))
}

// show_message sends a window/showMessage notification to the client
fn (mut ls Vls) show_message(message string, typ lsp.MessageType) {
	result := jsonrpc.NotificationMessage<lsp.ShowMessageParams>{
		method: 'window/showMessage'
		params: lsp.ShowMessageParams{
			@type: typ
			message: message
		}
	}
	ls.send(json.encode(result))
}

fn (mut ls Vls) show_message_request(message string, actions []lsp.MessageActionItem, typ lsp.MessageType) {
	result := jsonrpc.NotificationMessage<lsp.ShowMessageRequestParams>{
		method: 'window/showMessageRequest'
		params: lsp.ShowMessageRequestParams{
			@type: typ
			message: message
			actions: actions
		}
	}
	ls.send(json.encode(result))
}
