// Tests for the two refactors in assists.v: extracting a pure expression into a
// variable of its own, and inlining a local that is written once. Every helper
// below is named for them, because all `_test.v` files of this module share one
// namespace and a colliding name would break the build.
module main

import json2

// AssistTestSpan is one edit, resolved to the byte range it applies to.
struct AssistTestSpan {
	start    int
	end      int
	new_text string
}

// assists_test_app returns an App with nothing open, which is all the refactors
// read: each one works on the buffer it is handed.
fn assists_test_app() &App {
	return &App{
		text:       ''
		open_files: map[string]string{}
	}
}

// assists_test_position returns where the first `needle` of `content` sits.
fn assists_test_position(content string, needle string) Position {
	return assists_test_position_nth(content, needle, 0)
}

// assists_test_position_nth returns the position of the `nth` occurrence of
// `needle`, counting from zero, so a test can reach the second `math` in a file
// whose first is an import line, or the last `x` in a file that also declares a
// field called `x`.
fn assists_test_position_nth(content string, needle string, nth int) Position {
	mut seen := 0
	for line, text in content.split_into_lines() {
		mut from := 0
		for {
			col := text.index_after(needle, from) or { break }
			if seen == nth {
				return Position{
					line: line
					char: col
				}
			}
			seen++
			from = col + needle.len
		}
	}
	assert false, 'the fixture holds no occurrence ${nth} of ${needle}'
	return Position{}
}

// assists_test_range returns the range covering the first `needle` of `content`,
// what an editor reports for a selected token.
fn assists_test_range(content string, needle string) LSPRange {
	return assists_test_range_nth(content, needle, 0)
}

// assists_test_range_nth returns the range covering the `nth` occurrence of
// `needle`.
fn assists_test_range_nth(content string, needle string, nth int) LSPRange {
	at := assists_test_position_nth(content, needle, nth)
	return LSPRange{
		start: at
		end:   Position{
			line: at.line
			char: at.char + needle.len
		}
	}
}

// assists_test_span returns the range from the start of `from` to the end of
// `to`, what an editor reports when a selection is dragged across both.
fn assists_test_span(content string, from string, to string) LSPRange {
	start := assists_test_position(content, from)
	end := assists_test_position(content, to)
	return LSPRange{
		start: start
		end:   Position{
			line: end.line
			char: end.char + to.len
		}
	}
}

// assists_test_cursor returns the empty range an editor reports for a cursor
// sitting on the first `needle` of `content`.
fn assists_test_cursor(content string, needle string) LSPRange {
	at := assists_test_position(content, needle)
	return LSPRange{
		start: at
		end:   at
	}
}

// assists_test_cursor_nth returns the empty range of a cursor on the `nth`
// occurrence of `needle`.
fn assists_test_cursor_nth(content string, needle string, nth int) LSPRange {
	at := assists_test_position_nth(content, needle, nth)
	return LSPRange{
		start: at
		end:   at
	}
}

// assists_test_offset maps a position back to a byte offset, so a test can
// check an edit against the text it addresses.
fn assists_test_offset(content string, pos Position) int {
	return position_to_byte_offset(content, line_start_offsets(content), pos.line, pos.char,
		PositionEncoding.utf16)
}

// assists_test_apply applies the edits an action carries to `content`, from the
// last edit back, so the result is the document a client ends up with once the
// quick fix is taken.
fn assists_test_apply(content string, action CodeAction) string {
	edit := action.edit or {
		assert false, 'the action must carry an edit'
		return content
	}
	mut spans := []AssistTestSpan{}
	for _, edits in edit.changes {
		for one in edits {
			spans << AssistTestSpan{
				start:    assists_test_offset(content, one.range.start)
				end:      assists_test_offset(content, one.range.end)
				new_text: one.new_text
			}
		}
	}
	spans.sort_with_compare(fn (a &AssistTestSpan, b &AssistTestSpan) int {
		return b.start - a.start
	})
	mut out := content
	for span in spans {
		assert span.start <= span.end, 'an edit must not end before it starts'
		assert span.start >= 0 && span.end <= out.len, 'an edit must stay inside the document'
		out = out[..span.start] + span.new_text + out[span.end..]
	}
	return out
}

// assists_test_action runs a codeAction request over `sel` and returns the
// action titled `title`, or none when the server offers no such action. It goes
// through the real request handler, so a test also pins the registration and the
// kind filter.
fn assists_test_action(mut app App, uri string, content string, sel LSPRange, only []string, title string) ?CodeAction {
	app.open_files[uri] = content
	resp := app.handle_code_action(Request{
		id:     1
		params: json2.encode(CodeActionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			range:         sel
			context:       CodeActionContext{
				only: only
			}
		},
			escape_unicode: true
		)
	})
	if resp.result is []CodeAction {
		for action in resp.result as []CodeAction {
			if action.title == title {
				return action
			}
		}
	}
	return none
}

// --- Extract variable ---

// The commonest case: an expression that reads a local and passes it on. The
// selection becomes a fresh name, and the value it stood for is bound to that
// name in front of the statement that held it.
fn test_extract_variable_lifts_an_index_expression_out_of_a_call() {
	content := 'module main\n\nfn main() {\n\titems := [1, 2, 3]\n\tprintln(items[0])\n}\n'
	mut app := assists_test_app()
	action := app.build_extract_variable_action('file:///main.v', content, assists_test_range(content,
		'items[0]')) or {
		assert false, 'an index on a local must offer "Extract variable"'
		return
	}
	assert action.kind == code_action_kind_quickfix, 'the extraction is offered as a quick fix'
	assert assists_test_apply(content, action) == 'module main\n\nfn main() {\n\titems := [1, 2, 3]\n\tmut extracted_0 := items[0]\n\tprintln(extracted_0)\n}\n', 'the declaration is written above the statement and the selection is replaced'
}

// A call chain rooted in a local is pure, and so is the field access that leads
// to it: the method name is not the receiver, `name` is.
fn test_extract_variable_lifts_a_call_chain_on_a_local() {
	content := "module main\n\nfn main() {\n\tname := 'med'\n\tprintln(name.len())\n}\n"
	mut app := assists_test_app()
	action := app.build_extract_variable_action('file:///main.v', content, assists_test_range(content,
		'name.len()')) or {
		assert false, 'a call chain on a local must offer "Extract variable"'
		return
	}
	assert assists_test_apply(content, action) == "module main\n\nfn main() {\n\tname := 'med'\n\tmut extracted_0 := name.len()\n\tprintln(extracted_0)\n}\n", 'the chain is bound to the new name as it was written'
}

// A call chain on a parameter of the enclosing function counts as a local: a
// refusal there would refuse the commonest extraction of all.
fn test_extract_variable_accepts_a_chain_on_a_function_parameter() {
	content := "module main\n\nfn main() {\n\ttext := 'med'\n\tprintln(trim(text))\n}\n\nfn trim(input string) string {\n\treturn input.len()\n}\n"
	mut app := assists_test_app()
	action := app.build_extract_variable_action('file:///main.v', content, assists_test_range(content,
		'input.len()')) or {
		assert false, 'a chain on a parameter must offer "Extract variable"'
		return
	}
	assert assists_test_apply(content, action) == "module main\n\nfn main() {\n\ttext := 'med'\n\tprintln(trim(text))\n}\n\nfn trim(input string) string {\n\tmut extracted_0 := input.len()\n\treturn extracted_0\n}\n", 'the parameter chain is lifted into its own statement'
}

// A parenthesised expression of a pure form is pure, and a literal always is.
fn test_extract_variable_lifts_a_parenthesized_expression() {
	content := 'module main\n\nfn main() {\n\twidth := 8\n\tprintln((width))\n}\n'
	mut app := assists_test_app()
	action := app.build_extract_variable_action('file:///main.v', content, assists_test_range(content,
		'(width)')) or {
		assert false, 'a parenthesised identifier must offer "Extract variable"'
		return
	}
	assert assists_test_apply(content, action) == 'module main\n\nfn main() {\n\twidth := 8\n\tmut extracted_0 := (width)\n\tprintln(extracted_0)\n}\n', 'the parenthesised form is bound as it was written'
}

// The fresh name skips the bindings the buffer already holds, so the new name
// cannot capture an existing one.
fn test_extract_variable_takes_the_next_free_name() {
	content := 'module main\n\nfn main() {\n\textracted_0 := 1\n\titems := [1, 2, 3]\n\tprintln(items[0])\n}\n'
	mut app := assists_test_app()
	action := app.build_extract_variable_action('file:///main.v', content, assists_test_range(content,
		'items[0]')) or {
		assert false, 'a buffer already using the name must still offer the extraction'
		return
	}
	assert assists_test_apply(content, action) == 'module main\n\nfn main() {\n\textracted_0 := 1\n\titems := [1, 2, 3]\n\tmut extracted_1 := items[0]\n\tprintln(extracted_1)\n}\n', 'the new name is the first one the buffer does not use'
}

// A selection dragged across two statements holds two expressions and a line
// break: lifting it would rebuild the program it came from.
fn test_extract_variable_refuses_a_selection_that_spans_two_statements() {
	content := 'module main\n\nfn main() {\n\titems := [1, 2, 3]\n\tprintln(items[0])\n\tprintln(items)\n}\n'
	mut app := assists_test_app()
	sel := assists_test_span(content, 'println(items[0])', 'println(items)')
	assert app.build_extract_variable_action('file:///main.v', content, sel) == none, 'a selection spanning two statements must not be lifted'
}

// A cursor selects nothing, so there is nothing to bind.
fn test_extract_variable_refuses_an_empty_selection() {
	content := 'module main\n\nfn main() {\n\titems := [1, 2, 3]\n\tprintln(items[0])\n}\n'
	mut app := assists_test_app()
	assert app.build_extract_variable_action('file:///main.v', content, assists_test_cursor(content,
		'items[0]')) == none, 'a cursor must not offer an extraction'
}

// A call whose receiver is not a local runs code nobody can vouch for, and so
// does an expression built from an operator: neither is one of the pure forms.
fn test_extract_variable_refuses_an_expression_it_cannot_vouch_for() {
	content := 'module main\n\nfn main() {\n\ta := 1\n\tb := 2\n\tprintln(a + b)\n\tprintln(C.sqrt(2.0))\n\tprintln(a > b)\n}\n'
	mut app := assists_test_app()
	for needle in ['println(a + b)', 'C.sqrt(2.0)', 'a > b'] {
		assert app.build_extract_variable_action('file:///main.v', content, assists_test_range(content,
			needle)) == none, '`${needle}` is not a side-effect-free expression'
	}
}

// The left of an assignment is not a value: `mut extracted_0 := value` written
// in front of `value := f(value)` would read it before it is written.
fn test_extract_variable_refuses_the_left_of_an_assignment() {
	content := 'module main\n\nfn main() {\n\tvalue := 3\n\tprintln(value)\n}\n'
	mut app := assists_test_app()
	assert app.build_extract_variable_action('file:///main.v', content, assists_test_range(content,
		'value')) == none, 'the target of a declaration must not be lifted'
}

// A statement that does not begin its own line cannot have a declaration
// inserted in front of it: the only place to write one is inside the enclosing
// block, which V has no syntax for.
fn test_extract_variable_refuses_a_statement_that_does_not_begin_its_line() {
	content := 'module main\n\nfn main() {\n\titems := [1, 2, 3]\n\tif items[0] == 1 { println(items[0]) }\n}\n'
	mut app := assists_test_app()
	assert app.build_extract_variable_action('file:///main.v', content, assists_test_range(content,
		'println(items[0])')) == none, 'a statement opening inside braces must not be lifted'
}

// The base of a longer selector is a value only when it is a local: `math` names
// a module, and no variable holds one.
fn test_extract_variable_refuses_a_selector_whose_base_is_a_module() {
	content := 'module main\n\nimport math\n\nfn main() {\n\tx := math.pi\n\tprintln(x)\n}\n'
	mut app := assists_test_app()
	assert app.build_extract_variable_action('file:///main.v', content, assists_test_range_nth(content,
		'math', 1)) == none, 'the module half of `math.pi` must not be lifted'
}

// Through the request handler the action is registered as a quick fix, and a
// client asking only for some other kind is not sent it.
fn test_extract_variable_is_offered_as_a_quickfix_only() {
	content := 'module main\n\nfn main() {\n\titems := [1, 2, 3]\n\tprintln(items[0])\n}\n'
	mut app := assists_test_app()
	uri := 'file:///main.v'
	sel := assists_test_range(content, 'items[0]')
	assists_test_action(mut app, uri, content, sel, ['quickfix'], 'Extract variable') or {
		assert false, 'a client asking for quick fixes must see the extraction'
		return
	}
	assert assists_test_action(mut app, uri, content, sel, ['refactor'], 'Extract variable') == none, 'a client asking only for refactors must not be sent a quick fix'
}

// --- Inline variable ---

// A local written once folds back into its uses: the declaration line goes and
// the expression takes its place at every use.
fn test_inline_variable_folds_every_use_of_a_local() {
	content := 'module main\n\nfn main() {\n\ttotal := 3\n\tprintln(total)\n\tprintln(total + 1)\n}\n'
	mut app := assists_test_app()
	action := app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'total')) or {
		assert false, 'a local written once must offer "Inline variable"'
		return
	}
	assert action.kind == code_action_kind_quickfix, 'the inlining is offered as a quick fix'
	assert assists_test_apply(content, action) == 'module main\n\nfn main() {\n\tprintln(3)\n\tprintln(3 + 1)\n}\n', 'the declaration line is removed and each use becomes the expression'
}

// Exactly one use is the smallest case: the same two edits, and no declaration
// left behind.
fn test_inline_variable_replaces_a_single_use() {
	content := 'module main\n\nfn main() {\n\tlimit := 10\n\tprintln(limit)\n}\n'
	mut app := assists_test_app()
	action := app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'limit')) or {
		assert false, 'a local with one use must offer "Inline variable"'
		return
	}
	assert assists_test_apply(content, action) == 'module main\n\nfn main() {\n\tprintln(10)\n}\n', 'a single use is replaced and no declaration is left'
}

// A second writing of the name cannot be reordered past the declaration the
// edit removes, so the action is refused.
fn test_inline_variable_refuses_a_later_assignment() {
	content := 'module main\n\nfn main() {\n\tcount := 1\n\tcount = 2\n\tprintln(count)\n}\n'
	mut app := assists_test_app()
	assert app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'count')) == none, 'a local that is assigned again must not be inlined'
}

// A name that was never declared with `:=` is not this refactor's subject.
fn test_inline_variable_refuses_a_name_that_is_never_declared() {
	content := 'module main\n\nfn main() {\n\tprintln(missing)\n}\n'
	mut app := assists_test_app()
	assert app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'missing')) == none, 'a name with no declaration must not be inlined'
}

// `a, b := 1, 2` does not bind `a` alone, so there is no expression to fold in.
fn test_inline_variable_refuses_a_multi_target_declaration() {
	content := 'module main\n\nfn main() {\n\ta, b := 1, 2\n\tprintln(a)\n}\n'
	mut app := assists_test_app()
	assert app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'a')) == none, 'a declaration with several targets must not be inlined'
}

// An expression that mentions the name being removed would keep a reference to a
// binding that no longer exists.
fn test_inline_variable_refuses_an_expression_that_names_itself() {
	content := 'module main\n\nfn main() {\n\tn := 2\n\tn := n * 2\n\tprintln(n)\n}\n'
	mut app := assists_test_app()
	assert app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'n')) == none, 'a declaration naming itself must not be inlined'
}

// The whole line is deleted, so a comment on it would be deleted with it.
fn test_inline_variable_refuses_a_declaration_with_a_trailing_comment() {
	content := 'module main\n\nfn main() {\n\tcount := 1 // how many\n\tprintln(count)\n}\n'
	mut app := assists_test_app()
	assert app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'count')) == none, 'a declaration carrying a comment must not be inlined'
}

// A local nothing uses has nothing to fold into.
fn test_inline_variable_refuses_a_local_nothing_uses() {
	content := 'module main\n\nfn main() {\n\tunused := 1\n\tprintln(2)\n}\n'
	mut app := assists_test_app()
	assert app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'unused')) == none, 'a local with no use must not be inlined'
}

// The same name elsewhere in the file belongs to something else: a field of
// another object, a field initialiser, and a local of another function all keep
// their name.
fn test_inline_variable_leaves_a_field_and_another_scope_alone() {
	content := 'module main\n\nstruct Box {\n\twidth int\n}\n\nfn main() {\n\twidth := 5\n\tbox := Box{width: 1}\n\tprintln(box.width)\n\tprintln(width)\n}\n\nfn other() {\n\tprintln(width)\n}\n'
	mut app := assists_test_app()
	action := app.build_inline_variable_action('file:///main.v', content, assists_test_cursor_nth(content,
		'width', 4)) or {
		assert false, 'a local beside a field of the same name must still be inlined'
		return
	}
	assert assists_test_apply(content, action) == 'module main\n\nstruct Box {\n\twidth int\n}\n\nfn main() {\n\tbox := Box{width: 1}\n\tprintln(box.width)\n\tprintln(5)\n}\n\nfn other() {\n\tprintln(width)\n}\n', 'the field, the initialiser and the other scope keep the name'
}

// A same-named local in another function is another scope: the block of the
// declaration ends at its closing brace, so a use below that isn't the local's.
fn test_inline_variable_stays_inside_the_block_that_declared_it() {
	content := 'module main\n\nfn main() {\n\ttotal := 3\n\tprintln(total)\n}\n\nfn other() {\n\tprintln(total)\n}\n'
	mut app := assists_test_app()
	action := app.build_inline_variable_action('file:///main.v', content, assists_test_cursor(content,
		'total')) or {
		assert false, 'a local must offer "Inline variable"'
		return
	}
	assert assists_test_apply(content, action) == 'module main\n\nfn main() {\n\tprintln(3)\n}\n\nfn other() {\n\tprintln(total)\n}\n', 'a use outside the declaring block is left alone'
}

// Through the request handler the action is registered as a quick fix, and a
// client asking only for some other kind is not sent it.
fn test_inline_variable_is_offered_as_a_quickfix_only() {
	content := 'module main\n\nfn main() {\n\tlimit := 10\n\tprintln(limit)\n}\n'
	mut app := assists_test_app()
	uri := 'file:///main.v'
	sel := assists_test_cursor(content, 'limit')
	assists_test_action(mut app, uri, content, sel, ['quickfix'], 'Inline variable') or {
		assert false, 'a client asking for quick fixes must see the inlining'
		return
	}
	assert assists_test_action(mut app, uri, content, sel, ['refactor'], 'Inline variable') == none, 'a client asking only for refactors must not be sent a quick fix'
}
