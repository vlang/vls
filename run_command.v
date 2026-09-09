// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import net
import os
import strings
import sync
import time

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

// run_managed_v_argv runs a user-requested program without the diagnostics timeout. The manager
// owns cancellation instead, so a long-running main stays alive while VLS remains active and is
// terminated when its client shuts down or disconnects.
fn run_managed_v_argv(mut manager RunCommandManager, id u64, args []string,
	work_folder string) ManagedRunResult {
	if work_folder != '' && !os.is_dir(work_folder) {
		return ManagedRunResult{
			result: os.Result{
				exit_code: 1
				output:    'Working dir does not exist: ${work_folder}'
			}
		}
	}
	mut process := os.new_process(resolve_v_compiler_exe())
	process.set_args(args)
	process.use_pgroup = true
	if work_folder != '' {
		process.set_work_folder(work_folder)
	}
	process.set_redirect_stdio()
	process.run()
	registered := manager.register_process(id, process)
	if !registered && process.is_alive() {
		process.signal_pgkill()
	}

	mut output := strings.new_builder(1024)
	for process.is_alive() {
		mut got_data := false
		if chunk := process.pipe_read(.stdout) {
			output.write_string(chunk)
			got_data = true
		}
		if chunk := process.pipe_read(.stderr) {
			output.write_string(chunk)
			got_data = true
		}
		if !got_data {
			time.sleep(time.millisecond)
		}
	}
	output.write_string(process.stdout_slurp())
	output.write_string(process.stderr_slurp())
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
	mut exec_dir := os.dir(job.path)
	mut overlay := CompilationOverlay{}
	if job.uri in job.open_files {
		overlay = worker.prepare_compilation_overlay(job.path) or {
			worker.send_show_message('vls: ${job.title} could not prepare the open buffer: ${err}',
				1)
			return worker.captured_output.clone()
		}
		target_path = overlay.temp_source_file
		exec_dir = overlay.temp_work_dir
	}

	args := match job.kind {
		.main { build_v_run_args() }
		.test_file { build_v_test_args(target_path, '') }
		.test_function { build_v_test_args(target_path, job.fn_name) }
	}
	display_args := code_lens_display_args(job)
	worker.send_log_message('vls: ${job.title}: v ${display_args.join(' ')}', 3)
	managed_result := run_managed_v_argv(mut manager, id, args, exec_dir)
	if managed_result.cancelled {
		return worker.captured_output.clone()
	}
	mut output := managed_result.result.output.trim_space()
	if overlay.temp_root != '' {
		output = output.replace(overlay.temp_root, overlay.source_display_root)
	}
	if output != '' {
		level := if managed_result.result.exit_code == 0 { 3 } else { 1 }
		worker.send_log_message(output, level)
	}
	if managed_result.result.exit_code != 0 {
		worker.send_show_message(
			'vls: ${job.title} failed with exit code ${managed_result.result.exit_code}.', 1)
	} else {
		worker.send_show_message('vls: ${job.title} finished successfully.', 3)
	}
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
