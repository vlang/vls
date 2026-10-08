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

// run_fast_diagnostics_job answers a fast job: index-only errors, no
// compiler, no temp copy. An empty fast answer publishes nothing: the slow
// check publishes the file's full state, which also clears a fast error it
// does not repeat.
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
	errors := worker.fast_check_errors(job.uri, job.content)
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
