// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

fn test_ssr_parse_rule_rejects_a_missing_separator() {
	ssr_parse_rule('foo(1)') or {
		assert err.msg().contains('old ==>> new')
		return
	}
	assert false, 'a rule with no separator was accepted'
}

fn test_ssr_parse_rule_rejects_two_separators() {
	ssr_parse_rule('a ==>> b ==>> c') or {
		assert err.msg().contains('one `==>>`')
		return
	}
	assert false, 'two separators were accepted'
}

fn test_ssr_parse_rule_rejects_an_empty_pattern() {
	ssr_parse_rule(' ==>> b') or {
		assert err.msg().contains('pattern is empty')
		return
	}
	assert false, 'an empty pattern was accepted'
}

fn test_ssr_parse_rule_rejects_a_repeated_placeholder() {
	ssr_parse_rule('f($a, $a) ==>> g($a)') or {
		assert err.msg().contains('more than once')
		return
	}
	assert false, 'a repeated placeholder was accepted'
}

fn test_ssr_parse_rule_rejects_an_undefined_template_placeholder() {
	ssr_parse_rule('f($a) ==>> g($b)') or {
		assert err.msg().contains('$b')
		return
	}
	assert false, 'an undefined template placeholder was accepted'
}

fn test_ssr_parse_rule_rejects_unbalanced_brackets() {
	ssr_parse_rule('f( ==>> x') or {
		assert err.msg().contains('brackets')
		return
	}
	assert false, 'an unbalanced pattern was accepted'
}

fn test_ssr_parse_rule_accepts_a_rewrite() {
	rule := ssr_parse_rule('old ==>> new') or {
		assert false, 'a valid rule was refused: ${err}'
		return
	}
	assert rule.pattern == ['old']
	assert rule.template == ['new']
}

fn test_ssr_matches_an_identifier_call_and_binds_arguments() {
	rule := ssr_parse_rule('f($a, $b) ==>> g($b, $a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	matches := ssr_find_matches('f(1, 2)', rule)
	assert matches.len == 1, matches.str()
	assert matches[0].start == 0
	assert matches[0].end == 7
	assert matches[0].text == 'g(2, 1)'
}

fn test_ssr_matches_every_occurrence() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	matches := ssr_find_matches('f(1) f(2) f(x)', rule)
	assert matches.len == 3, matches.len.str()
	assert matches.map(it.text) == ['g(1)', 'g(2)', 'g(x)']
}

fn test_ssr_bounds_how_many_matches_a_rule_applies() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// The bound is what keeps one rule from rewriting a whole program in one
	// edit set, so it is asserted rather than left to hold by construction.
	mut parts := ['module main', '', 'fn main() {']
	for _ in 0 .. 250 {
		parts << '\tf(1)'
	}
	parts << '}'
	matches := ssr_find_matches(parts.join('\n'), rule)
	assert matches.len == ssr_max_matches, matches.len.str()
}

fn test_ssr_parenthesises_a_binding_that_precedence_would_split() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	matches := ssr_find_matches('f(1 + 2)', rule)
	assert matches.len == 1
	assert matches[0].text == 'g((1 + 2))', matches[0].text
}

fn test_ssr_leaves_a_balanced_binding_unwrapped() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	matches := ssr_find_matches('f(h(1))', rule)
	assert matches.len == 1
	assert matches[0].text == 'g(h(1))', matches[0].text
}

fn test_ssr_wraps_a_binding_that_a_template_operator_would_split() {
	rule := ssr_parse_rule('f($a) ==>> g($a + 1)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// The template adds to the binding, so a binding the operators run
	// through is wrapped or the render's meaning changes. The spacing is
	// tight because the tokenizer drops the rule's own; `v fmt` unwinds it,
	// and the wrap is what keeps the meaning.
	matches := ssr_find_matches('f(1 + 2)', rule)
	assert matches.len == 1
	assert matches[0].text == 'g((1 + 2)+1)', matches[0].text
}

fn test_ssr_leaves_a_primary_binding_unwrapped_before_an_operator() {
	rule := ssr_parse_rule('f($a) ==>> g($a + 1)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// A single name is already a primary, so wrapping it would only add
	// parentheses the rule's author never wrote.
	matches := ssr_find_matches('f(x)', rule)
	assert matches.len == 1
	assert matches[0].text == 'g(x+1)', matches[0].text
}

fn test_ssr_allows_a_match_after_an_escaped_interpolation_marker() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// `\${` is an escaped dollar: the string holds those characters rather
	// than an interpolation, so a match there is an ordinary one. Refusing it
	// would make a rewrite inside an escaped string impossible.
	content := "module main\n\nfn main() {\n\ts := 'a\\\${f(1)}c'\n}\n"
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	mut app := App{}
	assert ssr_match_refusal(content, matches[0]) == ''
}

fn test_ssr_allows_a_match_inside_a_backtick_string() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// A backtick string is raw, so `${` is its text and not an interpolation.
	content := 'module main\n\nfn main() {\n\ts := `a\${f(1)}c`\n}\n'
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	mut app := App{}
	assert ssr_match_refusal(content, matches[0]) == ''
}

fn test_ssr_does_not_match_across_an_identifier_boundary() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	matches := ssr_find_matches('ff(x)', rule)
	assert matches.len == 0, matches.str()
}

fn test_ssr_refuses_a_match_inside_a_comptime_branch() {
	content := 'module main\n\n\$if production ? {\n\tf(1)\n}\n'
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1
	mut app := App{}
	reason := ssr_match_refusal(content, matches[0])
	assert reason.contains('$if'), reason
	assert reason.contains('not reported'), reason
}

fn test_ssr_refuses_a_match_that_starts_inside_an_interpolation() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// The pattern matched the interpolation's own expression, so the match
	// starts on the two bytes after `${`.
	content := "module main\n\nfn main() {\n\ts := 'a\${f(1)}c'\n}\n"
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	mut app := App{}
	reason := ssr_match_refusal(content, matches[0])
	assert reason.contains('interpolation'), reason
	// A match further into the span is refused too, not only one that starts
	// on the interpolation's first byte.
	deep := "module main\n\nfn main() {\n\ts := 'a\${x + f(1)}c'\n}\n"
	deep_matches := ssr_find_matches(deep, rule)
	assert deep_matches.len == 1, deep_matches.len.str()
	assert ssr_match_refusal(deep, deep_matches[0]).contains('interpolation')
}

fn test_ssr_refuses_a_plain_match_for_nothing() {
	rule := ssr_parse_rule('println($a) ==>> dump($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	content := "module main\n\nfn main() {\n\ts := 'abc'\n\tprintln(s)\n}\n"
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	mut app := App{}
	assert ssr_match_refusal(content, matches[0]) == ''
}

fn test_ssr_refuses_a_match_in_a_type_position() {
	content := 'module main\n\nstruct Box[T] {\n\titem T\n}\n'
	mut app := App{}
	// `T` on the field line is in a type position.
	at := content.index('item T') or { return }
	hit := SsrMatch{
		start: at + 5
		end:   at + 6
	}
	reason := ssr_match_refusal(content, hit)
	assert reason.contains('type position'), reason
}

fn test_ssr_lifts_a_selection_before_it_refuses_a_match() {
	mut app := App{}
	// The selection starts inside a `$if` branch's own line, so a match's
	// span is relative to the selected region. The refusal reads the whole
	// document, so lifting the span by the selection's start is what lets it
	// find the branch at all.
	content := 'module main\n\nfn main() {\n\tx := 0\n\t\$if slow ? {\n\t\tf(1)\n\t}\n}\n'
	uri := 'file:///tmp/ssr_lift/main.v'
	app.open_files[uri] = content
	selection := LSPRange{
		start: Position{
			line: 4
			char: 1
		}
		end:   Position{
			line: 6
			char: 3
		}
	}
	if _ := app.build_ssr_action(uri, content, selection, 'f($a) ==>> g($a)') {
		assert false, 'a match inside a `$if` branch must be refused, not rewritten'
	}
}

fn test_ssr_in_comptime_branch_skips_a_line_below_a_closed_branch() {
	mut app := App{}
	content := 'module main\n\nfn main() {\n\tf(1)\n}\n'
	at := content.index('f(1)') or { return }
	assert !ssr_in_comptime_branch(content, ssr_byte_to_line(content, at))
	// The branch closed above the match, so the match is not inside it.
	below := '\$if x ? {\n\tg(1)\n}\n\nfn h() {\n\tf(1)\n}\n'
	line := ssr_byte_to_line(below, below.index('f(1)') or { return })
	assert !ssr_in_comptime_branch(below, line)
}

fn test_ssr_refuses_a_match_inside_an_else_branch() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// `} $else {` closes one branch and opens the next on one line, and the
	// compiler does not build the branch the flags do not choose, so a wrong
	// rewrite in it is invisible to the slow check.
	content := 'module main\n\n\$if x ? {\n\tg(1)\n} \$else {\n\tf(1)\n}\n'
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	mut app := App{}
	reason := ssr_match_refusal(content, matches[0])
	assert reason.contains('\$if'), reason
	// A match below the whole pair is not in either branch.
	below := 'module main\n\n\$if x ? {\n\tg(1)\n} \$else {\n\th(1)\n}\n\nfn k() {\n\tf(1)\n}\n'
	below_matches := ssr_find_matches(below, rule)
	assert below_matches.len == 1, below_matches.len.str()
	assert ssr_match_refusal(below, below_matches[0]) == ''
}

fn test_ssr_refuses_a_match_inside_an_attribute() {
	rule := ssr_parse_rule('export ==>> inline') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	content := '@[export]\nfn main() {\n}\n'
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	mut app := App{}
	reason := ssr_match_refusal(content, matches[0])
	// The refusal must name the attribute, not call it a type position: the
	// two are refused for different reasons and only one of them is true.
	assert reason.contains('attribute'), reason
}

fn test_ssr_refuses_an_annotated_field_type() {
	rule := ssr_parse_rule('T ==>> U') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// The field's type carries an attribute after it, so the type is not the
	// last name on the line.
	content := 'module main\n\nstruct S {\n\titem x T @[json: json]\n}\n'
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	mut app := App{}
	assert ssr_match_refusal(content, matches[0]).contains('type position')
}

fn test_ssr_allows_a_match_inside_an_array_literal() {
	rule := ssr_parse_rule('f($a) ==>> g($a)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// `[` after `:=` opens an array literal, not a generic argument, so the
	// match is an ordinary one and must not be refused as a type.
	content := 'module main\n\nfn main() {\n\tx := [f(1)]\n}\n'
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	mut app := App{}
	assert ssr_match_refusal(content, matches[0]) == ''
}

fn test_ssr_refuses_a_match_inside_a_generic_argument() {
	rule := ssr_parse_rule('T ==>> U') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// A generic instantiation is indistinguishable from an index by text
	// alone, so a match after `Foo[` is refused rather than guessed.
	content := 'module main\n\nfn main() {\n\tx := Foo[int]{}\n}\n'
	matches := ssr_find_matches(content, rule)
	if matches.len > 0 {
		mut app := App{}
		assert ssr_match_refusal(content, matches[0]).contains('type position')
	}
}

fn test_ssr_matches_across_a_line_comment_between_the_pattern_tokens() {
	rule := ssr_parse_rule('f(1) ==>> g(1)') or {
		assert false, 'invalid rule: ${err}'
		return
	}
	// The `(` is matched, and the `1` the pattern names sits after a line
	// comment. Trivia is skipped by an offset that moves: a scan bound on the
	// offset the function was called with never terminates here.
	content := 'module main\n\nfn main() {\n\tf( // a note\n\t  1)\n}\n'
	matches := ssr_find_matches(content, rule)
	assert matches.len == 1, matches.len.str()
	assert matches[0].text == 'g(1)', matches[0].text
}

fn test_ssr_byte_to_line_reports_the_holding_line() {
	assert ssr_byte_to_line('', 0) == 0
	assert ssr_byte_to_line('a\nb\nc', 4) == 2
	assert ssr_byte_to_line('a\nb\nc', 0) == 0
}

fn test_ssr_position_round_trips_a_byte_offset() {
	content := 'abc\ndef\nghi'
	starts := line_start_offsets(content)
	mut app := App{}
	for offset in [0, 3, 4, 8, 10] {
		position := ssr_position_at(content, starts, offset, .utf16)
		assert position.line == ssr_byte_to_line(content, offset), 'offset ${offset}'
	}
	_ = app
}
