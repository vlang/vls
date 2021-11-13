module test_utils

fn test_parse_test_file_content() {
	src, expected := parse_test_file_content('hello\n---\n(world)\n(test)\t\t\t(world)')
	assert src == 'hello'
	assert expected == '(world) (test) (world)'
}