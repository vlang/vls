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
	mut var_name := strings.new_builder(100)
	defer { unsafe { var_name.free() } }

	mut cur_data_idx := 0
	for scanner.remaining() != 0 {
		chr := scanner.next()
		if chr == `%` && scanner.peek() == `s` {
			builder.write_string(data_formatter_fn(datum[cur_data_idx % datum.len]))
			cur_data_idx++

			scanner.skip_n(1)
		} else if chr == `{` && scanner.peek() == chr && (datum.last() is map[string]ErrorData || datum.last() is map[string]string) {
			// maps are used for accepting named parameters in error messages
			// e.g. "cannot selectively import {{var}} from {{mod}}. use {{mod}}.{{var}} instead"
			scanner.skip_n(1)

			// get var name
			for scanner.current() != `}` && scanner.peek() != `}` {
				var_chr := scanner.next()
				if var_chr == ` ` {
					continue
				}

				var_name.write_rune(var_chr)
			}

			// get data
			last := datum.last()
			got_var_name := var_name.str()
			if last is map[string]ErrorData {
				value := (*last)[got_var_name] or { ErrorData('missing value') }
				builder.write_string(data_formatter_fn(value))
			} else if last is map[string]string {
				value := (*last)[got_var_name] or { 'missing value' }
				builder.write_string(value)
			}

			scanner.skip_n(2)
		} else {
			// TODO: maps
			builder.write_rune(chr)
		}
	}

	return builder.str()
}
