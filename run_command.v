// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import net
import os
import strings
import sync
import time

const code_lens_output_limit_bytes = 256 * 1024
const code_lens_output_truncation_notice = '\n[vls: additional process output was truncated]'

enum CodeLensRunKind {
	main
	test_file
	test_function
}

struct CodeLensRunJob {
	kind           CodeLensRunKind
	title          string
	uri            string
	path           string
	fn_name        string
	open_files     map[string]string
	write_mutex    &sync.Mutex
	tcp_conn       ?&net.TcpConn
	capture_output bool
}

struct ManagedRunResult {
	result    os.Result
	cancelled bool
}

struct RunOutputBuffer {
mut:
	output    strings.Builder
	truncated bool
}

fn new_run_output_buffer() RunOutputBuffer {
	return RunOutputBuffer{
		output: strings.new_builder(1024)
	}
}

fn (mut output RunOutputBuffer) write(chunk string) {
	remaining := code_lens_output_limit_bytes - output.output.len
	if remaining <= 0 {
		if chunk.len > 0 {
			output.truncated = true
		}
		return
	}
	if chunk.len <= remaining {
		output.output.write_string(chunk)
		return
	}
	output.output.write_string(chunk[..remaining])
	output.truncated = true
}

fn (mut output RunOutputBuffer) str() string {
	mut result := output.output.str()
	if output.truncated {
		result += code_lens_output_truncation_notice
	}
	return result
}

// code_lens_source_code_mask keeps code bytes in place while hiding strings and comments.
// Interpolation expressions remain visible because they can contain compile-time path tokens.
fn code_lens_source_code_mask(source string) []u8 {
	mut mask := []u8{len: source.len, init: ` `}
	mut state := ImportScanState{}
	mut in_line_comment := false
	mut pos := 0
	for pos < source.len {
		if in_line_comment {
			if source[pos] == `\n` {
				in_line_comment = false
				mask[pos] = `\n`
			}
			pos++
			continue
		}
		if state.block_comment_depth > 0 {
			if pos + 1 < source.len && source[pos] == `/` && source[pos + 1] == `*` {
				state.block_comment_depth++
				pos += 2
				continue
			}
			if pos + 1 < source.len && source[pos] == `*` && source[pos + 1] == `/` {
				state.block_comment_depth--
				pos += 2
				continue
			}
			if source[pos] == `\n` {
				mask[pos] = `\n`
			}
			pos++
			continue
		}
		if state.quote != 0 {
			if !state.raw_string && source[pos] == `\\` && pos + 1 < source.len {
				pos += 2
				continue
			}
			if !state.raw_string && source[pos] == `$` && pos + 1 < source.len
				&& source[pos + 1] == `{` {
				state.interpolations << ImportInterpolationState{
					quote: state.quote
				}
				state.quote = 0
				pos += 2
				continue
			}
			if source[pos] == state.quote {
				state.quote = 0
				state.raw_string = false
			}
			if source[pos] == `\n` {
				mask[pos] = `\n`
			}
			pos++
			continue
		}
		if pos + 1 < source.len && source[pos] == `/` && source[pos + 1] == `/` {
			in_line_comment = true
			pos += 2
			continue
		}
		if pos + 1 < source.len && source[pos] == `/` && source[pos + 1] == `*` {
			state.block_comment_depth = 1
			pos += 2
			continue
		}
		if source[pos] == `{` && state.interpolations.len > 0 {
			last := state.interpolations.len - 1
			state.interpolations[last].brace_depth++
			mask[pos] = source[pos]
			pos++
			continue
		}
		if source[pos] == `}` && state.interpolations.len > 0 {
			last := state.interpolations.len - 1
			if state.interpolations[last].brace_depth == 0 {
				interpolation := state.interpolations.pop()
				state.quote = interpolation.quote
				state.raw_string = false
			} else {
				state.interpolations[last].brace_depth--
				mask[pos] = source[pos]
			}
			pos++
			continue
		}
		if source[pos] == `r` && pos + 1 < source.len
			&& source[pos + 1] in [`'`, `"`] {
			state.quote = source[pos + 1]
			state.raw_string = true
			pos += 2
			continue
		}
		if source[pos] in [`'`, `"`, 96] {
			state.quote = source[pos]
			state.raw_string = false
			pos++
			continue
		}
		mask[pos] = source[pos]
		pos++
	}
	return mask
}

fn code_lens_mask_has_at_token(mask []u8, pos int, token string) bool {
	if pos + token.len > mask.len {
		return false
	}
	for i in 0 .. token.len {
		if mask[pos + i] != token[i] {
			return false
		}
	}
	return pos + token.len == mask.len || !is_ident_char(mask[pos + token.len])
}

fn code_lens_token_is_in_hash_directive(mask []u8, pos int) bool {
	mut line_start := pos
	for line_start > 0 && mask[line_start - 1] != `\n` {
		line_start--
	}
	for line_start < pos && mask[line_start].is_space() {
		line_start++
	}
	return line_start < pos && mask[line_start] == `#`
}

fn code_lens_v_string_literal(value string) string {
	escaped := value.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$').replace('\n',
		'\\n').replace('\r', '\\r').replace('\t', '\\t')
	return "'${escaped}'"
}

// code_lens_source_with_real_paths prevents the temporary overlay location from being compiled
// into path pseudo variables. Hash directives retain their tokens so the compiler can resolve
// native inputs from the materialized overlay.
fn code_lens_source_with_real_paths(source string, source_path string) string {
	mask := code_lens_source_code_mask(source)
	file_path := os.real_path(source_path)
	file_dir := os.real_path(os.dir(source_path))
	vmod_root := find_project_root(os.dir(source_path))
	mut rewritten := strings.new_builder(source.len + 64)
	mut pos := 0
	for pos < source.len {
		if mask[pos] == `@` && !code_lens_token_is_in_hash_directive(mask, pos) {
			if vmod_root != '' && code_lens_mask_has_at_token(mask, pos, '@VMODROOT') {
				rewritten.write_string(code_lens_v_string_literal(os.real_path(vmod_root)))
				pos += '@VMODROOT'.len
				continue
			}
			if code_lens_mask_has_at_token(mask, pos, '@FILE') {
				rewritten.write_string(code_lens_v_string_literal(file_path))
				pos += '@FILE'.len
				continue
			}
			if code_lens_mask_has_at_token(mask, pos, '@DIR') {
				rewritten.write_string(code_lens_v_string_literal(file_dir))
				pos += '@DIR'.len
				continue
			}
		}
		rewritten.write_u8(source[pos])
		pos++
	}
	return rewritten.str()
}

// preserve_code_lens_overlay_dir rewrites both open buffers and linked sibling module files.
fn preserve_code_lens_overlay_dir(overlay CompilationOverlay, temp_dir string,
	open_sources map[string]string) ! {
	for entry in os.ls(temp_dir)! {
		temp_path := os.join_path(temp_dir, entry)
		if !os.is_link(temp_path) && os.is_dir(temp_path) {
			preserve_code_lens_overlay_dir(overlay, temp_path, open_sources)!
			continue
		}
		if !os.is_file(temp_path) || (!temp_path.ends_with('.v') && !temp_path.ends_with('.vsh')) {
			continue
		}
		rel_path := overlay_relative_path(temp_path, overlay.temp_root) or { continue }
		source_path := normalize_overlay_path(os.join_path(overlay.source_root, rel_path))
		source := open_sources[source_path] or { os.read_file(temp_path)! }
		rewritten := code_lens_source_with_real_paths(source, source_path)
		if rewritten == source {
			continue
		}
		// Unlink first: unchanged overlay files may be links to the user's source tree.
		os.rm(temp_path)!
		os.write_file(temp_path, rewritten) or {
			return error('Failed to preserve source paths for ${source_path}: ${err}')
		}
	}
}

fn preserve_code_lens_overlay_source_paths(overlay CompilationOverlay,
	open_files map[string]string) ! {
	mut open_sources := map[string]string{}
	for uri, source in open_files {
		open_sources[normalize_overlay_path(uri_to_path(uri))] = source
	}
	preserve_code_lens_overlay_dir(overlay, overlay.temp_root, open_sources)!
}

@[heap]
struct RunCommandManager {
	workers &sync.WaitGroup
mut:
	mutex     sync.Mutex
	processes map[u64]&os.Process
	next_id   u64
	stopping  bool
}

fn new_run_command_manager() &RunCommandManager {
	return &RunCommandManager{
		workers:   sync.new_waitgroup()
		processes: map[u64]&os.Process{}
	}
}

// begin_job reserves an id and increments the worker count while holding the lifecycle lock.
// Once stopping is set, no new worker can race with wait().
fn (mut manager RunCommandManager) begin_job() (u64, bool) {
	manager.mutex.lock()
	defer {
		manager.mutex.unlock()
	}
	if manager.stopping {
		return 0, false
	}
	manager.next_id++
	manager.workers.add(1)
	return manager.next_id, true
}

fn (mut manager RunCommandManager) launch(job CodeLensRunJob) bool {
	id, accepted := manager.begin_job()
	if !accepted {
		return false
	}
	spawn run_code_lens_job(mut manager, id, job)
	return true
}

// run_sync is only used by tests that need to inspect worker notifications deterministically.
fn (mut manager RunCommandManager) run_sync(job CodeLensRunJob) []string {
	id, accepted := manager.begin_job()
	if !accepted {
		return []
	}
	return run_code_lens_job(mut manager, id, job)
}

fn (mut manager RunCommandManager) register_process(id u64, process &os.Process) bool {
	manager.mutex.lock()
	defer {
		manager.mutex.unlock()
	}
	if manager.stopping {
		return false
	}
	manager.processes[id] = process
	return true
}

fn (mut manager RunCommandManager) unregister_process(id u64) {
	manager.mutex.lock()
	manager.processes.delete(id)
	manager.mutex.unlock()
}

fn (mut manager RunCommandManager) is_stopping() bool {
	manager.mutex.lock()
	stopping := manager.stopping
	manager.mutex.unlock()
	return stopping
}

// cancel_all_and_wait prevents new runs, kills active children, and joins every worker.
fn (mut manager RunCommandManager) cancel_all_and_wait() {
	manager.mutex.lock()
	manager.stopping = true
	for _, mut process in manager.processes {
		if process.is_alive() {
			process.signal_pgkill()
		}
	}
	manager.mutex.unlock()
	manager.workers.wait()
}

// run_managed_process runs a code-lens subprocess without the diagnostics timeout. The manager
// owns cancellation instead, so a long-running program stays alive while VLS remains active and
// is terminated when its client shuts down or disconnects.
fn run_managed_process(mut manager RunCommandManager, id u64, executable string, args []string,
	work_folder string) ManagedRunResult {
	if work_folder != '' && !os.is_dir(work_folder) {
		return ManagedRunResult{
			result: os.Result{
				exit_code: 1
				output:    'Working dir does not exist: ${work_folder}'
			}
		}
	}
	mut process := os.new_process(executable)
	process.set_args(args)
	process.use_pgroup = true
	if work_folder != '' {
		process.set_work_folder(work_folder)
	}
	process.set_stdin_path(os.path_devnull)
	process.set_redirect_stdio()
	process.run()
	registered := manager.register_process(id, process)
	if !registered && process.is_alive() {
		process.signal_pgkill()
	}

	mut output := new_run_output_buffer()
	for process.is_alive() {
		mut got_data := false
		if chunk := process.pipe_read(.stdout) {
			output.write(chunk)
			got_data = true
		}
		if chunk := process.pipe_read(.stderr) {
			output.write(chunk)
			got_data = true
		}
		if !got_data {
			time.sleep(time.millisecond)
		}
	}
	output.write(process.stdout_slurp())
	output.write(process.stderr_slurp())
	process.wait()
	if registered {
		manager.unregister_process(id)
	}
	exit_code := process.code
	process.close()
	return ManagedRunResult{
		result: os.Result{
			exit_code: exit_code
			output:    output.str()
		}
		cancelled: !registered || manager.is_stopping()
	}
}

fn code_lens_executable_path(temp_dir string) string {
	$if windows {
		return os.join_path(temp_dir, 'code_lens_program.exe')
	}
	return os.join_path(temp_dir, 'code_lens_program')
}

fn code_lens_compile_args(job CodeLensRunJob, target_path string,
	executable_path string) []string {
	return match job.kind {
		.main { build_v_run_compile_args(executable_path) }
		.test_file { build_v_test_compile_args(target_path, '', executable_path) }
		.test_function { build_v_test_compile_args(target_path, job.fn_name, executable_path) }
	}
}

fn log_code_lens_output(mut worker App, result os.Result, overlay CompilationOverlay) {
	mut output := result.output.trim_space()
	if overlay.temp_root != '' {
		output = output.replace(overlay.temp_root, overlay.source_display_root)
	}
	if output != '' {
		level := if result.exit_code == 0 { 3 } else { 1 }
		worker.send_log_message(output, level)
	}
}

fn code_lens_display_args(job CodeLensRunJob) []string {
	return match job.kind {
		.main { build_v_run_args() }
		.test_file { build_v_test_args(job.path, '') }
		.test_function { build_v_test_args(job.path, job.fn_name) }
	}
}

fn run_code_lens_job(mut manager RunCommandManager, id u64, job CodeLensRunJob) []string {
	defer {
		manager.workers.done()
	}
	temp_dir := os.join_path(os.temp_dir(), 'vls_run_${os.getpid()}_${id}_${time.now().unix_nano()}')
	mut worker := App{
		open_files:      job.open_files
		temp_dir:        temp_dir
		capture_output:  job.capture_output
		write_mutex:     job.write_mutex
		tcp_conn:        job.tcp_conn
	}
	os.mkdir_all(temp_dir) or {
		worker.send_show_message('vls: ${job.title} could not create a temporary directory: ${err}',
			1)
		return worker.captured_output.clone()
	}
	defer {
		os.rmdir_all(temp_dir) or { log('Failed to clean up run command directory: ${err}') }
	}

	mut target_path := job.path
	source_work_dir := os.dir(job.path)
	mut compile_dir := source_work_dir
	mut overlay := CompilationOverlay{}
	if job.uri in job.open_files {
		overlay = worker.prepare_compilation_overlay(job.path) or {
			worker.send_show_message('vls: ${job.title} could not prepare the open buffer: ${err}',
				1)
			return worker.captured_output.clone()
		}
		preserve_code_lens_overlay_source_paths(overlay, job.open_files) or {
			worker.send_show_message('vls: ${job.title} could not preserve source paths: ${err}',
				1)
			return worker.captured_output.clone()
		}
		target_path = overlay.temp_source_file
		compile_dir = overlay.temp_work_dir
	}

	executable_path := code_lens_executable_path(temp_dir)
	compile_args := code_lens_compile_args(job, target_path, executable_path)
	display_args := code_lens_display_args(job)
	worker.send_log_message('vls: ${job.title}: v ${display_args.join(' ')}', 3)
	compile_result := run_managed_process(mut manager, id, resolve_v_compiler_exe(), compile_args,
		compile_dir)
	if compile_result.cancelled {
		return worker.captured_output.clone()
	}
	log_code_lens_output(mut worker, compile_result.result, overlay)
	if compile_result.result.exit_code != 0 {
		worker.send_show_message(
			'vls: ${job.title} failed with exit code ${compile_result.result.exit_code}.', 1)
		return worker.captured_output.clone()
	}

	run_result := run_managed_process(mut manager, id, executable_path, [], source_work_dir)
	if run_result.cancelled {
		return worker.captured_output.clone()
	}
	log_code_lens_output(mut worker, run_result.result, overlay)
	if run_result.result.exit_code != 0 {
		worker.send_show_message(
			'vls: ${job.title} failed with exit code ${run_result.result.exit_code}.', 1)
		return worker.captured_output.clone()
	}
	worker.send_show_message('vls: ${job.title} finished successfully.', 3)
	return worker.captured_output.clone()
}

fn (mut app App) start_code_lens_run(job CodeLensRunJob) {
	mut manager := app.get_run_command_manager()
	if app.execute_commands_synchronously {
		app.captured_output << manager.run_sync(job)
	} else if !manager.launch(job) {
		app.send_show_message('vls: cannot start ${job.title}; the server is shutting down.', 1)
	}
}

fn (mut app App) get_run_command_manager() &RunCommandManager {
	if manager := app.run_command_manager {
		return manager
	}
	manager := new_run_command_manager()
	app.run_command_manager = manager
	return manager
}

fn (mut app App) stop_run_commands() {
	if mut manager := app.run_command_manager {
		manager.cancel_all_and_wait()
	}
}
