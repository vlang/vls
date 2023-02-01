module analyzer

pub struct AnalyzerError {
	Error
	msg       string
	file_path string
	range     C.TSRange
}

pub fn (err AnalyzerError) msg() string {
	start := '${err.range.start_point.row}:${err.range.start_point.column}'
	end := '${err.range.end_point.row}:${err.range.end_point.column}'
	return '[${start} -> ${end}] ${err.msg}'
}

pub fn (err AnalyzerError) str() string {
	return err.msg()
}

fn report_error(msg string, range C.TSRange) IError {
	return AnalyzerError{
		msg: msg
		range: range
	}
}

// report_error reports the AnalyzerError to the messages array
pub fn (mut ss Store) report_error(err IError) {
	if err is AnalyzerError {
		ss.report(
			kind: .error
			message: err.msg
			range: err.range
			file_path: err.file_path
		)
	}
}

// report_error_with_path reports AnalyzerError to the messages array, and allow
// you to specify file path of this error with an argument.
pub fn (mut ss Store) report_error_with_path(err IError, file_path string) {
	if err is AnalyzerError {
		ss.report(
			kind: .error
			message: err.msg
			range: err.range
			file_path: file_path
		)
	}
}
