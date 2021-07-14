module analyzer

pub enum MessageKind {
	error
	warning
	notice
}

pub struct Message {
pub:
	kind MessageKind = .error
	file_path string
	range C.TSRange
	content string
}

pub fn (msgs []Message) has_range(range C.TSRange) bool {
	for m in msgs {
		if m.range.eq(range) {
			return true
		}
	}

	return false
}

pub struct AnalyzerError {
	msg string
	code int
	range C.TSRange
}

pub fn (info AnalyzerError) str() string {
	start := '{${info.range.start_point.row}:${info.range.start_point.column}}'
	end := '{${info.range.end_point.row}:${info.range.end_point.column}}'
	return '[${start} -> ${end}] ${info.msg} (${info.code})'
}

fn report_error(msg string, range C.TSRange) IError {
	return AnalyzerError{
		msg: msg
		code: 0
		range: range
	}
}

pub fn (mut ss Store) report_error(err IError) {
	if err is AnalyzerError {
		ss.report({ 
			content: err.msg
			range: err.range
			file_path: ss.cur_file_path.clone()
		})
	}
}
