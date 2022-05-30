module lsp

fn test_document_uri_from_path() {
	input := '/foo/bar/test.v'
	uri := document_uri_from_path(input)
	$if windows {
		assert uri == 'file:////foo/bar/test.v'
	} $else {
		assert uri == 'file:///foo/bar/test.v'
	}
	assert document_uri_from_path(uri) == uri
}

fn test_document_uri_from_path_windows() {
	$if !windows {
		return
	}

	assert document_uri_from_path('C:\\coding\\test.v') == 'file:///C%3A/coding/test.v'
}

fn test_document_uri_path() {
	uri := DocumentUri('file:///baz/foo/hello.v')
	mut expected := ''
	$if windows {
		expected = 'baz\\foo\\hello.v'
	} $else {
		expected = '/baz/foo/hello.v'
	}
	assert uri.path() == expected
}
