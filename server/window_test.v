import server
import lsp
import test_utils
import json

const (
	log_message_method  = 'window/logMessage'
	show_message_method = 'window/showMessage'
)

fn test_log_message_error() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	// error
	ls.log_message('Error!', .error)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == log_message_method
	assert params == json.encode(lsp.LogMessageParams{
		@type: .error
		message: 'Error!'
	})
}

fn test_log_message_warning() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	// warning
	ls.log_message('This is a warning!', .warning)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == log_message_method
	assert params == json.encode(lsp.LogMessageParams{
		@type: .warning
		message: 'This is a warning!'
	})
}

fn test_log_message_info() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	// info
	ls.log_message('Hello World!', .info)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == log_message_method
	assert params == json.encode(lsp.LogMessageParams{
		@type: .info
		message: 'Hello World!'
	})
}

fn test_log_message_log() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	// log
	ls.log_message('Logged!', .log)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == log_message_method
	assert params == json.encode(lsp.LogMessageParams{
		@type: .log
		message: 'Logged!'
	})
}

fn test_show_message_error() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	// error
	ls.show_message('Error!', .error)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == show_message_method
	assert params == json.encode(lsp.ShowMessageParams{
		@type: .error
		message: 'Error!'
	})
}

fn test_show_message_warning() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	// warning
	ls.show_message('This is a warning!', .warning)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == show_message_method
	assert params == json.encode(lsp.ShowMessageParams{
		@type: .warning
		message: 'This is a warning!'
	})
}

fn test_show_message_info() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	// info
	ls.show_message('Hello World!', .info)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == show_message_method
	assert params == json.encode(lsp.ShowMessageParams{
		@type: .info
		message: 'Hello World!'
	})
}

fn test_show_message_log() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	// log
	ls.show_message('Logged!', .log)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == show_message_method
	assert params == json.encode(lsp.ShowMessageParams{
		@type: .log
		message: 'Logged!'
	})
}

fn test_show_message_request() {
	mut io := &test_utils.Testio{}
	mut ls := server.new(io)
	actions := [lsp.MessageActionItem{'Retry'}]
	ls.show_message_request('Failed!', actions, .info)
	method, params := io.notification() or {
		assert false
		return
	}
	assert method == 'window/showMessageRequest'
	assert params == json.encode(lsp.ShowMessageRequestParams{
		@type: .info
		message: 'Failed!'
		actions: actions
	})
}
