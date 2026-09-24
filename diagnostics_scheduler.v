// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import net
import os
import sync
import time

// Wait until typing pauses before starting a check. Completion requests can then
// overtake diagnostics instead of sitting behind a compile on every key. A check
// answered by a diagnostics server takes a fraction of a one-shot run, so the
// pause can be short, and the worker looks for ready jobs often.
const diagnostics_debounce_ms = 25
const diagnostics_worker_poll = 5 * time.millisecond

struct DiagnosticsJob {
	uri                 string
	content             string
	version             ?i64
	project_key         string
	project_generation  u64
	position_encoding   PositionEncoding
	open_files          map[string]string
	project_generations map[string]int
	write_mutex         &sync.Mutex
	tcp_conn            ?&net.TcpConn
	global_generation   u64
	generation          u64
	ready_at            i64
}

struct DiagnosticsTicket {
	uri                string
	global_generation  u64
	generation         u64
	project_generation u64
}

struct DiagnosticsProjectMutation {
	project_key string
	tickets     []DiagnosticsTicket
}

@[heap]
struct DiagnosticsScheduler {
mut:
	mutex               sync.Mutex
	generations         map[string]u64
	project_generations map[string]u64
	global_generation   u64
	pending_jobs        map[string]DiagnosticsJob
	worker_running      bool
	active_uri          string
	active_project_key  string
	active_generation   u64
	// The open files the last check of each program answered for, by program
	// directory.
	program_members map[string][]string
	// The diagnostics servers outlive the worker, which exits when idle.
	servers &DiagnosticsServerPool = new_diagnostics_server_pool()
}

fn new_diagnostics_scheduler() &DiagnosticsScheduler {
	return &DiagnosticsScheduler{
		generations: map[string]u64{}
		project_generations: map[string]u64{}
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

// begin_project_schedule invalidates jobs whose snapshots include an older
// buffer from the same project, then returns tickets for replacement jobs.
fn (mut scheduler DiagnosticsScheduler) begin_project_schedule(uri string, project_key string) []DiagnosticsTicket {
	return scheduler.begin_project_mutation(project_key, uri, [])
}

// begin_project_mutation invalidates pending and active jobs in a project. A
// non-empty requested_uri also schedules diagnostics for that document, and
// `others` for documents the mutation can change the diagnostics of.
fn (mut scheduler DiagnosticsScheduler) begin_project_mutation(project_key string, requested_uri string, others []string) []DiagnosticsTicket {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	mut affected := map[string]bool{}
	if requested_uri != '' {
		affected[requested_uri] = true
	}
	for other in others {
		affected[other] = true
	}
	mut pending_uris := []string{}
	for pending_uri, job in scheduler.pending_jobs {
		if job.project_key == project_key {
			affected[pending_uri] = true
			pending_uris << pending_uri
		}
	}
	for pending_uri in pending_uris {
		scheduler.pending_jobs.delete(pending_uri)
	}
	if scheduler.active_project_key == project_key && scheduler.active_uri != '' {
		affected[scheduler.active_uri] = true
	}
	scheduler.project_generations[project_key] = scheduler.project_generations[project_key] + 1
	project_generation := scheduler.project_generations[project_key]
	mut tickets := []DiagnosticsTicket{cap: affected.len}
	for affected_uri, _ in affected {
		scheduler.generations[affected_uri] = scheduler.generations[affected_uri] + 1
		tickets << DiagnosticsTicket{
			uri: affected_uri
			global_generation: scheduler.global_generation
			generation: scheduler.generations[affected_uri]
			project_generation: project_generation
		}
	}
	return tickets
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

fn (mut scheduler DiagnosticsScheduler) is_job_current(job DiagnosticsJob) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	return scheduler.is_job_current_locked(job)
}

fn (scheduler &DiagnosticsScheduler) is_job_current_locked(job DiagnosticsJob) bool {
	return scheduler.is_current_locked(job.uri, job.global_generation, job.generation)
		&& scheduler.project_generations[job.project_key] == job.project_generation
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

// take_ready_jobs removes at most one job whose debounce deadline has passed.
// The second result tells the worker that the queue is empty and it can stop.
fn (mut scheduler DiagnosticsScheduler) take_ready_jobs(now i64) ([]DiagnosticsJob, bool) {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	mut ready := []DiagnosticsJob{cap: 1}
	mut ready_uri := ''
	if scheduler.active_uri == '' {
		for uri, job in scheduler.pending_jobs {
			if job.ready_at <= now {
				ready << job
				ready_uri = uri
				break
			}
		}
	}
	if ready_uri != '' {
		job := ready[0]
		scheduler.pending_jobs.delete(ready_uri)
		scheduler.active_uri = job.uri
		scheduler.active_project_key = job.project_key
		scheduler.active_generation = job.generation
	}
	should_stop := ready.len == 0 && scheduler.pending_jobs.len == 0
		&& scheduler.active_uri == ''
	if should_stop {
		scheduler.worker_running = false
	}
	return ready, should_stop
}

fn (mut scheduler DiagnosticsScheduler) finish(job DiagnosticsJob) {
	scheduler.mutex.lock()
	if scheduler.active_uri == job.uri && scheduler.active_generation == job.generation {
		scheduler.active_uri = ''
		scheduler.active_project_key = ''
		scheduler.active_generation = 0
	}
	scheduler.mutex.unlock()
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
	mutation := app.begin_diagnostics_project_schedule(uri)
	return app.finish_diagnostics_project_schedule(mutation, uri, content)
}

fn (mut app App) begin_diagnostics_project_schedule(uri string) DiagnosticsProjectMutation {
	if !app.diagnostics_enabled {
		return DiagnosticsProjectMutation{}
	}
	if mut scheduler := app.diagnostics_scheduler {
		project_key := app.generation_key(uri)
		return DiagnosticsProjectMutation{
			project_key: project_key
			tickets: scheduler.begin_project_schedule(uri, project_key)
		}
	}
	return DiagnosticsProjectMutation{}
}

fn (mut app App) finish_diagnostics_project_schedule(mutation DiagnosticsProjectMutation, uri string, content string) bool {
	if !app.diagnostics_enabled || mutation.tickets.len == 0 {
		return false
	}
	if mut scheduler := app.diagnostics_scheduler {
		app.enqueue_diagnostics_tickets(mut scheduler, mutation.tickets, mutation.project_key, uri, content, '')
		return true
	}
	return false
}

// begin_diagnostics_project_mutation invalidates existing jobs before App state
// changes. finish_diagnostics_project_mutation rebuilds them from fresh state.
fn (mut app App) begin_diagnostics_project_mutation(uri string) DiagnosticsProjectMutation {
	if mut scheduler := app.diagnostics_scheduler {
		project_key := app.generation_key(uri)
		return DiagnosticsProjectMutation{
			project_key: project_key
			tickets:     scheduler.begin_project_mutation(project_key, '', app.open_files_affected_by(uri,
				project_key))
		}
	}
	return DiagnosticsProjectMutation{}
}

// open_files_affected_by returns the other open files whose diagnostics a change
// to the file at `uri` can change without them changing: those of its project,
// and those of any program whose directory holds it, since creating, deleting or
// renaming a file there decides whether an import resolves.
fn (app &App) open_files_affected_by(uri string, project_key string) []string {
	changed := normalize_overlay_path(uri_to_path(uri))
	mut affected := []string{}
	for open_uri, _ in app.open_files {
		if open_uri == uri {
			continue
		}
		key := app.generation_key(open_uri)
		if key == project_key || path_is_within(changed, normalize_overlay_path(key)) {
			affected << open_uri
		}
	}
	return affected
}

fn (mut app App) finish_diagnostics_project_mutation(mutation DiagnosticsProjectMutation, excluded_uri string) {
	if !app.diagnostics_enabled || mutation.tickets.len == 0 {
		return
	}
	if mut scheduler := app.diagnostics_scheduler {
		app.enqueue_diagnostics_tickets(mut scheduler, mutation.tickets, mutation.project_key, '', '', excluded_uri)
	}
}

fn (mut app App) enqueue_diagnostics_tickets(mut scheduler DiagnosticsScheduler, tickets []DiagnosticsTicket, project_key string, changed_uri string, changed_content string, excluded_uri string) {
	ready_at := time.now().unix_milli() + diagnostics_debounce_ms
	mut should_start := false
	for ticket in tickets {
		if ticket.uri == excluded_uri {
			continue
		}
		job_content := if ticket.uri == changed_uri {
			changed_content
		} else if open_content := app.open_files[ticket.uri] {
			open_content
		} else {
			os.read_file(uri_to_path(ticket.uri)) or { continue }
		}
		mut version := ?i64(none)
		if current_version := app.open_files_versions[ticket.uri] {
			version = current_version
		}
		job := DiagnosticsJob{
			uri: ticket.uri
			content: job_content
			version: version
			project_key: project_key
			project_generation: ticket.project_generation
			position_encoding: app.position_encoding
			open_files: app.open_files.clone()
			project_generations: app.project_generations.clone()
			write_mutex: app.write_mutex
			tcp_conn: app.tcp_conn
			global_generation: ticket.global_generation
			generation: ticket.generation
			ready_at: ready_at
		}
		if scheduler.enqueue(job) {
			should_start = true
		}
	}
	if should_start {
		spawn run_diagnostics_worker(mut scheduler)
	}
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
			scheduler.finish(job)
		}
	}
}

fn run_diagnostics_job(mut scheduler DiagnosticsScheduler, job DiagnosticsJob) {
	if !scheduler.is_job_current(job) {
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
		text:                  job.content
		open_files:            job.open_files
		open_files_versions:   versions
		temp_dir:              temp_dir
		diagnostics_enabled:   true
		diag_cache:            map[string]DiagCacheEntry{}
		project_generations:   job.project_generations
		position_encoding:     job.position_encoding
		write_mutex:           job.write_mutex
		tcp_conn:              job.tcp_conn
		diagnostics_servers:   scheduler.servers
		// A change that arrives while this check runs stops it: its answer would
		// be stale, and the newer check can start at once.
		diagnostics_cancelled: fn [mut scheduler, job] () bool {
			return !scheduler.is_job_current(job)
		}
	}
	notification := worker.build_diagnostics_notification(job.uri, job.content)
	if !scheduler.publish_if_current(mut worker, job, notification) {
		return
	}
	// The same check found the diagnostics of the program's other open files: a
	// change in one file shows in the others without checking them again.
	for other_uri, errors in worker.program_errors {
		other_content := job.open_files[other_uri] or { continue }
		other := worker.diagnostics_notification_for(other_uri, other_content, errors)
		scheduler.publish_if_current(mut worker, job, other)
	}
	if worker.program_dir_checked == '' {
		return
	}
	// A file that the last check of this program answered for, and this one does
	// not, left the program, as a module does when the program stops importing
	// it: nothing else checks it again, and it would keep what the program said.
	mut members := worker.program_errors.keys()
	members << job.uri
	for other_uri in scheduler.swap_program_members(worker.program_dir_checked, members) {
		other_content := job.open_files[other_uri] or { continue }
		other := worker.build_diagnostics_notification(other_uri, other_content)
		scheduler.publish_if_current(mut worker, job, other)
	}
}

// swap_program_members records `members`, the open files a check of the program
// in `program_dir` answered for, and returns those the previous check of that
// program answered for and this one does not.
fn (mut scheduler DiagnosticsScheduler) swap_program_members(program_dir string, members []string) []string {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	previous := scheduler.program_members[program_dir] or { []string{} }
	scheduler.program_members[program_dir] = members
	return previous.filter(it !in members)
}

// publish_if_current keeps validation and the transport write atomic with
// cancellation. A close or disable that wins this lock suppresses the result;
// one that follows it will publish its clearing notification afterward.
fn (mut scheduler DiagnosticsScheduler) publish_if_current(mut app App, job DiagnosticsJob, notification Notification) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	if !scheduler.is_job_current_locked(job) {
		return false
	}
	app.write_notification(notification)
	return true
}
