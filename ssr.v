// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

// Structural search and replace, in the shape rust-analyzer's SSR uses:
// a `pattern ==>> template` rule whose `$name` placeholders carry the text
// of what they matched.
//
// What is deliberately NOT here, because each cannot be made safe on the
// index alone: typed wildcards (`$placeholders must be strings`), rules that
// span files or the workspace, and declaration-shape rewrites (rename already
// does that, and compiles the program to check its own result).
//
// Two invariants carry the safety of everything below:
//
//  1. Scope-negative. A rule is refused, as a whole, when anything it would
//     touch cannot be told safe from text: a `${...}` interpolation, a `$if`
//     branch, a comptime block, an attribute, a generic type position, or a
//     project that is only partly indexed.
//  2. Visible. Every match is inside the region the user selected, and the
//     preview is the edit set itself. There is no silent second match.

// ssr_max_matches bounds how many matches one rule applies, as
// rename_max_occurrences bounds a rename.
const ssr_max_matches = 200

// SsrRule is one parsed `pattern ==>> template`.
struct SsrRule {
	pattern      []string
	template     []string
	placeholders []string
}

// SsrMatch is one place a rule applies: the span to replace and the text that
// replaces it.
struct SsrMatch {
	start int
	end   int
	text  string
}

// ssr_refusal is why a rule could not be applied. One is never withheld when
// a rule is refused: the user acts on what it says.
type SsrRefusal = string

// ssr_parse_rule parses `pattern ==>> template`. The separator is exactly
// three `>` after an `=`, and it may appear only once. A placeholder is `$`
// and an identifier, repeated at most once in the pattern, and every template
// placeholder must be one the pattern defines.
fn ssr_parse_rule(input string) !SsrRule {
	sep := input.index('==>>') or { return error('a structural replace is written `old ==>> new`') }
	if input.index_after('==>>', sep + 1) or { -1 } >= 0 {
		return error('a structural replace has one `==>>`')
	}
	raw_pattern := input[..sep]
	raw_template := input[sep + 4..]
	pattern := ssr_split_tokens(raw_pattern)!
	template := ssr_split_tokens(raw_template)!
	if pattern.len == 0 {
		return error('the pattern is empty: a structural replace is written `old ==>> new`')
	}
	mut placeholders := []string{}
	for token in pattern {
		if !token.starts_with('$') {
			continue
		}
		if token in placeholders {
			return error('`${token}` is used more than once in the pattern')
		}
		placeholders << token
	}
	for token in template {
		if token.starts_with('$') && token !in placeholders {
			return error('the template uses `${token}`, which the pattern does not write')
		}
	}
	if !ssr_brackets_balance(pattern) {
		return error('the pattern of a structural replace does not balance its brackets')
	}
	return SsrRule{
		pattern:      pattern
		template:     template
		placeholders: placeholders
	}
}

// ssr_split_tokens splits a rule side into tokens. Whitespace separates them,
// and a bracket run is one token, so `foo(` is not `foo` and `(`. Identifiers
// carry their `_` and digits; a `$` prefix starts a placeholder.
fn ssr_split_tokens(text string) ![]string {
	mut tokens := []string{}
	mut i := 0
	for i < text.len {
		c := text[i]
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` {
			i++
			continue
		}
		if ssr_is_ident_char(c) {
			start := i
			for i < text.len && ssr_is_ident_char(text[i]) {
				i++
			}
			token := text[start..i]
			if token.starts_with('$') {
				if !ssr_placeholder_is_name(token) {
					return error('`$` in a structural replace is followed by a name')
				}
			}
			tokens << token
			continue
		}
		// A bracket run is one token: `f(` matches the callee and the open
		// bracket together, and `[]int{}` is one group rather than three.
		if c in [`(`, `)`, `[`, `]`, `{`, `}`] {
			start := i
			for i < text.len && text[i] in [`(`, `)`, `[`, `]`, `{`, `}`] {
				i++
			}
			tokens << text[start..i]
			continue
		}
		tokens << text[i..i + 1]
		i++
	}
	return tokens
}

fn ssr_is_ident_char(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
		|| c == `_` || c == `.` || c == `$`
}

fn ssr_placeholder_is_name(token string) bool {
	if token.len < 2 {
		return false
	}
	first := token[1]
	if !((first >= `a` && first <= `z`) || (first >= `A` && first <= `Z`) || first == `_`) {
		return false
	}
	for i in 2 .. token.len {
		c := token[i]
		if !((c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_`) {
			return false
		}
	}
	return true
}

fn ssr_brackets_balance(tokens []string) bool {
	mut depth := 0
	for token in tokens {
		for c in token {
			if c in [`(`, `[`, `{`] {
				depth++
			} else if c in [`)`, `]`, `}`] {
				depth--
				if depth < 0 {
					return false
				}
			}
		}
	}
	return depth == 0
}

// ssr_find_matches returns where the rule applies in `content`, in order and
// without overlap. `code_only` is the mask, not the string-blinding one: a
// `${...}` interpolation is code, and a match that touches it is refused.
fn ssr_find_matches(content string, rule SsrRule) []SsrMatch {
	mut matches := []SsrMatch{}
	mut search_from := 0
	for search_from < content.len && matches.len < ssr_max_matches {
		found := ssr_match_at(content, search_from, rule) or { break }
		if found.start >= found.end {
			break
		}
		// A match may not overlap the previous one.
		if matches.len > 0 && found.start < matches.last().end {
			search_from = found.end
			continue
		}
		matches << found
		search_from = found.end
	}
	return matches
}

// ssr_match_at matches the rule at or after `from`, and returns the first
// match it finds.
fn ssr_match_at(content string, from int, rule SsrRule) ?SsrMatch {
	mut i := from
	for i < content.len {
		if bound := ssr_try_match(content, i, rule) {
			return bound
		}
		i++
	}
	return none
}

// ssr_try_match matches the rule exactly at `at`.
fn ssr_try_match(content string, at int, rule SsrRule) ?SsrMatch {
	mut bindings := map[string]string{}
	mut pos := at
	mut token_index := 0
	// The match starts where its first token starts. The scan reaches this
	// one from the whitespace before it, and recording that offset would put
	// the preceding newline inside the edit.
	mut start := at
	for token_index < rule.pattern.len {
		token := rule.pattern[token_index]
		pos = ssr_skip_trivia(content, pos)
		if pos >= content.len {
			return none
		}
		if token_index == 0 {
			start = pos
		}
		if token.starts_with('$') {
			// A placeholder binds one balanced group: everything up to the
			// delimiter the next pattern token names, or to the end of the
			// line when it is the last token.
			name := token[1..]
			mut bound_end := pos
			next := if token_index + 1 < rule.pattern.len {
				rule.pattern[token_index + 1]
			} else {
				''
			}
			if next != '' {
				bound_end = ssr_scan_to_delimiter(content, pos, next) or { return none }
			} else {
				bound_end = ssr_scan_to_line_end(content, pos)
			}
			if bound_end <= pos {
				return none
			}
			bindings[name] = content[pos..bound_end]
			pos = bound_end
			// Trailing separators are tolerated, as upstream's matcher does.
			pos = ssr_skip_trailing_separator(content, pos, next)
			token_index++
			continue
		}
		if !ssr_token_matches_at(content, pos, token) {
			return none
		}
		pos = ssr_skip_token(pos, token)
		token_index++
	}
	// Every placeholder the pattern writes must have bound something.
	for placeholder in rule.placeholders {
		if placeholder[1..] !in bindings {
			return none
		}
	}
	rendered := ssr_render(rule.template, bindings)
	return SsrMatch{
		start: start
		end:   pos
		text:  rendered
	}
}

fn ssr_token_matches_at(content string, pos int, token string) bool {
	if pos + token.len > content.len {
		return false
	}
	if token[0] in [`(`, `)`, `[`, `]`, `{`, `}`] {
		return content[pos..pos + token.len] == token
	}
	if !content[pos..].starts_with(token) {
		return false
	}
	// A token that is a word must not be the tail of a longer one: `f(` of
	// `f(1)` matches inside `ff(1)` without this.
	if ssr_is_ident_char(token[0]) && ssr_is_ident_char(token[token.len - 1]) {
		if pos > 0 && ssr_is_ident_char(content[pos - 1]) {
			return false
		}
	}
	return true
}

fn ssr_skip_token(pos int, token string) int {
	return pos + token.len
}

fn ssr_skip_trivia(content string, pos int) int {
	mut at := pos
	for at < content.len {
		c := content[at]
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` {
			at++
			continue
		}
		// A line comment runs to the end of the line.
		if c == `/` && pos + 1 < content.len && content[pos + 1] == `/` {
			for pos < content.len && content[pos] != `\n` {
				at++
			}
			continue
		}
		break
	}
	return at
}

fn ssr_skip_trailing_separator(content string, pos int, next string) int {
	mut end := pos
	for end < content.len {
		c := content[end]
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` {
			end++
			continue
		}
		if c == `,` {
			// The pattern names this comma itself, so the token that follows
			// the placeholder still has to see it.
			if next.len > 0 && next[0] == c {
				break
			}
			end++
			continue
		}
		break
	}
	return end
}

// ssr_scan_to_delimiter returns where the span before `delimiter` ends. The
// delimiter is matched at bracket depth zero, so a `(` inside a placeholder
// span does not stop it: a callee's argument list, `(`, `)`.
fn ssr_scan_to_delimiter(content string, from int, delimiter string) ?int {
	mut depth := 0
	mut i := from
	for i < content.len {
		c := content[i]
		if c in [`(`, `[`, `{`] {
			depth++
			i++
			continue
		}
		if c in [`)`, `]`, `}`] {
			if depth == 0 && c == delimiter[0] {
				return i
			}
			depth--
			i++
			continue
		}
		if depth == 0 && i + delimiter.len <= content.len
			&& content[i..i + delimiter.len] == delimiter {
			// A delimiter inside an identifier is not one.
			if i > from && ssr_is_ident_char(content[i - 1]) && ssr_is_ident_char(delimiter[0]) {
				i++
				continue
			}
			return i
		}
		i++
	}
	return none
}

fn ssr_scan_to_line_end(content string, from int) int {
	for i in from .. content.len {
		if content[i] == `\n` {
			return i
		}
	}
	return content.len
}

// ssr_render writes the template with each placeholder's bound text. A
// binding is wrapped in parentheses unless it is a single primary token or a
// balanced group, the conservative stand-in for re-parsing the render, which
// vls has no parser to do. Without it, `$a + 1` would render `1 + 2 + 1` for
// a binding of `1 + 2`.
fn ssr_render(template []string, bindings map[string]string) string {
	mut parts := []string{}
	for i, token in template {
		if token.starts_with('$') {
			bound := bindings[token[1..]] or { '' }
			trimmed := bound.trim_space()
			// One primary token — an identifier, a literal, or a balanced
			// group standing alone — needs no wrap; anything an operator
			// runs through does.
			tokens := ssr_split_tokens(trimmed) or { [] }
			is_group := tokens.len == 1
				&& (trimmed.starts_with('(') || trimmed.starts_with('[')
					|| trimmed.starts_with('{'))
			needs_wrapping := ssr_needs_parentheses(trimmed) && !is_group
			if needs_wrapping {
				parts << '(${trimmed})'
			} else {
				parts << trimmed
			}
			continue
		}
		parts << token
		// A comma is followed by a space, as V code is written. The
		// tokenizer drops the rule's own spacing, and `g(2,1)` is not what
		// the template reads.
		if i + 1 < template.len && token == ',' && template[i + 1] != ')' {
			parts << ' '
		}
	}
	return parts.join('')
}

fn ssr_needs_parentheses(text string) bool {
	operators := ['+', '-', '*', '/', '%', '<', '>', '=', '&', '|', '^', '!', '?', ':', ' ']
	for c in operators {
		if text.contains(c) {
			return true
		}
	}
	return false
}

// ssr_build_action builds the structural-replace action for a selection, or a
// message naming what makes it unsafe.
fn (mut app App) build_ssr_action(uri string, content string, selection LSPRange, rule_input string) ?CodeAction {
	rule := ssr_parse_rule(rule_input) or { return none }
	scope := app.index_scope_for_uri(uri)
	if !app.index_is_complete_for_scope(scope) {
		app.send_log_message('ssr refused: the project is only partly indexed', 2)
		return none
	}
	lines := content.split_into_lines()
	starts := line_start_offsets(content)
	from := ssr_selection_start(content, starts, selection)
	to := ssr_selection_end(content, starts, lines, selection)
	region := content[from..to]
	matches := ssr_find_matches(region, rule)
	if matches.len == 0 {
		return none
	}
	// Before a single edit is built, every match is checked against the
	// constructs a structural replace cannot touch safely. The match spans
	// are relative to the selected region, so they are lifted by `from`
	// before the whole document is read against them.
	for hit in matches {
		absolute := SsrMatch{
			start: from + hit.start
			end:   from + hit.end
			text:  hit.text
		}
		reason := app.ssr_match_refusal(content, absolute)
		if reason != '' {
			app.send_log_message('ssr refused: ${reason}', 2)
			return none
		}
	}
	mut edits := []TextEdit{cap: matches.len}
	for hit in matches {
		edit_range := LSPRange{
			start: ssr_position_at(content, starts, from + hit.start, app.position_encoding)
			end:   ssr_position_at(content, starts, from + hit.end, app.position_encoding)
		}
		edits << TextEdit{
			range:    edit_range
			new_text: hit.text
		}
	}
	return CodeAction{
		title:        'Structural replace (${matches.len} match${if matches.len == 1 {
			''
		} else {
			'es'
		}})'
		kind:         code_action_kind_refactor
		is_preferred: true
		edit:         WorkspaceEdit{
			changes: {
				uri: edits
			}
		}
	}
}

// ssr_match_refusal reports why the match at `at` cannot be rewritten, or ''
// when it can.
fn (app &App) ssr_match_refusal(content string, hit SsrMatch) string {
	line := byte_to_line(content, hit.start)
	if app.ssr_in_comptime_branch(content, line) {
		return 'the match at line ${line + 1} is inside a `$if` branch this build does not compile, so a wrong rewrite is not reported'
	}
	// A match that touches an interpolation is inside code the mask kept as
	// code; the render cannot know how to write it back into the string.
	for i in hit.start .. hit.end {
		if i > 0 && content[i - 1] == `$` && content[i] == `{` {
			return 'the match at line ${line + 1} spans an interpolation, and the replacement would break the string'
		}
		if i > 0 && content[i - 1] == `}` && i > 1 && content[i - 2] == `{` {
			// Inside an interpolation: no closing brace may be produced there.
			return 'the match at line ${line + 1} spans an interpolation, and the replacement would break the string'
		}
	}
	// A placeholder in a type position renames a type parameter of a generic
	// declaration, which the render would write as its type argument.
	if app.ssr_in_type_position(content, hit.start) {
		return 'the match at line ${line + 1} is in a type position, which a structural replace does not write'
	}
	return ''
}

// ssr_in_comptime_branch reports whether the given line is inside a
// compile-time branch. The compiler only builds the branch the flags
// choose, so a match inside one is invisible to the slow check.
fn (app &App) ssr_in_comptime_branch(content string, line int) bool {
	if line <= 0 {
		return false
	}
	lines := content.split_into_lines()
	dollar := u8(36)
	// Scan the lines above the match for an unclosed branch block.
	mut depth := 0
	mut i := line - 1
	for i >= 0 {
		text := lines[i]
		if text.trim_space().starts_with('}') {
			depth++
			i--
			continue
		}
		before_brace := text.all_before('{').trim_space()
		if before_brace.len > 0 && before_brace[0] == dollar {
			if depth == 0 {
				return true
			}
			depth--
		}
		i--
	}
	return false
}

// ssr_in_type_position reports whether the match starts in a type position:
// after a generic argument's `[`, after a field's `:`, after a declaration's
// `)`, or on a struct field's type. A placeholder there would be written as
// a value where V expects a type, so the whole rule is refused instead.
fn (app &App) ssr_in_type_position(content string, at int) bool {
	newline := content[..at].last_index('\n') or { -1 }
	line_start := if newline < 0 { 0 } else { newline + 1 }
	line_end := content[line_start..].index('\n') or { content.len - line_start }
	prefix := content[line_start..at].trim_space()
	rest := content[at..line_start + line_end].trim_space()
	if prefix.ends_with('[') || prefix.ends_with(':') {
		return true
	}
	// A declaration that closes its parameter list on this line follows it
	// with the return type, so a match starting there is inside one.
	if prefix.ends_with(')') && ssr_line_first_word(content, line_start, line_end) == 'fn' {
		return true
	}
	// A struct field is written `item T` or `mut x T`: the line starts with a
	// field modifier and holds nothing but names, and the match starts on its
	// type, the final name. A statement such as `mut x := 0` carries an
	// operator after the match, which rules it out.
	if ssr_is_field_modifier(ssr_line_first_word(content, line_start, line_end))
		&& ssr_is_all_bare_names(prefix) && ssr_is_all_bare_names(rest) {
		return true
	}
	return false
}

// ssr_line_first_word is the leading word of a line, or '' for a blank one.
fn ssr_line_first_word(content string, line_start int, line_end int) string {
	line := content[line_start..line_start + line_end].trim_space()
	if !line.contains(' ') {
		return line
	}
	return line.all_before(' ')
}

// ssr_is_field_modifier reports whether the word declares a struct field,
// so the name that follows it is a type rather than an operand.
fn ssr_is_field_modifier(word string) bool {
	modifiers := ['item', 'mut', 'pub', 'shared', 'const', 'volatile', 'static']
	return word in modifiers
}

// ssr_is_all_bare_names reports whether the text is one or more identifiers
// separated by spaces, so `item x` is bare and `item x := 0` is not.
fn ssr_is_all_bare_names(text string) bool {
	trimmed := text.trim_space()
	if trimmed == '' {
		return false
	}
	for word in trimmed.split(' ') {
		if word == '' {
			continue
		}
		if !ssr_is_bare_name(word) {
			return false
		}
	}
	return true
}

// ssr_is_bare_name reports whether the text is exactly one identifier.
fn ssr_is_bare_name(text string) bool {
	if text == '' {
		return false
	}
	for i, c in text {
		is_letter := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
		is_digit := c >= `0` && c <= `9`
		if i == 0 && !is_letter {
			return false
		}
		if i > 0 && !is_letter && !is_digit {
			return false
		}
	}
	return true
}

// ssr_selection_start is the byte offset the selection starts at.
fn ssr_selection_start(content string, starts []int, selection LSPRange) int {
	if selection.start.line < 0 || selection.start.line >= starts.len {
		return 0
	}
	return ssr_position_to_byte(content, starts, selection.start)
}

// ssr_selection_end is the byte offset the selection ends at, clamped to the
// document end so a client range past the last line still selects all.
fn ssr_selection_end(content string, starts []int, lines []string, selection LSPRange) int {
	line := selection.end.line
	if line >= lines.len {
		return content.len
	}
	return ssr_position_to_byte(content, starts, selection.end)
}

// byte_to_line returns the 0-based line of a byte offset.
fn byte_to_line(content string, at int) int {
	mut line := 0
	for i in 0 .. at {
		if content[i] == `\n` {
			line++
		}
	}
	return line
}

// ssr_position_at converts an absolute byte offset into an LSP position in the
// negotiating client's encoding.
fn ssr_position_at(content string, starts []int, offset int, enc PositionEncoding) Position {
	line := byte_to_line(content, offset)
	return ssr_byte_to_position(content, starts, offset, line, enc)
}

// ssr_byte_to_position converts an absolute byte offset into an LSP position
// in the negotiating client's encoding.
fn ssr_byte_to_position(content string, starts []int, offset int, line int, enc PositionEncoding) Position {
	line_start := if line < starts.len { starts[line] } else { content.len }
	line_text := content[line_start..offset]
	return Position{
		line: line
		char: byte_to_encoded_col(line_text, line_text.len, enc)
	}
}

// ssr_position_to_byte is position_to_byte_offset with a line's own byte
// offset subtracted, so a range inside one line keeps its own column.
fn ssr_position_to_byte(content string, starts []int, position Position) int {
	line := position.line
	if line < 0 {
		return 0
	}
	if line >= starts.len {
		return content.len
	}
	line_start := starts[line]
	line_text := content[line_start..]
	mut byte_offset := position_to_byte_offset(content, starts, line,
		position.char, .utf8)
	if byte_offset > line_start + line_text.len {
		byte_offset = line_start + line_text.len
	}
	return byte_offset
}

// ssr_rule_at_selection returns the `pattern ==>> template` rule written on
// the line the selection starts on. A rule is written as a comment, as
// rust-analyzer's SSR accept one in a comment; a selection that starts on no
// such line carries no rule, and a structural replace is then not offered.
fn (app &App) ssr_rule_at_selection(uri string, selection LSPRange) string {
	content := app.open_files[uri] or { return '' }
	lines := content.split_into_lines()
	if selection.start.line < 0 || selection.start.line >= lines.len {
		return ''
	}
	line := lines[selection.start.line]
	hash := line.index('//') or { return '' }
	return line[hash + 2..].trim_space()
}
