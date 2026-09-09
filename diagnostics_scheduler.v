// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import net
import os
import sync
import time

// Wait until typing pauses before starting a compiler process. Completion requests
// can then overtake diagnostics instead of sitting behind a compile on every key.
const diagnostics_debounce = 300 * time.millisecond

@[heap]
struct DiagnosticsScheduler {
mut:
	mutex             sync.Mutex
	generations       map[string]u64
	global_generation u64
}

fn new_diagnostics_scheduler() &DiagnosticsScheduler {
	return &DiagnosticsScheduler{
		generations: map[string]u64{}
	}
}

fn (mut scheduler DiagnosticsScheduler) next_generation(uri string) (u64, u64) {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	scheduler.generations[uri] = scheduler.generations[uri] + 1
	return scheduler.global_generation, scheduler.generations[uri]
}

fn (mut scheduler DiagnosticsScheduler) is_current(uri string, global_generation u64, generation u64) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	return scheduler.global_generation == global_generation
		&& scheduler.generations[uri] == generation
}

fn (mut scheduler DiagnosticsScheduler) cancel(uri string) {
	scheduler.mutex.lock()
	scheduler.generations[uri] = scheduler.generations[uri] + 1
	scheduler.mutex.unlock()
}

fn (mut scheduler DiagnosticsScheduler) cancel_all() {
	scheduler.mutex.lock()
	scheduler.global_generation++
	scheduler.mutex.unlock()
}

struct DiagnosticsJob {
	uri                 string
	content             string
	version             ?i64
	position_encoding   PositionEncoding
	open_files          map[string]string
	project_generations map[string]int
	scheduler           &DiagnosticsScheduler
	write_mutex         &sync.Mutex
	tcp_conn            ?&net.TcpConn
	global_generation   u64
	generation          u64
}

fn (mut app App) schedule_diagnostics(uri string, content string) bool {
	if !app.diagnostics_enabled {
		return false
	}
	if mut scheduler := app.diagnostics_scheduler {
		global_generation, generation := scheduler.next_generation(uri)
		mut version := ?i64(none)
		if current_version := app.open_files_versions[uri] {
			version = current_version
		}
		job := DiagnosticsJob{
			uri: uri
			content: content
			version: version
			position_encoding: app.position_encoding
			open_files: app.open_files.clone()
			project_generations: app.project_generations.clone()
			scheduler: scheduler
			write_mutex: app.write_mutex
			tcp_conn: app.tcp_conn
			global_generation: global_generation
			generation: generation
		}
		spawn run_diagnostics_job(job)
		return true
	}
	return false
}

fn (mut app App) cancel_scheduled_diagnostics(uri string) {
	if mut scheduler := app.diagnostics_scheduler {
		scheduler.cancel(uri)
	}
}

fn (mut app App) cancel_all_scheduled_diagnostics() {
	if mut scheduler := app.diagnostics_scheduler {
		scheduler.cancel_all()
	}
}

fn run_diagnostics_job(job DiagnosticsJob) {
	mut scheduler := job.scheduler
	time.sleep(diagnostics_debounce)
	if !scheduler.is_current(job.uri, job.global_generation, job.generation) {
		return
	}
	temp_dir := os.join_path(os.temp_dir(), 'vls_diag_${os.getpid()}_${job.generation}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { return }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut versions := map[string]i64{}
	if version := job.version {
		versions[job.uri] = version
	}
	mut worker := App{
		text: job.content
		open_files: job.open_files
		open_files_versions: versions
		temp_dir: temp_dir
		diagnostics_enabled: true
		diag_cache: map[string]DiagCacheEntry{}
		project_generations: job.project_generations
		position_encoding: job.position_encoding
		write_mutex: job.write_mutex
		tcp_conn: job.tcp_conn
	}
	notification := worker.build_diagnostics_notification(job.uri, job.content)
	if scheduler.is_current(job.uri, job.global_generation, job.generation) {
		worker.write_notification(notification)
	}
}
