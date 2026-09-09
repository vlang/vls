// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import net
import os
import sync
import time

// Wait until typing pauses before starting a compiler process. Completion requests
// can then overtake diagnostics instead of sitting behind a compile on every key.
const diagnostics_debounce_ms = 300
const diagnostics_worker_poll = 25 * time.millisecond

struct DiagnosticsJob {
	uri                 string
	content             string
	version             ?i64
	position_encoding   PositionEncoding
	open_files          map[string]string
	project_generations map[string]int
	write_mutex         &sync.Mutex
	tcp_conn            ?&net.TcpConn
	global_generation   u64
	generation          u64
	ready_at            i64
}

@[heap]
struct DiagnosticsScheduler {
mut:
	mutex             sync.Mutex
	generations       map[string]u64
	global_generation u64
	pending_jobs      map[string]DiagnosticsJob
	worker_running    bool
}

fn new_diagnostics_scheduler() &DiagnosticsScheduler {
	return &DiagnosticsScheduler{
		generations: map[string]u64{}
		pending_jobs: map[string]DiagnosticsJob{}
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
	return scheduler.is_current_locked(uri, global_generation, generation)
}

fn (scheduler &DiagnosticsScheduler) is_current_locked(uri string, global_generation u64, generation u64) bool {
	return scheduler.global_generation == global_generation
		&& scheduler.generations[uri] == generation
}

// enqueue replaces an older pending job for the same document and returns true
// only when the caller must start the single diagnostics worker.
fn (mut scheduler DiagnosticsScheduler) enqueue(job DiagnosticsJob) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	scheduler.pending_jobs[job.uri] = job
	should_start := !scheduler.worker_running
	scheduler.worker_running = true
	return should_start
}

// take_ready_jobs removes jobs whose debounce deadline has passed. The second
// result tells the worker that the queue is empty and it can stop.
fn (mut scheduler DiagnosticsScheduler) take_ready_jobs(now i64) ([]DiagnosticsJob, bool) {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	mut ready := []DiagnosticsJob{}
	mut ready_uris := []string{}
	for uri, job in scheduler.pending_jobs {
		if job.ready_at <= now {
			ready << job
			ready_uris << uri
		}
	}
	for uri in ready_uris {
		scheduler.pending_jobs.delete(uri)
	}
	should_stop := ready.len == 0 && scheduler.pending_jobs.len == 0
	if should_stop {
		scheduler.worker_running = false
	}
	return ready, should_stop
}

fn (mut scheduler DiagnosticsScheduler) cancel(uri string) {
	scheduler.mutex.lock()
	scheduler.generations[uri] = scheduler.generations[uri] + 1
	scheduler.pending_jobs.delete(uri)
	scheduler.mutex.unlock()
}

fn (mut scheduler DiagnosticsScheduler) cancel_all() {
	scheduler.mutex.lock()
	scheduler.global_generation++
	scheduler.pending_jobs.clear()
	scheduler.mutex.unlock()
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
			write_mutex: app.write_mutex
			tcp_conn: app.tcp_conn
			global_generation: global_generation
			generation: generation
			ready_at: time.now().unix_milli() + diagnostics_debounce_ms
		}
		if scheduler.enqueue(job) {
			spawn run_diagnostics_worker(mut scheduler)
		}
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

fn run_diagnostics_worker(mut scheduler DiagnosticsScheduler) {
	for {
		time.sleep(diagnostics_worker_poll)
		jobs, should_stop := scheduler.take_ready_jobs(time.now().unix_milli())
		if should_stop {
			return
		}
		for job in jobs {
			run_diagnostics_job(mut scheduler, job)
		}
	}
}

fn run_diagnostics_job(mut scheduler DiagnosticsScheduler, job DiagnosticsJob) {
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
	scheduler.publish_if_current(mut worker, job, notification)
}

// publish_if_current keeps validation and the transport write atomic with
// cancellation. A close or disable that wins this lock suppresses the result;
// one that follows it will publish its clearing notification afterward.
fn (mut scheduler DiagnosticsScheduler) publish_if_current(mut app App, job DiagnosticsJob, notification Notification) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	if !scheduler.is_current_locked(job.uri, job.global_generation, job.generation) {
		return false
	}
	app.write_notification(notification)
	return true
}
