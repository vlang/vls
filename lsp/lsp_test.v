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

	input := [
		'C:\\coding\\test.v',
		'file:///C:/my/files',
		r'\\server\share\foo',
	]
	expected := [
		'file:///c%3A/coding/test.v',
		'file:///c%3A/my/files',
		'file://server/share/foo',
	]

	for i in 0 .. input.len {
		assert document_uri_from_path(input[i]) == expected[i]
	}
}

fn test_document_uri_unicode() {
	input := [
		'/usr/home/你好世界',
		r'C:/files/C%3A%5Cfiles',
	]
	mut expected := []string{}
	$if windows {
		expected << 'file:////usr/home/%E4%BD%A0%E5%A5%BD%E4%B8%96%E7%95%8C'
		expected << 'file:///c%3A/files/C%253A%255Cfiles'
	} $else {
		expected << 'file:///usr/home/%E4%BD%A0%E5%A5%BD%E4%B8%96%E7%95%8C'
		expected << 'file:///C%3A/files/C%253A%255Cfiles'
	}

	for i in 0 .. input.len {
		assert document_uri_from_path(input[i]) == expected[i]
	}
}

fn test_document_uri_path() {
	input := [
		'file:///baz/foo/hello.v',
		'file:///C%3A/upper_case/files',
		'file:///c%3A/lower_case/files',
		'file://server/share/foo',
		'file:///usr/home/%E4%BD%A0%E5%A5%BD%E4%B8%96%E7%95%8C',
	]
	mut expected := []string{}
	$if windows {
		expected << r'baz\foo\hello.v'
		expected << r'C:\upper_case\files'
		expected << r'C:\lower_case\files'
		expected << r'\\server\share\foo'
		expected << r'usr\home\你好世界'
	} $else {
		expected << '/baz/foo/hello.v'
		expected << '/C:/upper_case/files'
		expected << '/c:/lower_case/files'
		expected << '/share/foo'
		expected << '/usr/home/你好世界'
	}

	for i in 0 .. input.len {
		assert DocumentUri(input[i]).path() == expected[i]
	}
}
