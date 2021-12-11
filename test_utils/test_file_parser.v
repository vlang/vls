module test_utils

import regex

// newlines_to_spaces replaces the newlines
// and multiples into single space.
// TODO: use single instance of regex pattern
pub fn newlines_to_spaces(text string) string {
	mut re2 := regex.regex_opt(r'\s+') or { return text }
	return re2.replace(text, ' ')
}

// parse_test_file_content extracts and returns the source content
// and the expected output from the text mostly from .test.txt files.
pub fn parse_test_file_content(text string) (string, string) {
	triple_dash_idx := text.last_index('---') or { return '', '' }

	return text[..triple_dash_idx].trim_space(), text[triple_dash_idx + 3..].trim_space()
}
