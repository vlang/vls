import vls
import lsp
import vls.testing

fn test_log_message() {
	mut io := testing.Testio{}
	ls := vls.new(io)

	// error
	ls.log_message('Error!', .error)
	io.assert_response(lsp.LogMessageParams{
		@type: .error
		message: 'Error!'
	})

	// warning
	ls.log_message('This is a warning!', .warning)
	io.assert_response(lsp.LogMessageParams{
		@type: .warning
		message: 'This is a warning!'
	})

	// info
	ls.log_message('Hello World!', .info)
	io.assert_response(lsp.LogMessageParams{
		@type: .info
		message: 'Hello World!'
	})

	// log
	ls.log_message('Logged!', .log)
	io.assert_response(lsp.LogMessageParams{
		@type: .log
		message: 'Logged!'
	})
}

fn test_show_message() {
	mut io := testing.Testio{}
	ls := vls.new(io)

	// error
	ls.show_message('Error!', .error)
	io.assert_response(lsp.ShowMessageParams{
		@type: .error
		message: 'Error!'
	})

	// warning
	ls.show_message('This is a warning!', .warning)
	io.assert_response(lsp.ShowMessageParams{
		@type: .warning
		message: 'This is a warning!'
	})

	// info
	ls.show_message('Hello World!', .info)
	io.assert_response(lsp.ShowMessageParams{
		@type: .info
		message: 'Hello World!'
	})

	// log
	ls.show_message('Logged!', .log)
	io.assert_response(lsp.ShowMessageParams{
		@type: .log
		message: 'Logged!'
	})
}

fn test_show_message_request() {
	mut io := testing.Testio{}
	ls := vls.new(io)

	actions := [lsp.MessageActionItem{'Retry'}]
	ls.show_message_request('Failed!', actions, .info)
	io.assert_response(lsp.ShowMessageRequestParams{
		@type: .info
		message: 'Failed!'
		actions: actions
	})
}
