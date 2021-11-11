module analyzer

pub enum MessageKind {
	error
	warning
	notice
}

pub struct Message {
pub:
	kind      MessageKind = .error
	file_path string
	range     C.TSRange
	content   string
}

// has_range checks if there is an existing message from a given path and range
pub fn (msgs []Message) has_range(file_path string, range C.TSRange) bool {
	for m in msgs {
		if m.file_path == file_path && m.range.eq(range) {
			return true
		}
	}

	return false
}

pub fn (mut msgs []Message) report(msg Message) {
	if msgs.has_range(msg.file_path, msg.range) {
		return
	}
	msgs << msg
}

pub struct AnalyzerError {
	msg   string
	code  int
	range C.TSRange
}

pub fn (info AnalyzerError) str() string {
	start := '{$info.range.start_point.row:$info.range.start_point.column}'
	end := '{$info.range.end_point.row:$info.range.end_point.column}'
	return '[$start -> $end] $info.msg ($info.code)'
}

fn report_error(msg string, range C.TSRange) IError {
	return AnalyzerError{
		msg: msg
		code: 0
		range: range
	}
}

// report_error reports the AnalyzerError to the messages array
pub fn (mut ss Store) report_error(err IError) {
	if err is AnalyzerError {
		ss.report(
			content: err.msg
			range: err.range
			file_path: ss.cur_file_path
		)
	}
}
