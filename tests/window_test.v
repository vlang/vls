import vls
import lsp

fn test_log_message() {
	mut ls := vls.Vls{
		test_mode: true
	}
	ls.log_message('Hello World!', .info)
	assert ls.response == '{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"Hello World!"}}'
}

fn test_show_message() {
	mut ls := vls.Vls{
		test_mode: true
	}
	ls.show_message('Hello World!', .info)
	assert ls.response == '{"jsonrpc":"2.0","method":"window/showMessage","params":{"type":3,"message":"Hello World!"}}'
}

fn test_show_message_request() {
	mut ls := vls.Vls{
		test_mode: true
	}
	mut actions := [lsp.MessageActionItem{'Retry'}]
	ls.show_message_request('Failed!', actions, .info)
	assert ls.response == '{"jsonrpc":"2.0","method":"window/showMessageRequest","params":{"type":3,"message":"Failed!","actions":[{"title":"Retry"}]}}'
}
