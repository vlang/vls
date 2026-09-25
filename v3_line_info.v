module main

import os

// V3 answers the `-line-info` questions of the mini-VLS protocol (hover,
// definition, signature help, completion and inlay hints). It answers them in
// a copy of the program, built once with the editor's buffers and the other
// files linked from disk, and kept: each request writes into it only the files
// that changed. The V in use answers through the `query` requests of its
// diagnostics server when it runs one, and otherwise in a compiler process of
// its own. V1 is left what V3 cannot answer, such as a file that does not parse
// while it is being written.

// v3_completion_placeholder is the name written after the dot the cursor
// follows when completion is asked for: V3 has to parse the member access it
// completes, where V1 accepted `x.` with nothing after it.
const v3_completion_placeholder = 'vlsmember'

// V3QueryProject is the copy of a program V3 answers questions in.
struct V3QueryProject {
mut:
	overlay CompilationOverlay
	// What each file of the program written into the copy holds, by its path.
	written map[string]string
	// What the copy may still copy of the project where it cannot link it, for
	// all its writes together (see own_overlay_dirs).
	copy_budget OverlayCopyBudget = new_overlay_copy_budget()
}

// V3Question is a question about a position of the file at `path`, which holds
// `content` for it: `line:<code><column>`, as `-line-info` takes it.
struct V3Question {
	path      string
	content   string
	line_info string
}

// V3Answers are the answers to the questions of one request, in their order,
// and the copy of the program they come from.
struct V3Answers {
	project V3QueryProject
	answers []string
}

// v3_line_info answers `line_info` for the file at `path` from V3, or returns
// none when V3 cannot: the caller then asks V1.
fn (mut app App) v3_line_info(method Method, path string, real_path string, line_info string) ?ResponseResult {
	if !app.v3_line_info_enabled || os.getenv('VLS_V3_LINE_INFO') == 'off' {
		return none
	}
	mut content := app.open_files[path] or { os.read_file(real_path) or { return none } }
	if method == .completion {
		content = with_completion_placeholder(content, line_info)
	}
	result := app.v3_ask(real_path, [
		V3Question{
			path:      normalize_overlay_path(real_path)
			content:   content
			line_info: line_info
		},
	])?
	output := normalize_v_line_info_output(result.answers[0], method)
	if output == '' {
		return none
	}
	log('V3 answered ${output.len} bytes')
	return app.line_info_result(method, path, line_info, output, true, result.project.overlay.temp_root,
		result.project.overlay)
}

// v3_ask asks V3 `questions` about files of the program that holds the file at
// `real_path`, all in one check.
fn (mut app App) v3_ask(real_path string, questions []V3Question) ?V3Answers {
	program_dir := app.program_root(real_path)
	mut project := app.v3_query_project(real_path, program_dir) or {
		log('no V3 copy of ${program_dir}: ${err}')
		return none
	}
	app.v3_sync_open_files(mut project)
	mut specs := []string{cap: questions.len}
	mut targets := []string{cap: questions.len}
	for question in questions {
		copy_path := project.write(question.path, question.content) or { return none }
		specs << '${copy_path}:${question.line_info}'
		// A test file is a program of its own, which V builds with the files of
		// its module: the program of the directory leaves it out.
		targets << if copy_path.ends_with('_test.v') { copy_path } else { '.' }
	}
	app.v3_query_projects[program_dir] = project
	// The questions about one program are asked in one check.
	mut answers := []string{len: questions.len}
	mut asked := []bool{len: questions.len}
	mut answered := false
	for first, target in targets {
		if asked[first] {
			continue
		}
		mut group := []int{}
		for i in first .. targets.len {
			if targets[i] == target {
				group << i
				asked[i] = true
			}
		}
		output := app.v3_run(project, group.map(specs[it]), target) or { continue }
		answered = true
		if group.len == 1 {
			answers[group[0]] = output
			continue
		}
		// Several questions get an answer each, on a line of its own after its index.
		for line in output.split_into_lines() {
			index_text := line.all_before('\t')
			if line.contains('\t') && index_text.is_int() {
				index := index_text.int()
				if index >= 0 && index < group.len {
					answers[group[index]] = line.all_after('\t')
				}
			}
		}
	}
	if !answered {
		return none
	}
	return V3Answers{
		project: project
		answers: answers
	}
}

// v3_run sends the questions `specs` about the program `target`, `.` or a test
// file, to the diagnostics server of the V in use, or, where there is none, to
// a compiler process of its own, and returns what it answered. None means V3
// has no answer: it cannot parse the program, or the V in use has no V3 that
// answers questions.
fn (mut app App) v3_run(project V3QueryProject, specs []string, target string) ?string {
	is_library := target == '.' && !app.is_program_dir(project.overlay.source_work_dir)
	question := specs.join('\t')
	if exe := resolve_diagnostics_server_exe() {
		mut args := v3_compiler_selection_args()
		if is_library {
			args << '-shared'
		}
		args << ['-w', '-check', '-nocolor', target]
		mut servers := app.v3_query_pool()
		if result := servers.query(exe, args, project.overlay.temp_work_dir, question) {
			return if result.exit_code == 0 { result.output } else { none }
		}
	}
	if app.v3_one_shot_unsupported {
		return none
	}
	// `-new-compiler`: the launcher sends `-vls-mode` to V1 without it.
	mut argv := ['-new-compiler', '-w', '-check', '-nocolor']
	if is_library {
		argv << '-shared'
	}
	argv << ['-vls-mode', '-line-info', question, target]
	x := run_v_argv(argv, project.overlay.temp_work_dir)
	if compiler_rejects_any_option(x.output, ['-new-compiler', '-vls-mode', '-line-info']) {
		log('this V has no V3 that answers -line-info')
		app.v3_one_shot_unsupported = true
		return none
	}
	return if x.exit_code == 0 { x.output } else { none }
}

// v3_query_project returns the copy of the program in `program_dir` that holds
// the file at `real_path`, building it when there is none yet.
fn (mut app App) v3_query_project(real_path string, program_dir string) !V3QueryProject {
	if project := app.v3_query_projects[program_dir] {
		if os.is_dir(project.overlay.temp_work_dir) {
			return project
		}
	}
	// A copy for each program: the copy of another would not hold what this one
	// keeps as written into it.
	app.overlay_dir = app.v3_query_pool().stable_dir('query', program_dir)
	defer {
		app.overlay_dir = ''
	}
	overlay := app.prepare_compilation_overlay_in(real_path, program_dir)!
	// The copy holds the open files as their buffers already.
	mut written := map[string]string{}
	for uri, content in app.open_files {
		path := normalize_overlay_path(uri_to_path(uri))
		if path_is_within(path, overlay.source_root) {
			written[path] = content
		}
	}
	return V3QueryProject{
		overlay: overlay
		written: written
	}
}

// v3_sync_open_files writes into the copy what the editor holds: every open
// file of the program as its buffer, and a file written before that is no
// longer open as it is on disk again.
fn (mut app App) v3_sync_open_files(mut project V3QueryProject) {
	mut open_paths := map[string]bool{}
	for uri, content in app.open_files {
		path := normalize_overlay_path(uri_to_path(uri))
		if path_is_within(path, project.overlay.source_root) {
			open_paths[path] = true
			project.write(path, content) or {}
		}
	}
	for path in project.written.keys() {
		if path !in open_paths {
			project.write(path, os.read_file(path) or { '' }) or {}
		}
	}
}

// write makes the copy of the file at `path` hold `content`, and returns the
// path of that copy. The copy links the project's files it was not asked to
// write, by a link to the file, a hard link, or a link to a directory above it:
// such a link is replaced by a file of the copy's own, never written through.
fn (mut project V3QueryProject) write(path string, content string) !string {
	rel := overlay_relative_path(path, project.overlay.source_root) or {
		return error('${path} is not in ${project.overlay.source_root}')
	}
	copy_path := os.join_path(project.overlay.temp_root, rel)
	if written := project.written[path] {
		if written == content && os.is_file(copy_path) && !os.is_link(copy_path) {
			return copy_path
		}
	}
	own_overlay_dirs(project.overlay.source_root, project.overlay.temp_root, os.dir(rel), mut
		project.copy_budget)!
	if os.exists(copy_path) || os.is_link(copy_path) {
		os.rm(copy_path)!
	}
	os.write_file(copy_path, content)!
	project.written[path] = content
	return copy_path
}

// v3_query_pool returns the servers that answer this editor's questions, whose
// directory holds the copies of its programs.
fn (mut app App) v3_query_pool() &DiagnosticsServerPool {
	if app.v3_query_servers == unsafe { nil } {
		app.v3_query_servers = new_diagnostics_server_pool()
	}
	return app.v3_query_servers
}

// v3_query_notice_disk_change forgets the copy of the program a file was
// created or deleted in: the copy links the files that were there when it was
// built. A change to a file needs nothing: a link shows it, and a file written
// into the copy is written again from what it holds.
fn (mut app App) v3_query_notice_disk_change(changed_path string, event_type int) {
	if event_type == 2 {
		return
	}
	for program_dir, project in app.v3_query_projects {
		if path_is_within(normalize_overlay_path(changed_path), project.overlay.source_root) {
			app.v3_query_projects.delete(program_dir)
		}
	}
}

// v3_prefetch_anchors asks V3, in one check per program, where the name at each
// of `locations` is declared, and keeps what it finds in `cache` for
// resolve_symbol_anchor_cached: the references, renames and document highlights
// that look them up one after another then start no compiler for each.
fn (mut app App) v3_prefetch_anchors(locations []Location, mut cache map[string]?Location) {
	if !app.v3_line_info_enabled || os.getenv('VLS_V3_LINE_INFO') == 'off' || locations.len < 2 {
		return
	}
	mut program_of_dir := map[string]string{}
	mut groups := map[string][]Location{}
	for loc in locations {
		if anchor_cache_key(loc.uri, loc.range.start.line, loc.range.start.char) in cache {
			continue
		}
		dir := os.dir(uri_to_path(loc.uri))
		if dir !in program_of_dir {
			program_of_dir[dir] = app.program_root(uri_to_path(loc.uri))
		}
		groups[program_of_dir[dir]] << loc
	}
	for _, locs in groups {
		mut questions := []V3Question{cap: locs.len}
		mut asked := []Location{cap: locs.len}
		for loc in locs {
			probe_cols := app.anchor_probe_cols(loc.uri, loc.range.start.line, loc.range.start.char)
			if probe_cols.len == 0 {
				continue
			}
			path := uri_to_path(loc.uri)
			byte_col := app.client_col_to_byte_col(loc.uri, loc.range.start.line, probe_cols[0])
			questions << V3Question{
				path:      normalize_overlay_path(path)
				content:   app.open_files[loc.uri] or { os.read_file(path) or { continue } }
				line_info: '${loc.range.start.line + 1}:gd^${byte_col}'
			}
			asked << loc
		}
		if questions.len == 0 {
			continue
		}
		result := app.v3_ask(questions[0].path, questions) or { continue }
		for i, loc in asked {
			output := normalize_v_line_info_output(result.answers[i], .definition)
			if output == '' {
				continue
			}
			found := app.line_info_result(.definition, loc.uri, questions[i].line_info, output,
				true, result.project.overlay.temp_root, result.project.overlay)
			if found is Location && found.uri != '' {
				cache[anchor_cache_key(loc.uri, loc.range.start.line, loc.range.start.char)] = found
			}
		}
	}
}

// stop_v3_queries ends the V3 servers that answered questions.
fn (mut app App) stop_v3_queries() {
	if app.v3_query_servers != unsafe { nil } {
		mut servers := app.v3_query_servers
		servers.stop_all()
	}
	app.v3_query_projects.clear()
}

// with_completion_placeholder writes v3_completion_placeholder at the cursor of
// a completion request, `line:column` with a 0-based byte column, when the
// cursor follows a dot and no name does: `x.` becomes `x.vlsmember`.
fn with_completion_placeholder(content string, line_info string) string {
	line_nr := line_info.all_before(':').int()
	col := line_info.all_after(':').int()
	if line_nr < 1 || col < 1 {
		return content
	}
	mut line_start := 0
	for _ in 1 .. line_nr {
		next := content.index_after('\n', line_start) or { return content }
		line_start = next + 1
	}
	offset := line_start + col
	if offset > content.len || content[offset - 1] != `.`
		|| (offset < content.len && is_ident_char(content[offset])) {
		return content
	}
	return content[..offset] + v3_completion_placeholder + content[offset..]
}
