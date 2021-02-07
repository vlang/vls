import vls

fn test_compute_offset_lf() {
	content := 'module main\nfn main() {\n    test := 123\n}'
	exp := 38
	res := vls.compute_offset(content.bytes(), 2, 14)
	assert res == exp
}

fn test_compute_offset_crlf() {
	content := 'module main\r\nfn main() {\r\n    test := 123\r\n}'
	exp := 40
	res := vls.compute_offset(content.bytes(), 2, 14)
	assert res == exp
}