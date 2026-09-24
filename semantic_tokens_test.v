module main

// V interpolates only `${expr}` in strings; an unbraced `$name` is plain text
// (V prints it as it is), so it stays inside the string token.
fn test_unbraced_dollar_name_is_string_text() {
	line := "\tprintln('a: \$name.len and \$u.name b')"
	tokens := tokenize_v_source('fn main() {\n${line}\n}\n').filter(it.line == 1)
	quote := line.index_u8(`'`)
	strings := tokens.filter(it.type_idx == sem_tok_string)
	assert strings.len == 1, strings.str()
	assert strings[0].start == quote
	assert strings[0].length == line.len - 1 - quote
	assert !tokens.any(it.start > quote && it.type_idx != sem_tok_string), tokens.str()
}

// A braced interpolation is code: the string tokens stop around it and its
// identifiers get tokens of their own.
fn test_braced_interpolation_is_code() {
	line := "\tprintln('a: \${name.len} b')"
	tokens := tokenize_v_source('fn main() {\n\tname := 1\n${line}\n}\n').filter(it.line == 2)
	strings := tokens.filter(it.type_idx == sem_tok_string)
	assert strings.len == 2, strings.str()
	name_col := line.index('name') or { -1 }
	assert tokens.any(it.start == name_col && it.type_idx != sem_tok_string), tokens.str()
}
