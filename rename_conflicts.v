module main

import os

// A rename edits every occurrence of the symbol and nothing else, and the
// program can still change: the new name may be declared already, where the
// renamed declaration is or around it. V then reports the clash, warns about
// it, or says nothing while a use comes to name the other declaration.
// check_rename_conflicts renames in the copy of the program that V answers
// questions in, checks it, and asks again where each occurrence of the old and
// the new name leads: the rename is refused when the check reports an error or
// a warning that it did not before, or when an occurrence would name another
// declaration than it does now, or one that the rename makes.

// NamePos is a position in a file: its path, a 0-based line and a byte column.
struct NamePos {
	path string
	line int
	col  int
}

// RenameSpan is an occurrence that a rename edits: the bytes of the old name
// on a line of a file, and where it leads now, when the rename asked V.
struct RenameSpan {
	line  int
	start int
	end   int
	knows bool
	led   NamePos
}

// RenameCheck is what check_rename_conflicts compares: the names, the
// occurrences the rename edits by file, and the occurrences of the new name
// that the program has already.
struct RenameCheck {
	old_name string
	new_name string
	spans    map[string][]RenameSpan
	existing []NamePos
	uris     map[string]string
}

// check_rename_conflicts refuses the rename of `target` to `new_name` at
// `locations` when it would change the program (see above). `cache` holds
// where the rename found that the occurrences lead.
fn (mut app App) check_rename_conflicts(target RenameTarget, locations []Location, new_name string, scope IndexScope, cache map[string]?Location) ! {
	mut spans := map[string][]RenameSpan{}
	mut uris := map[string]string{}
	for loc in locations {
		path := normalize_overlay_path(uri_to_path(loc.uri))
		line := loc.range.start.line
		start := app.client_col_to_byte_col(loc.uri, line, loc.range.start.char)
		key := anchor_cache_key(loc.uri, line, loc.range.start.char)
		mut span := RenameSpan{
			line:  line
			start: start
			end:   start + target.symbol.len
		}
		for asked in [key, 'once:' + key] {
			if led := cache[asked] {
				span = RenameSpan{
					...span
					knows: true
					led:   app.name_pos_of(led)
				}
				break
			}
		}
		spans[path] << span
		uris[path] = loc.uri
	}
	for path in spans.keys() {
		mut sorted := spans[path].clone()
		sorted.sort_with_compare(fn (a &RenameSpan, b &RenameSpan) int {
			return if a.line != b.line { a.line - b.line } else { a.start - b.start }
		})
		spans[path] = sorted
	}
	mut existing := []NamePos{}
	for loc in app.collect_semantic_candidates(new_name, scope) {
		path := normalize_overlay_path(uri_to_path(loc.uri))
		line := loc.range.start.line
		existing << NamePos{
			path: path
			line: line
			col:  app.client_col_to_byte_col(loc.uri, line, loc.range.start.char)
		}
		uris[path] = loc.uri
	}
	rc := RenameCheck{
		old_name: target.symbol
		new_name: new_name
		spans:    spans
		existing: existing
		uris:     uris
	}
	// The files of a program are checked together, each program apart.
	mut programs := map[string][]string{}
	for path, _ in uris {
		programs[app.program_root(path)] << path
	}
	for dir, paths in programs {
		if reason := app.rename_clash_in(dir, paths, rc) {
			return error('renaming `${target.symbol}` to `${new_name}` would ${reason}')
		}
	}
}

// rename_clash_in returns how the rename `rc` would change the program in
// `program_dir`, whose files at `paths` it edits or holds the new name, or
// none when it would not, or when V cannot tell.
fn (mut app App) rename_clash_in(program_dir string, paths []string, rc RenameCheck) ?string {
	mut project := app.v3_query_project(paths[0], program_dir) or { return none }
	app.v3_sync_open_files(mut project)
	// The copy is kept for the questions that come later, as v3_ask keeps it, with
	// the files it held before the rename (see the deferred writes below).
	defer {
		app.v3_query_projects[program_dir] = project
	}
	mut originals := map[string]string{}
	mut copies := map[string]string{}
	for path in paths {
		text := app.open_files[rc.uris[path]] or { os.read_file(path) or { return none } }
		originals[path] = text
		copies[path] = project.write(path, text) or { return none }
	}
	// V builds a test file as a program of its own, with the files of its module.
	mut targets := ['.']
	for path in paths {
		if copies[path].ends_with('_test.v') && copies[path] !in targets {
			targets << copies[path]
		}
	}
	existing := rc.existing.filter(it.path in copies)
	mut before := []string{}
	for target in targets {
		before << check_messages(app.v3_check_copy(project, target)?)
	}
	named_before := app.rename_answers(project, existing.map(NamePos{
		...it
		path: copies[it.path]
	}), rc.new_name.len)
	// The copy holds the renamed files until the answers are in.
	for path, spans in rc.spans {
		if path in copies {
			project.write(path, renamed_text(originals[path], spans, rc.new_name)) or {
				return none
			}
		}
	}
	defer {
		for path, _ in rc.spans {
			if path in copies {
				project.write(path, originals[path]) or {}
			}
		}
	}
	mut after := []string{}
	for target in targets {
		after << check_messages(app.v3_check_copy(project, target)?)
	}
	if message := new_check_message(before, after) {
		return message
	}
	// Where each occurrence leads once renamed: where it led before.
	mut renamed := []RenameSpan{}
	mut asked := []NamePos{}
	for path, spans in rc.spans {
		if path !in copies {
			continue
		}
		for span in spans {
			renamed << span
			asked << NamePos{
				path: path
				line: span.line
				col:  rc.renamed_col(path, span.line, span.start)
			}
		}
	}
	for pos in existing {
		asked << NamePos{
			...pos
			col: rc.renamed_col(pos.path, pos.line, pos.col)
		}
	}
	named_after := app.rename_answers(project, asked.map(NamePos{
		...it
		path: copies[it.path]
	}), rc.new_name.len)
	if named_after.len != asked.len {
		return none
	}
	for i, answer in named_after {
		named := answer or { continue }
		was := rc.original_pos(named)
		at := rc.original_pos(asked[i])
		if i < renamed.len {
			led := renamed[i].led
			if renamed[i].knows && !same_name_pos(was, led) {
				return 'make `${rc.new_name}` at ${name_pos_text(at)} name the declaration at ${name_pos_text(was)} instead of the one at ${name_pos_text(led)}'
			}
			continue
		}
		// An occurrence of the new name that the program has already.
		k := i - renamed.len
		if k >= named_before.len {
			continue
		}
		if led := named_before[k] {
			if !same_name_pos(was, led) {
				return 'make `${rc.new_name}` at ${name_pos_text(at)} name the declaration at ${name_pos_text(was)} instead of the one at ${name_pos_text(led)}'
			}
		} else if rc.is_renamed(was) {
			return 'make `${rc.new_name}` at ${name_pos_text(at)} name the renamed declaration at ${name_pos_text(was)}'
		}
	}
	return none
}

// v3_check_copy checks the program `target` of the copy `project`, `.` or a
// test file, as the checks of the diagnostics do, and returns what V printed.
// None when V could not check it.
fn (mut app App) v3_check_copy(project V3QueryProject, target string) ?string {
	is_library := target == '.' && !app.is_program_dir(project.overlay.source_work_dir)
	if exe := resolve_diagnostics_server_exe() {
		// The command line of the questions (see v3_run): the same server.
		mut args := v3_compiler_selection_args()
		if is_library {
			args << '-shared'
		}
		args << ['-check', '-nocolor', target]
		mut servers := app.v3_query_pool()
		if result := servers.check(exe, args, project.overlay.temp_work_dir, fn () bool {
			return false
		}) {
			return result.output
		}
	}
	if app.v3_one_shot_unsupported {
		return none
	}
	mut argv := ['-new-compiler', '-check', '-nocolor']
	if is_library {
		argv << '-shared'
	}
	argv << target
	return run_v_argv(argv, project.overlay.temp_work_dir).output
}

// rename_answers asks V where each name of `len` bytes at `positions`, paths of
// the copy `project`, leads: a position of the project for each, or none where
// V gives no answer. Nothing when V answered none of them.
fn (mut app App) rename_answers(project V3QueryProject, positions []NamePos, len int) []?NamePos {
	if positions.len == 0 {
		return []
	}
	// Two bytes into the name, or one for a short name: see anchor_probe_cols.
	probe := if len > 2 { 2 } else { 1 }
	mut answers := []?NamePos{len: positions.len, init: none}
	mut groups := map[string][]int{}
	for i, pos in positions {
		target := if pos.path.ends_with('_test.v') { pos.path } else { '.' }
		groups[target] << i
	}
	for target, group in groups {
		specs := group.map('${positions[it].path}:${positions[it].line + 1}:gd^${positions[it].col +
			probe}')
		output := app.v3_run(project, specs, target) or { continue }
		if group.len == 1 {
			answers[group[0]] = parse_name_pos(output.trim_space(), project.overlay)
			continue
		}
		for line in output.split_into_lines() {
			index_text := line.all_before('\t')
			if line.contains('\t') && index_text.is_int() {
				index := index_text.int()
				if index >= 0 && index < group.len {
					answers[group[index]] = parse_name_pos(line.all_after('\t').trim_space(),
						project.overlay)
				}
			}
		}
	}
	return answers
}

// parse_name_pos reads `file:line:col`, a definition that V answered in the
// copy `overlay`, as a position of the project.
fn parse_name_pos(answer string, overlay CompilationOverlay) ?NamePos {
	fields := answer.split(':')
	if answer == '' || fields.len < 3 || !fields[fields.len - 1].is_int()
		|| !fields[fields.len - 2].is_int() {
		return none
	}
	path := source_path_from_overlay(os.to_slash(fields[..fields.len - 2].join(':')), overlay)
	return NamePos{
		path: normalize_overlay_path(path)
		line: fields[fields.len - 2].int() - 1
		col:  fields[fields.len - 1].int()
	}
}

// renamed_text is `text` with the name at each of `spans`, sorted, renamed to
// `new_name`.
fn renamed_text(text string, spans []RenameSpan, new_name string) string {
	mut lines := text.split('\n')
	for i := spans.len - 1; i >= 0; i-- {
		span := spans[i]
		if span.line < 0 || span.line >= lines.len || span.end > lines[span.line].len {
			continue
		}
		line := lines[span.line]
		lines[span.line] = line[..span.start] + new_name + line[span.end..]
	}
	return lines.join('\n')
}

// renamed_col is where the byte `col` of `line` of `path` is once renamed: the
// names renamed before it on the line move it.
fn (rc &RenameCheck) renamed_col(path string, line int, col int) int {
	mut shift := 0
	for span in rc.spans[path] or { return col } {
		if span.line != line || col < span.start {
			continue
		}
		if col < span.end {
			return span.start + shift + int_min(col - span.start, rc.new_name.len - 1)
		}
		shift += rc.new_name.len - (span.end - span.start)
	}
	return col + shift
}

// original_pos is where `pos`, a position once renamed, was before the rename.
fn (rc &RenameCheck) original_pos(pos NamePos) NamePos {
	mut shift := 0
	for span in rc.spans[pos.path] or { return pos } {
		if span.line != pos.line {
			continue
		}
		start := span.start + shift
		if pos.col < start {
			break
		}
		if pos.col < start + rc.new_name.len {
			return NamePos{
				...pos
				col: span.start + int_min(pos.col - start, span.end - span.start - 1)
			}
		}
		shift += rc.new_name.len - (span.end - span.start)
	}
	return NamePos{
		...pos
		col: pos.col - shift
	}
}

// is_renamed reports whether `pos` is an occurrence that the rename edits.
fn (rc &RenameCheck) is_renamed(pos NamePos) bool {
	for span in rc.spans[pos.path] or { return false } {
		if span.line == pos.line && same_name_pos(pos, NamePos{ ...pos, col: span.start }) {
			return true
		}
	}
	return false
}

// name_pos_of is the position of `loc` in bytes.
fn (app &App) name_pos_of(loc Location) NamePos {
	return NamePos{
		path: normalize_overlay_path(uri_to_path(loc.uri))
		line: loc.range.start.line
		col:  app.client_col_to_byte_col(loc.uri, loc.range.start.line, loc.range.start.char)
	}
}

// same_name_pos reports whether `a` and `b` are the same name: V may answer
// one byte apart depending on the context (see same_anchor_location).
fn same_name_pos(a NamePos, b NamePos) bool {
	return a.path == b.path && a.line == b.line && a.col - b.col <= 1 && b.col - a.col <= 1
}

// name_pos_text writes `pos` as `file.v:line:column`, from 1.
fn name_pos_text(pos NamePos) string {
	return '${os.file_name(pos.path)}:${pos.line + 1}:${pos.col + 1}'
}

// check_messages returns the errors and warnings of the output of a check, each
// as `file:line: kind: message`.
fn check_messages(output string) []string {
	mut found := []string{}
	for line in output.split_into_lines() {
		for kind in ['error', 'warning'] {
			marker := ': ${kind}: '
			idx := line.index(marker) or { continue }
			fields := line[..idx].split(':')
			if fields.len < 3 || !fields[fields.len - 1].is_int()
				|| !fields[fields.len - 2].is_int() {
				continue
			}
			found << '${fields[..fields.len - 1].join(':')}: ${kind}: ${line[idx + marker.len..]}'
			break
		}
	}
	return found
}

// new_check_message returns how the first message of `after` that `before` has
// not reads: `break the program: redefinition of `x` (main.v:12)`. What a
// message quotes between backticks is left out of the comparison, since the
// same message about the renamed name quotes the new one.
fn new_check_message(before []string, after []string) ?string {
	mut seen := map[string]int{}
	for message in before {
		seen[without_quoted_names(message)]++
	}
	for message in after {
		key := without_quoted_names(message)
		if seen[key] > 0 {
			seen[key]--
			continue
		}
		file_line := message.all_before(': ')
		kind := message.all_after(': ').all_before(': ')
		text := message.all_after(': ').all_after(': ')
		place := '${os.file_name(file_line.all_before_last(':'))}:${file_line.all_after_last(':')}'
		verb := if kind == 'warning' { 'make V warn' } else { 'break the program' }
		return '${verb}: ${text} (${place})'
	}
	return none
}

// without_quoted_names is `message` without what it quotes between backticks.
fn without_quoted_names(message string) string {
	parts := message.split('`')
	mut kept := []string{}
	for i, part in parts {
		if i % 2 == 0 {
			kept << part
		}
	}
	return kept.join('``')
}
