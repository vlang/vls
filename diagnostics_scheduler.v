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
	overlay_store       ?&OverlayCacheStore
	scheduler           ?&DiagnosticsScheduler
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
// ProjectDiagResult caches one project-wide compiler run for batching: the
// unfiltered errors plus the overlay layout needed to map them back to
// source paths. Only shared-overlay runs are stored, so the layout stays
// valid while the entry is reachable.
struct ProjectDiagResult {
	generation          int
	errors              []JsonError
	temp_root           string
	temp_work_dir       string
	source_display_root string
}

struct DiagnosticsScheduler {
mut:
	mutex               sync.Mutex
	generations         map[string]u64
	project_generations map[string]u64
	diag_results        map[string]DiagCacheEntry
	project_results     map[string]ProjectDiagResult
	global_generation   u64
	pending_jobs        map[string]DiagnosticsJob
	worker_running      bool
	active_uri          string
	active_project_key  string
	active_generation   u64
}

fn new_diagnostics_scheduler() &DiagnosticsScheduler {
	return &DiagnosticsScheduler{
		generations: map[string]u64{}
		project_generations: map[string]u64{}
		pending_jobs: map[string]DiagnosticsJob{}
		diag_results: map[string]DiagCacheEntry{}
		project_results: map[string]ProjectDiagResult{}
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
	return scheduler.begin_project_mutation(project_key, uri)
}

// begin_project_mutation invalidates pending and active jobs in a project. A
// non-empty requested_uri also schedules diagnostics for that document.
fn (mut scheduler DiagnosticsScheduler) begin_project_mutation(project_key string, requested_uri string) []DiagnosticsTicket {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	mut affected := map[string]bool{}
	if requested_uri != '' {
		affected[requested_uri] = true
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

fn (mut scheduler DiagnosticsScheduler) is_generation_current(global_generation u64) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	return scheduler.global_generation == global_generation
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
	mut ready := []DiagnosticsJob{}
	if scheduler.active_uri == '' {
		for _, job in scheduler.pending_jobs {
			if job.ready_at <= now {
				ready << job
			}
		}
		for job in ready {
			scheduler.pending_jobs.delete(job.uri)
		}
		if ready.len > 0 {
			first := ready[0]
			scheduler.active_uri = first.uri
			scheduler.active_project_key = first.project_key
			scheduler.active_generation = first.generation
		}
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

// cached_diag returns scheduler-cached checker errors for `uri` when they were
// computed for exactly this content hash and project generation. The cache is
// populated whenever a diagnostics job (or a synchronous check) publishes, so
// repeat requests such as reopening or re-saving an unchanged file reuse the
// result instead of spawning another `v` process.
fn (mut scheduler DiagnosticsScheduler) cached_diag(uri string, content_hash int, generation int) ?[]JsonError {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	if entry := scheduler.diag_results[uri] {
		if entry.content_hash == content_hash && entry.generation == generation {
			return entry.errors
		}
	}
	return none
}

fn (mut scheduler DiagnosticsScheduler) store_diag(uri string, content_hash int, generation int, errors []JsonError) {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	scheduler.diag_results[uri] = DiagCacheEntry{
		content_hash: content_hash
		generation: generation
		errors: errors
	}
}

fn (mut scheduler DiagnosticsScheduler) store_project_diag(key string, generation int, errors []JsonError, temp_root string, temp_work_dir string, source_display_root string) {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	scheduler.project_results[key] = ProjectDiagResult{
		generation: generation
		errors: errors
		temp_root: temp_root
		temp_work_dir: temp_work_dir
		source_display_root: source_display_root
	}
}

fn (mut scheduler DiagnosticsScheduler) cached_project_diag(key string, generation int) ?ProjectDiagResult {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	if entry := scheduler.project_results[key] {
		if entry.generation == generation {
			return entry
		}
	}
	return none
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
			tickets: scheduler.begin_project_mutation(project_key, '')
		}
	}
	return DiagnosticsProjectMutation{}
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
			overlay_store: app.overlay_cache_store
			scheduler: app.diagnostics_scheduler
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

// publish_group_if_current publishes one file's share of a batched project
// check. The result was compiled from the latest snapshot, so per-file and
// per-project generations are not rechecked; a shutdown or a closed document
// still suppresses the publish.
fn (mut scheduler DiagnosticsScheduler) publish_group_if_current(mut app App, job DiagnosticsJob, notification Notification) bool {
	scheduler.mutex.lock()
	defer {
		scheduler.mutex.unlock()
	}
	if scheduler.global_generation != job.global_generation {
		return false
	}
	if job.uri !in app.open_files {
		return false
	}
	app.write_notification(notification)
	return true
}

// run_diagnostics_batch compiles one shared project snapshot for a group of
// same-project jobs and publishes per-file results. Opening N files schedules
// N jobs for one project; without batching each would run a full `v check`
// serially even though a single project check answers all of them.
fn run_diagnostics_batch(mut scheduler DiagnosticsScheduler, group []DiagnosticsJob) {
	mut leader_idx := 0
	for i, job in group {
		if job.project_generation > group[leader_idx].project_generation
			|| (job.project_generation == group[leader_idx].project_generation
			&& job.generation > group[leader_idx].generation) {
			leader_idx = i
		}
	}
	leader := group[leader_idx]
	if !scheduler.is_generation_current(leader.global_generation) {
		for job in group {
			scheduler.finish(job)
		}
		return
	}
	log('diagnostics batch: project=${leader.project_key} jobs=${group.len}')
	temp_dir := os.join_path(os.temp_dir(), 'vls_diag_${os.getpid()}_${leader.generation}_${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or {
		for job in group {
			scheduler.finish(job)
		}
		return
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut versions := map[string]i64{}
	if version := leader.version {
		versions[leader.uri] = version
	}
	mut worker := App{
		text: leader.content
		open_files: leader.open_files
		open_files_versions: versions
		temp_dir: temp_dir
		diagnostics_enabled: true
		diag_cache: map[string]DiagCacheEntry{}
		project_generations: leader.project_generations
		position_encoding: leader.position_encoding
		write_mutex: leader.write_mutex
		tcp_conn: leader.tcp_conn
		overlay_cache_store: leader.overlay_store
		diagnostics_scheduler: leader.scheduler
	}
	leader_errors := worker.run_v_check(leader.uri, leader.content)
	leader_key := worker.generation_key(leader.uri)
	leader_gen := worker.project_generation(leader.uri)
	for job in group {
		scheduler.finish(job)
	}
	content_hash := leader.content.hash()
	if entry := worker.diag_cache[leader.uri] {
		if entry.content_hash == content_hash && entry.generation == leader_gen {
			scheduler.store_diag(leader.uri, content_hash, leader_gen, entry.errors)
		}
	}
	notification := worker.build_diagnostics_notification_for_errors(leader.uri, leader.content, leader_errors)
	scheduler.publish_if_current(mut worker, leader, notification)
	project_errors := scheduler.cached_project_diag(leader_key, leader_gen)
	for job in group {
		if job.uri == leader.uri {
			continue
		}
		proj := project_errors or {
			if scheduler.is_job_current(job) {
				run_diagnostics_job(mut scheduler, job)
			}
			continue
		}
		member_content := leader.open_files[job.uri] or {
			if scheduler.is_job_current(job) {
				run_diagnostics_job(mut scheduler, job)
			}
			continue
		}
		if member_content != job.content {
			if scheduler.is_job_current(job) {
				run_diagnostics_job(mut scheduler, job)
			}
			continue
		}
		member_overlay := CompilationOverlay{
			temp_root: proj.temp_root
			temp_work_dir: proj.temp_work_dir
			source_display_root: proj.source_display_root
		}
		filtered := filter_v_errors_to_file(proj.errors, member_overlay, uri_to_path(job.uri))
		member_hash := job.content.hash()
		member_gen := job.project_generations[job.project_key]
		scheduler.store_diag(job.uri, member_hash, member_gen, filtered)
		mut member_versions := map[string]i64{}
		if version := job.version {
			member_versions[job.uri] = version
		}
		mut member_app := App{
			text: job.content
			open_files_versions: member_versions
			position_encoding: job.position_encoding
			diagnostics_enabled: true
		}
		member_notification := member_app.build_diagnostics_notification_for_errors(job.uri, job.content, filtered)
		scheduler.publish_group_if_current(mut worker, job, member_notification)
	}
}

fn run_diagnostics_worker(mut scheduler DiagnosticsScheduler) {
	for {
		time.sleep(diagnostics_worker_poll)
		jobs, should_stop := scheduler.take_ready_jobs(time.now().unix_milli())
		if should_stop {
			return
		}
		mut groups := map[string][]DiagnosticsJob{}
		for job in jobs {
			mut g := groups[job.project_key] or { []DiagnosticsJob{} }
			g << job
			groups[job.project_key] = g
		}
		for _, group in groups {
			if group.len == 1 {
				run_diagnostics_job(mut scheduler, group[0])
				scheduler.finish(group[0])
			} else {
				run_diagnostics_batch(mut scheduler, group)
			}
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
		text: job.content
		open_files: job.open_files
		overlay_cache_store: job.overlay_store
		diagnostics_scheduler: job.scheduler
		open_files_versions: versions
		temp_dir: temp_dir
		diagnostics_enabled: true
		diag_cache: map[string]DiagCacheEntry{}
		project_generations: job.project_generations
		position_encoding: job.position_encoding
		write_mutex: job.write_mutex
		tcp_conn: job.tcp_conn
	}
	content_hash := job.content.hash()
	gen := job.project_generations[job.project_key]
	v_errors := if cached_errors := scheduler.cached_diag(job.uri, content_hash, gen) {
		log('Reusing scheduler-cached diagnostics for ${job.uri}')
		cached_errors
	} else {
		worker.run_v_check(job.uri, job.content)
	}
	notification := worker.build_diagnostics_notification_for_errors(job.uri, job.content, v_errors)
	// Mirror the worker's cache decision into the scheduler cache: the entry
	// is present exactly when the check was cacheable (no timeout or crash),
	// so the scheduler learns the same rule without a signature change.
	if entry := worker.diag_cache[job.uri] {
		if entry.content_hash == content_hash && entry.generation == gen {
			scheduler.store_diag(job.uri, content_hash, gen, entry.errors)
		}
	}
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
	if !scheduler.is_job_current_locked(job) {
		return false
	}
	app.write_notification(notification)
	return true
}
