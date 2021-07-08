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