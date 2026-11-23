module main

import os
import time
import v.vmod

// The fast tier checks only source shapes for which it has enough information.
// Full compiler diagnostics still run for every edit, including the cases here.
const fast_type_max_file_bytes = 256 * 1024
const fast_type_max_scope_bytes = 4 * 1024 * 1024
const fast_type_max_files = 256
const fast_type_max_uses = 32
const fast_type_builtin_ttl_ms = 10_000

struct FastTypeBuiltin {
	dir     string
	read_at i64
	names   map[string]bool
}

struct FastValueUse {
	name string
	line int
	col  int
}

fn fast_type_identifier(value string) bool {
	return is_valid_v_identifier_name(value)
		&& value !in ['_', 'it', 'err', 'none', 'nil', 'true', 'false']
		&& value !in v_keywords && value !in v_builtin_types
}

// fast_call_open accepts a statement whose whole expression is a plain call.
// Selectors, function expressions and complex assignment targets need compiler
// scope information.
fn fast_call_open(code string) int {
	open := code.index('(') or { return -1 }
	mut head := code[..open].trim_space()
	if assignment := head.index(':=') {
		target := head[..assignment].trim_space().trim_string_left('mut ')
		if !fast_type_identifier(target) {
			return -1
		}
		head = head[assignment + 2..].trim_space()
	}
	head = head.trim_string_left('return ')
	return if fast_type_identifier(head) { open } else { -1 }
}

// fast_type_uses finds bare arguments. If the same spelling occurs anywhere
// else in the file, it may be a local, parameter, selective import or constant.
// Let the compiler resolve it together with its scope.
fn fast_type_uses(content string, lines []string, code_lines []string) []FastValueUse {
	mut uses := []FastValueUse{}
	mut line_start := 0
	mut checked := 0
	for line, code in code_lines {
		start := line_start
		line_start += code.len + 1
		open := fast_call_open(code)
		if open < 0 {
			continue
		}
		close := matching_delimiter(code, open, `(`, `)`)
		if close < 0 || code[close + 1..].trim_space() != '' {
			continue
		}
		mut part_start := open + 1
		for part in split_top_level_commas(code[open + 1..close]) {
			part_end := part_start + part.len
			name := part.trim_space()
			if fast_type_identifier(name) && lines[line][part_start..part_end].trim_space() == name {
				if checked == fast_type_max_uses {
					return uses
				}
				checked++
				col := part_start + (part.index(name) or { 0 })
				if !content[..start + col].contains(name)
					&& !content[start + col + name.len..].contains(name) {
					uses << FastValueUse{ name: name, line: line, col: col }
				}
			}
			part_start = part_end + 1
		}
	}
	return uses
}

// fast_return_types compares a complete scalar literal with a function's
// explicit scalar return type. Nested blocks may include their own functions.
fn fast_return_types(path string, lines []string, code_lines []string) []JsonError {
	mut errors := []JsonError{}
	mut depth := 0
	mut expected := ''
	for i, code in code_lines {
		head := code.trim_space().trim_string_left('pub ')
		if depth == 0 {
			expected = ''
			if head.starts_with('fn ') && head.ends_with('{') {
				open := head.index('(') or { -1 }
				close := matching_delimiter(head, open, `(`, `)`)
				if close >= 0 {
					expected = head[close + 1..head.len - 1].trim_space()
				}
			}
		} else if depth == 1 && (head == 'return' || head.starts_with('return '))
			&& expected in ['int', 'bool', 'string'] {
			byte_col := (code.index('return') or { continue }) + 'return'.len
			value := lines[i][byte_col..].trim_space()
			actual, len := receiver_scalar_literal(value) or { '', 0 }
			// V allows numeric coercions. Report only incompatible scalar kinds.
			if actual != '' && actual != expected
				&& (expected != 'int' || actual in ['bool', 'string'])
				&& (actual !in ['int', 'f64'] || fast_decimal_literal(value[..len]))
				&& !fast_return_continues(code_lines, i + 1) {
				col := byte_col + (lines[i][byte_col..].index(value) or { 0 })
				errors << JsonError{
					path:    path
					message: 'cannot return `${actual}` from a function returning `${expected}`'
					line_nr: i + 1
					col:     col + 1
					len:     len
					level:   'error'
				}
			}
		}
		for c in code {
			if c == `{` {
				depth++
			} else if c == `}` {
				depth--
			}
		}
	}
	return errors
}

// The receiver helper also accepts approximate numeric types for completion.
// Diagnostics use only decimal tokens with a shape that proves their type.
fn fast_decimal_literal(token string) bool {
	digits := token.trim_string_left('-')
	if digits.len == 0 || !digits[0].is_digit() || !digits[digits.len - 1].is_digit() {
		return false
	}
	mut dots := 0
	for c in digits {
		if c == `.` {
			dots++
		} else if !c.is_digit() {
			return false
		}
	}
	return dots <= 1
}

fn fast_return_continues(code_lines []string, next int) bool {
	for i in next .. code_lines.len {
		line := code_lines[i].trim_space()
		if line != '' {
			return line[0] in [`.`, `[`, `(`, `+`, `-`, `*`, `/`, `%`, `=`, `!`, `<`, `>`, `&`,
				`|`, `^`]
		}
	}
	return false
}

// An unresolved-name diagnostic needs the whole module's names. When a
// directory exceeds the work budget or cannot be read, defer to the compiler.
fn (app &App) fast_type_sibling_sources(uri string) ?[]string {
	target := normalized_index_path(uri_to_path(uri))
	dir := os.dir(target)
	// A manifest can add files from outside the edited file's directory.
	root := find_project_root(dir)
	if root != '' {
		manifest := vmod.from_file(os.join_path(root, 'v.mod')) or { return none }
		if manifest.base_url != '' || 'subdirs' in manifest.unknown {
			return none
		}
	}
	entries := os.ls(dir) or { return none }
	mut open := map[string]string{}
	for open_uri, text in app.open_files {
		if open_uri == uri {
			continue
		}
		path := normalized_index_path(uri_to_path(open_uri))
		if path != target && os.dir(path) == dir && path.ends_with('.v') {
			open[path] = text
		}
	}
	mut sources := []string{}
	mut bytes := u64(0)
	for entry in entries {
		if entry.ends_with('.vh') {
			return none
		}
		if !entry.ends_with('.v') {
			continue
		}
		path := os.join_path(dir, entry)
		if normalize_overlay_path(path) == normalize_overlay_path(target)
			|| (open.len > 0 && normalized_index_path(path) in open) {
			continue
		}
		info := os.stat(path) or { return none }
		if sources.len >= fast_type_max_files || info.get_filetype() != .regular
			|| info.size > fast_type_max_file_bytes || bytes + info.size > fast_type_max_scope_bytes {
			return none
		}
		text := os.read_file(path) or { return none }
		bytes += u64(text.len)
		if bytes > fast_type_max_scope_bytes {
			return none
		}
		sources << text
	}
	for _, text in open {
		bytes += u64(text.len)
		if sources.len >= fast_type_max_files || bytes > fast_type_max_scope_bytes {
			return none
		}
		sources << text
	}
	return sources
}

// Store identifier spellings once, including those in comments and strings.
// The fast check needs only absence from the compiler's builtin module.
fn record_fast_builtin_names(text string, mut names map[string]bool) {
	mut start := 0
	for start < text.len {
		if !is_ident_start(text[start]) {
			start++
			continue
		}
		mut end := start + 1
		for end < text.len && is_ident_char(text[end]) {
			end++
		}
		names[text[start..end]] = true
		start = end
	}
}

fn (mut scheduler DiagnosticsScheduler) fast_type_builtin_names() ?FastTypeBuiltin {
	v_dir := find_v_dir()
	now := time.now().unix_milli()
	if v_dir == '' {
		scheduler.fast_type_builtin = FastTypeBuiltin{ read_at: now }
		return none
	}
	dir := os.join_path(v_dir, 'vlib', 'builtin')
	cached := scheduler.fast_type_builtin
	if cached.dir == dir && now - cached.read_at < fast_type_builtin_ttl_ms {
		return if cached.names.len > 0 { cached } else { none }
	}
	// Cache failed attempts too. An unusual or incomplete installation should
	// go to the compiler without rescanning builtin for each keystroke.
	scheduler.fast_type_builtin = FastTypeBuiltin{ dir: dir, read_at: now }
	entries := os.ls(dir) or { return none }
	mut names := map[string]bool{}
	mut bytes := u64(0)
	mut files := 0
	for entry in entries {
		if !entry.ends_with('.v') || entry.ends_with('_test.v') {
			continue
		}
		path := os.join_path(dir, entry)
		info := os.stat(path) or { return none }
		if info.get_filetype() != .regular || files >= fast_type_max_files
			|| bytes + info.size > fast_type_max_scope_bytes {
			return none
		}
		text := os.read_file(path) or { return none }
		bytes += u64(text.len)
		if bytes > fast_type_max_scope_bytes {
			return none
		}
		record_fast_builtin_names(text, mut names)
		files++
	}
	scheduler.fast_type_builtin = FastTypeBuiltin{ dir: dir, read_at: now, names: names }
	return if names.len > 0 { scheduler.fast_type_builtin } else { none }
}

fn (app &App) fast_type_errors(uri string, content string, mut scheduler DiagnosticsScheduler) []JsonError {
	path := uri_to_path(uri)
	if !path.ends_with('.v') || path.ends_with('_test.v') || content.len > fast_type_max_file_bytes {
		return []
	}
	code := v_source_code_mask(content).bytestr()
	// Conditional and generated code is checked by V for the configured target.
	if code.contains_any('$#@') {
		return []
	}
	lines := content.split('\n')
	code_lines := code.split('\n')
	mut errors := fast_return_types(path, lines, code_lines)
	uses := fast_type_uses(content, lines, code_lines)
	if uses.len == 0 || os.getenv('VFLAGS').contains('-builtin')
		|| os.getenv('VFLAGS').contains('-path') {
		return errors
	}
	siblings := app.fast_type_sibling_sources(uri) or { return errors }
	if siblings.any(it.contains('$for') || it.contains('#include')) {
		return errors
	}
	builtins := scheduler.fast_type_builtin_names() or { return errors }
	for use in uses {
		if siblings.any(it.contains(use.name)) || use.name in builtins.names {
			continue
		}
		errors << JsonError{
			path:    path
			message: 'undefined variable: `${use.name}`'
			line_nr: use.line + 1
			col:     use.col + 1
			len:     use.name.len
			level:   'error'
		}
	}
	return errors
}
