module analyzer

import strconv

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

pub fn (msg Message) to_message() Message {
	return msg
}

pub interface IMessage {
	file_path string
	range C.TSRange
	to_message() Message
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

const (
	mismatched_type_error = 100	
	not_found_error = 101
	not_public_error = 102
	invalid_argument_error = 103
	undefined_operation_error = 104
	unknown_type_error = 105
	ambiguous_method_error = 106
	ambiguous_field_error = 107
	ambiguous_call_error = 108
	append_type_mismatch_error = 109
	array_append_expr_error = 110
	invalid_array_element_type_error = 111
)

const error_messages = {
	analyzer.mismatched_type_error: 'mismatched types `%s` and `%s`'
	analyzer.not_found_error: 'symbol `%s` not found'
	analyzer.not_public_error: 'symbol `%s` not public'
	analyzer.invalid_argument_error: 'cannot use `%s` as `%s` in argument %s to `%s`'
	analyzer.undefined_operation_error: 'undefined operation `%s` %s `%s`'
	analyzer.unknown_type_error: 'unknown type `%s`'
	analyzer.ambiguous_method_error: 'ambiguous method `%s`'
	analyzer.ambiguous_field_error: 'ambiguous field `%s`'
	analyzer.ambiguous_call_error: 'ambiguous call to: `%s`, may refer to fn `%s` or variable `%s`'
	analyzer.append_type_mismatch_error: 'cannot append `%s` to `%s`'
	analyzer.array_append_expr_error: 'array append cannot be used in an expression'
	analyzer.invalid_array_element_type_error: 'invalid array element: expected `%s`, not `%s`'
}

pub struct AnalyzerError {
	msg   string
	code  int
	file_path string
	range C.TSRange
mut:
	parameters []string
}

fn (err AnalyzerError) formatted_message() string {
	ptrs := unsafe { err.parameters.pointers() }
	return strconv.v_sprintf(error_messages[err.code], ...ptrs)
}

pub fn (err AnalyzerError) to_message() Message {
	err_msg := if err.code == 0 || err.msg.len != 0 { 
		err.msg 
	} else { 
		err.formatted_message() 
	}

	return Message{
		kind: .error
		content: err_msg
		range: err.range
		file_path: err.file_path
	}
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
		ss.report(err)
	}
}
