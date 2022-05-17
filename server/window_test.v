import server
import lsp
import test_utils
import jsonrpc.server_test_utils { new_test_client, TestClient }
import json

const (
	log_message_method  = 'window/logMessage'
	show_message_method = 'window/showMessage'
)

fn new_client() (&TestClient, server.ResponseWriter) {
	client := new_test_client(server.new())
	return client, client.server.writer()
}

fn test_log_message_error() ? {
	io, mut wr := new_client()
	// error
	wr.log_message('Error!', .error)
	msg := io.stream.notification_at<lsp.LogMessageParams>(0) ?
	assert msg.method == log_message_method
	assert msg.params == lsp.LogMessageParams{.error, 'Error!'}
}

fn test_log_message_warning() ? {
	io, mut wr := new_client()
	// warning
	wr.log_message('This is a warning!', .warning)
	msg := io.stream.notification_at<lsp.LogMessageParams>(0) ?
	assert msg.method == log_message_method
	assert msg.params == lsp.LogMessageParams{.warning, 'This is a warning!'}
}

fn test_log_message_info() ? {
	io, mut wr := new_client()
	// info
	wr.log_message('Hello World!', .info)
	msg := io.stream.notification_at<lsp.LogMessageParams>(0) ?
	assert msg.method == log_message_method
	assert msg.params == lsp.LogMessageParams{.info, 'Hello World!'}
}

fn test_log_message_log() ? {
	io, mut wr := new_client()
	// log
	wr.log_message('Logged!', .log)
	msg := io.stream.notification_at<lsp.LogMessageParams>(0) ?
	assert msg.method == log_message_method
	assert msg.params == lsp.LogMessageParams{.log, 'Logged!'}
}

fn test_show_message_error() ? {
	io, mut wr := new_client()
	// error
	wr.show_message('Error!', .error)
	msg := io.stream.notification_at<lsp.ShowMessageParams>(0) ?
	assert msg.method == show_message_method
	assert msg.params == lsp.ShowMessageParams{.error, 'Error!'}
}

fn test_show_message_warning() ? {
	io, mut wr := new_client()
	// warning
	wr.show_message('This is a warning!', .warning)
	msg := io.stream.notification_at<lsp.ShowMessageParams>(0) ?
	assert msg.method == show_message_method
	assert msg.params == lsp.ShowMessageParams{.warning, 'This is a warning!'}
}

fn test_show_message_info() ? {
	io, mut wr := new_client()
	// info
	wr.show_message('Hello World!', .info)
	msg := io.stream.notification_at<lsp.ShowMessageParams>(0) ?
	assert msg.method == show_message_method
	assert msg.params == lsp.ShowMessageParams{.info, 'Hello World!'}
}

fn test_show_message_log() ? {
	io, mut wr := new_client()
	// log
	wr.show_message('Logged!', .log)
	msg := io.stream.notification_at<lsp.ShowMessageParams>(0) ?
	assert msg.method == show_message_method
	assert msg.params == lsp.ShowMessageParams{.log, 'Logged!'}
}

fn test_show_message_request() ? {
	io, mut wr := new_client()
	actions := [lsp.MessageActionItem{'Retry'}]
	wr.show_message_request('Failed!', actions, .info)
	msg := io.stream.notification_at<lsp.ShowMessageRequestParams>(0) ?
	assert msg.method == 'window/showMessageRequest'
	assert msg.params == lsp.ShowMessageRequestParams{
		@type: .info
		message: 'Failed!'
		actions: actions
	}
}
