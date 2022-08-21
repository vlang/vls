import analyzer.errors

fn simple_data_formatter (data errors.ErrorData) string {
	if data is string {
		return *data
	} else {
		return '$data'
	}
}

fn test_format() {
	assert errors.format(simple_data_formatter, 'hello %s', 'world') == 'hello world'
	assert errors.format(simple_data_formatter, errors.undefined_operation_error, 'int', '+', 'int') == 'undefined operation `int` + `int`'
}