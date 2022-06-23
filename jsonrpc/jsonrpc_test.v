import jsonrpc

fn test_response_json_null() {
	resp := jsonrpc.Response<jsonrpc.Null>{id: '1'}
	assert resp.json() == '{"jsonrpc":"2.0","id":1,"result":null}'
}

fn test_notification_json_null() {
	resp := jsonrpc.NotificationMessage<jsonrpc.Null>{method: 'test'}
	assert resp.json() == '{"jsonrpc":"2.0","method":"test","params":null}'
}