module errors

import strings.textscanner
import strings

pub interface ErrorData {}

pub type DataFormatterFn = fn (ErrorData) string 

pub fn format(data_formatter_fn DataFormatterFn, code_or_msg string, datum ...ErrorData) string {
	mut error_template := code_or_msg
	if code_or_msg in errors.message_templates {
		error_template = errors.message_templates[code_or_msg]
	}

	if datum.len == 0 {
		return error_template
	}

	mut scanner := textscanner.new(error_template)
	defer { unsafe { scanner.free() } }

	mut builder := strings.new_builder(error_template.len)
	mut cur_data_idx := 0
	for scanner.remaining() != 0 {
		chr := scanner.next()
		if chr == `%` && scanner.peek() == `s` {
			builder.write_string(data_formatter_fn(datum[cur_data_idx % datum.len]))
			cur_data_idx++

			scanner.skip_n(1)
		} else {
			// TODO: maps
			builder.write_rune(chr)
		}
	}

	return builder.str()
}
