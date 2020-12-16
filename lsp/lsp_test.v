module lsp

fn test_document_uri_from_path() {
	input := '/foo/bar/test.v'
	// NOTE: Testing will result to a cgen error when not explictly casted to string. 
	expected := document_uri_from_path(input).str()
	assert expected == 'file:///foo/bar/test.v'
}

fn test_document_uri_path() {
	uri := DocumentUri('file:///baz/foo/hello.v')
	expected := '/baz/foo/hello.v'

	assert uri.path() == expected
}