import vls
import lsp
import vls.testing

fn test_log_message() {
	mut io := testing.Testio{}
	ls := vls.new(io)
	ls.log_message('Hello World!', .info)
	assert io.response == '{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"Hello World!"}}'
}

fn test_show_message() {
	mut io := testing.Testio{}
	ls := vls.new(io)
	ls.show_message('Hello World!', .info)
	assert io.response == '{"jsonrpc":"2.0","method":"window/showMessage","params":{"type":3,"message":"Hello World!"}}'
}

fn test_show_message_request() {
	mut io := testing.Testio{}
	ls := vls.new(io)
	mut actions := [lsp.MessageActionItem{'Retry'}]
	ls.show_message_request('Failed!', actions, .info)
	assert io.response == '{"jsonrpc":"2.0","method":"window/showMessageRequest","params":{"type":3,"message":"Failed!","actions":[{"title":"Retry"}]}}'
}
