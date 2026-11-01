// Fast, compiler-free diagnostics: unknown-import resolvability.
// The slow compiler check stays authoritative: a fast error the slow
// check does not reproduce is cleared when the slow answer publishes,
// since every publishDiagnostics replaces the file's diagnostics.
module main

import os
import time

// ImportRef is one module path an `import` statement takes, with its
// 0-based position for diagnostics.
struct ImportRef {
	line int // 0-based line of the import
	col  int // 0-based byte column where the module path starts
	path string
}

// parse_import_refs extracts module paths with positions from the
// `import` statements in `content`. It mirrors parse_imports, which
// delegates to it, so the two can never disagree.
fn parse_import_refs(content string) []ImportRef {
	mut refs := []ImportRef{}
	mut in_import_block := false
	for i, line in content.split_into_lines() {
		trimmed := line.trim_space()
		if in_import_block {
			if trimmed.starts_with(')') {
				in_import_block = false
				continue
			}
			parts := trimmed.all_before('//').fields()
			if parts.len > 0 {
				pos := line.index(parts[0]) or { -1 }
				if pos >= 0 {
					refs << ImportRef{
						line: i
						col:  pos
						path: parts[0]
					}
				}
			}
			continue
		}
		if !trimmed.starts_with('import ') {
			continue
		}
		rest := trimmed[7..].all_before('//').trim_space()
		if rest == '(' {
			in_import_block = true
			continue
		}
		// Strip optional `as alias` suffix
		parts := rest.fields()
		if parts.len > 0 {
			indent := line.len - trimmed.len
			offset := rest.index(parts[0]) or { 0 }
			refs << ImportRef{
				line: i
				col:  indent + 7 + offset
				path: parts[0]
			}
		}
	}
	return refs
}

// fast_import_is_skipped reports the paths that are never flagged: `C` is
// C interop, and a path with grouping or quoting characters is a construct
// this scan does not understand, so the slow check decides.
fn fast_import_is_skipped(path string) bool {
	if path == '' || path == 'C' {
		return true
	}
	for c in path {
		if c == `(` || c == `)` || c == `{` || c == `}` || c == `[` || c == `]` || c == `"`
			|| c == `'` {
			return true
		}
	}
	return false
}

// fast_module_dir_declares reports whether `dir` holds the module
// `name`: its V files declare the module named after the folder,
// which is not `main`. This mirrors collect_importable_modules.
fn fast_module_dir_declares(dir string, name string) bool {
	if name == '' || name == 'main' {
		return false
	}
	if !os.is_dir(dir) {
		return false
	}
	return declared_module_of_dir(dir) == name
}

// fast_check_errors returns one error per import of `content` that
// resolves nowhere: not under the project bases, vlib, or vmodules.
// An import of the file's own folder needs no import and is skipped.
// The message matches the compiler's wording so the existing
// "Remove unknown import" quick fix fires on fast results too.
fn (app &App) fast_check_errors(uri string, content string) []JsonError {
	refs := parse_import_refs(content)
	if refs.len == 0 {
		return []
	}
	real_path := uri_to_path(uri)
	file_dir := os.dir(real_path)
	own_dir := normalize_overlay_path(os.real_path(file_dir))
	vmod_root := find_project_root(file_dir)
	program_dir := app.program_root(real_path)
	// V resolves a project import against the importing file's folder, the
	// v.mod root, and the program folder, so every one is a base.
	mut bases := []string{}
	for base in [vmod_root, file_dir, program_dir] {
		if base != '' && base !in bases {
			bases << base
		}
	}
	v_dir := find_v_dir()
	vlib := if v_dir != '' { os.join_path(v_dir, 'vlib') } else { '' }
	vmodules := os.vmodules_paths()
	mut errors := []JsonError{}
	for ref in refs {
		if fast_import_is_skipped(ref.path) {
			continue
		}
		name := ref.path.split('.').last()
		rel := ref.path.replace('.', os.path_separator)
		mut resolves := false
		for base in bases {
			candidate := os.join_path(base, rel)
			if normalize_overlay_path(candidate) == own_dir {
				resolves = true
				break
			}
			if fast_module_dir_declares(candidate, name) {
				resolves = true
				break
			}
		}
		if !resolves && vlib != '' {
			resolves = fast_module_dir_declares(os.join_path(vlib, rel), name)
		}
		if !resolves {
			for dir in vmodules {
				if fast_module_dir_declares(os.join_path(dir, rel), name) {
					resolves = true
					break
				}
			}
		}
		if resolves {
			continue
		}
		// JsonError positions are 1-based (see v_error_to_lsp_diagnostic).
		errors << JsonError{
			path:    real_path
			message: "unknown module '${ref.path}'"
			line_nr: ref.line + 1
			col:     ref.col + 1
			len:     ref.path.len
			level:   'error'
		}
	}
	return errors
}

// FastParseBracket is one unclosed opening delimiter with its 0-based position.
struct FastParseBracket {
	ch   u8
	line int // 0-based line of the opener
	col  int // 0-based byte column of the opener
}

// FastParseInterp is one `${` interpolation whose string is suspended while its
// code is scanned, with the 0-based position of the `$`.
struct FastParseInterp {
	quote u8
	line  int
	col   int
mut:
	brace_depth int
}

// FastParseState is the scanner state for fast_parse_errors. It mirrors the
// discipline of OccurrenceScanState in index.v: nested block comments, line
// comments, single, double and backtick strings, raw and C strings, escapes,
// and `${` interpolation. Bracket depth is tracked only in code, so brackets
// inside comments, strings and rune literals never count.
struct FastParseState {
mut:
	block_comment_depth int
	block_comment_line  int
	block_comment_col   int
	quote               u8
	quote_line          int
	quote_col           int
	raw_string          bool
	interpolations      []FastParseInterp
	stack               []FastParseBracket
}

// fast_scan_literal scans a string or rune literal from `start`, skipping its
// text the way scan_literal_identifier_occurrences does. A `${` suspends the
// literal and scans the interpolation as code. It returns the byte after the
// closing quote, the matching `}` resume point, or the end of the line for a
// literal that stays open.
fn fast_scan_literal(line_text string, line_idx int, start int, path string, mut state FastParseState, mut errors []JsonError) int {
	mut col := start
	if state.quote == 0 {
		state.quote = line_text[start]
		state.quote_line = line_idx
		state.quote_col = start
		col++
	}
	quote := state.quote
	for col < line_text.len {
		if line_text[col] == `\\` && !state.raw_string {
			col += 2
			continue
		}
		if line_text[col] == quote {
			state.quote = 0
			state.raw_string = false
			return col + 1
		}
		if !state.raw_string && line_text[col] == `$` && col + 1 < line_text.len
			&& line_text[col + 1] == `{` {
			state.quote = 0
			state.interpolations << FastParseInterp{
				quote: quote
				line:  line_idx
				col:   col
			}
			return fast_scan_code(line_text, line_idx, col + 2, path, mut state, mut errors)
		}
		col++
	}
	return col
}

// fast_scan_code scans code from `start` to the end of the line, tracking
// bracket depth the way scan_code_identifier_occurrences tracks token context.
// A closer with an empty stack is certain no matter what the user types next,
// so it reports at once. A closer that mismatches the open top is uncertain
// mid-keystroke, so the slow check decides and the stack is left alone.
fn fast_scan_code(line_text string, line_idx int, start int, path string, mut state FastParseState, mut errors []JsonError) int {
	mut col := start
	for col < line_text.len {
		if state.quote != 0 {
			col = fast_scan_literal(line_text, line_idx, col, path, mut state, mut errors)
			continue
		}
		c := line_text[col]
		if state.block_comment_depth > 0 {
			if col + 1 < line_text.len && c == `/` && line_text[col + 1] == `*` {
				state.block_comment_depth++
				col += 2
				continue
			}
			if col + 1 < line_text.len && c == `*` && line_text[col + 1] == `/` {
				state.block_comment_depth--
				col += 2
				continue
			}
			col++
			continue
		}
		if col + 1 < line_text.len && c == `/` && line_text[col + 1] == `/` {
			return line_text.len
		}
		if col + 1 < line_text.len && c == `/` && line_text[col + 1] == `*` {
			state.block_comment_depth = 1
			state.block_comment_line = line_idx
			state.block_comment_col = col
			col += 2
			continue
		}
		if c in [`r`, `c`] && col + 1 < line_text.len
			&& (line_text[col + 1] == `"` || line_text[col + 1] == `'`) {
			state.raw_string = c == `r`
			col = fast_scan_literal(line_text, line_idx, col + 1, path, mut state, mut errors)
			continue
		}
		if c == `"` || c == `'` || c == 96 {
			col = fast_scan_literal(line_text, line_idx, col, path, mut state, mut errors)
			continue
		}
		if c == `(` || c == `[` || c == `{` {
			if c == `{` && state.interpolations.len > 0 {
				last := state.interpolations.len - 1
				state.interpolations[last].brace_depth++
			}
			state.stack << FastParseBracket{
				ch:   c
				line: line_idx
				col:  col
			}
			col++
			continue
		}
		if c == `)` || c == `]` || c == `}` {
			if c == `}` && state.interpolations.len > 0 {
				last := state.interpolations.len - 1
				if state.interpolations[last].brace_depth == 0 {
					interp := state.interpolations.pop()
					state.quote = interp.quote
					col++
					continue
				}
				state.interpolations[last].brace_depth--
			}
			expected := if c == `)` {
				`(`
			} else if c == `]` {
				`[`
			} else {
				`{`
			}
			if state.stack.len == 0 {
				// JsonError positions are 1-based (see v_error_to_lsp_diagnostic).
				errors << JsonError{
					path:    path
					message: "unexpected token '${c.ascii_str()}'"
					line_nr: line_idx + 1
					col:     col + 1
					len:     1
					level:   'error'
				}
			} else if state.stack.last().ch == expected {
				state.stack.pop()
			}
			col++
			continue
		}
		col++
	}
	return col
}

// fast_last_non_empty returns the index of the last line holding non-space
// text, or -1 when there is none.
fn fast_last_non_empty(lines []string) int {
	for i := lines.len - 1; i >= 0; i-- {
		if lines[i].trim_space() != '' {
			return i
		}
	}
	return -1
}

// fast_last_line_is_continuation reports whether the last non-empty line may
// still be growing: it ends in an opener or an operator tail, or it holds a
// construct that is still unclosed at EOF. Flagging the file now would fire
// on mid-keystroke code, so the slow check decides instead.
fn fast_last_line_is_continuation(lines []string, last int, state &FastParseState) bool {
	for b in state.stack {
		if b.line == last {
			return true
		}
	}
	for interp in state.interpolations {
		if interp.line == last {
			return true
		}
	}
	line := lines[last].trim_space()
	if line == '' {
		return true
	}
	c := line[line.len - 1]
	return c in [`(`, `[`, `{`, `,`, `=`, `:`, `.`, `\\`, `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`,
		`!`, `<`, `>`, `?`, `$`, `~`]
}

// fast_parse_errors scans the edited file's buffer for certain delimiter
// mistakes: a closing delimiter with no opener, or an unclosed delimiter,
// string or block comment at EOF. It runs no compiler and reads no other
// file. An EOF remainder only reports when the last non-empty line is not an
// obvious continuation, and a backtick literal never reports: backtick strings
// may legally span lines, so an unclosed one at EOF is still being typed as
// far as this check can tell.
fn (app &App) fast_parse_errors(uri string, content string) []JsonError {
	real_path := uri_to_path(uri)
	mut state := FastParseState{}
	mut errors := []JsonError{}
	lines := content.split_into_lines()
	for line_idx, line_text in lines {
		fast_scan_code(line_text, line_idx, 0, real_path, mut state, mut errors)
	}
	last := fast_last_non_empty(lines)
	if last < 0 {
		return errors
	}
	if state.quote != 0 {
		if state.quote != 96 && state.quote_line < last {
			errors << JsonError{
				path:    real_path
				message: 'unclosed string literal'
				line_nr: state.quote_line + 1
				col:     state.quote_col + 1
				len:     1
				level:   'error'
			}
		}
		return errors
	}
	if state.block_comment_depth > 0 {
		if state.block_comment_line < last {
			errors << JsonError{
				path:    real_path
				message: 'unclosed block comment'
				line_nr: state.block_comment_line + 1
				col:     state.block_comment_col + 1
				len:     2
				level:   'error'
			}
		}
		return errors
	}
	if state.interpolations.len > 0 {
		interp := state.interpolations.last()
		if !fast_last_line_is_continuation(lines, last, &state) {
			errors << JsonError{
				path:    real_path
				message: 'unclosed string interpolation'
				line_nr: interp.line + 1
				col:     interp.col + 1
				len:     2
				level:   'error'
			}
		}
		return errors
	}
	if state.stack.len > 0 {
		if fast_last_line_is_continuation(lines, last, &state) {
			return errors
		}
		first := state.stack.first()
		errors << JsonError{
			path:    real_path
			message: "unclosed delimiter '${first.ch.ascii_str()}'"
			line_nr: first.line + 1
			col:     first.col + 1
			len:     1
			level:   'error'
		}
	}
	return errors
}

// run_fast_diagnostics_job answers a fast job: import and parse errors from
// the edited buffer only, no compiler, no temp copy. An empty fast answer
// publishes nothing: the slow check publishes the file's full state, which
// also clears a fast error it does not repeat.
fn run_fast_diagnostics_job(mut scheduler DiagnosticsScheduler, job DiagnosticsJob) {
	if !scheduler.is_job_current(job) {
		return
	}
	started_ms := time.now().unix_milli()
	mut versions := map[string]i64{}
	if version := job.version {
		versions[job.uri] = version
	}
	mut worker := App{
		open_files:          job.open_files
		open_files_versions: versions
		position_encoding:   job.position_encoding
		write_mutex:         job.write_mutex
		tcp_conn:            job.tcp_conn
		diagnostics_enabled: true
	}
	mut errors := worker.fast_check_errors(job.uri, job.content)
	errors << worker.fast_parse_errors(job.uri, job.content)
	if errors.len == 0 {
		return
	}
	notification := worker.diagnostics_notification_for(job.uri, job.content, errors)
	scheduler.publish_if_current(mut worker, job, notification)
	if os.getenv('VLS_PERF_LOG') != '' {
		fast_elapsed_ms := time.now().unix_milli() - started_ms
		worker.send_log_message('diagnostics uri=${job.uri} kind=fast elapsed_ms=${fast_elapsed_ms}',
			4)
	}
}
