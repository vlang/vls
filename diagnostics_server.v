module main

import os
import sync
import time

#include <signal.h>

fn C.kill(pid int, sig int) int

// V3 can stay alive between diagnostics runs. Started with V_DIAGNOSTICS_SERVER
// set, it parses builtin once and answers each `check` line in a forked child
// that finishes the one-shot run of the same command line, printing the same
// diagnostics in a fraction of the time. A server answers for one command line
// run in one directory, so the files it checks live at paths that stay the same
// from one run to the next (see stable_dir).
@[heap]
struct DiagnosticsServerPool {
mut:
	mutex       sync.Mutex
	servers     map[string]&DiagnosticsServer
	unsupported map[string]bool
	requests    u64
	// The directory of the files its servers check, which no other pool uses:
	// the editors one VLS serves over TCP, and the checks and the questions of
	// one editor, neither write nor remove each other's files.
	base string
}

struct DiagnosticsServer {
mut:
	process     &os.Process = unsafe { nil }
	leftover    string
	last_used   i64
	fingerprint string
}

const diagnostics_server_ready = 'v-diagnostics-server: ready'
const diagnostics_server_end = 'v-diagnostics-server: end '
const diagnostics_server_child = 'v-diagnostics-server: child '
// diagnostics_check_cancelled is the exit code of a check stopped because a
// newer one made its answer useless: no diagnostics, and no one-shot fallback.
const diagnostics_check_cancelled = -2
// Parsing builtin takes a moment; a check of a large project can take longer.
const diagnostics_server_start_ms = 20000
const diagnostics_server_answer_ms = 60000
// A question comes from an editor waiting on it, a hover or a definition.
const v3_query_answer_ms = 15000
// Each server keeps builtin parsed in memory; a few cover the projects in use.
const diagnostics_server_limit = 3

fn new_diagnostics_server_pool() &DiagnosticsServerPool {
	mut pool := &DiagnosticsServerPool{}
	// Its address tells it apart from every other pool alive in this VLS.
	pool.base = os.join_path(os.temp_dir(), 'vls_diagnostics_${os.getpid()}_${ptr_str(pool)}')
	return pool
}

// check runs the compiler with `args` in `work_dir` through a server, starting
// one for this command line when needed. It returns none when no server can
// answer, which leaves the caller to run the compiler itself.
fn (mut pool DiagnosticsServerPool) check(exe string, args []string, work_dir string, cancelled fn () bool) ?os.Result {
	return pool.request(exe, args, work_dir, '', diagnostics_server_answer_ms, cancelled)
}

// query asks the server for this command line a question of the mini-VLS
// protocol, `<file>:<line>:<code><column>`, as `-line-info` does, and returns
// the answer as the output of the request.
fn (mut pool DiagnosticsServerPool) query(exe string, args []string, work_dir string, question string) ?os.Result {
	return pool.request(exe, args, work_dir, question, v3_query_answer_ms, fn () bool {
		return false
	})
}

// request sends a `check`, or a `query` of `question` when there is one, and
// waits `timeout_ms` for the answer.
fn (mut pool DiagnosticsServerPool) request(exe string, args []string, work_dir string, question string, timeout_ms int, cancelled fn () bool) ?os.Result {
	key := '${exe}\n${work_dir}\n${args.join('\n')}'
	// The compiler reads v.mod and .vvmrc once, before it forks, so a server
	// started before they changed can never answer again: a new one replaces it.
	fingerprint := project_config_fingerprint(work_dir)
	pool.mutex.lock()
	defer {
		pool.mutex.unlock()
	}
	if pool.unsupported['${key}\n${fingerprint}'] {
		return none
	}
	if mut outdated := pool.servers[key] {
		if outdated.fingerprint != fingerprint {
			outdated.stop()
			pool.servers.delete(key)
		}
	}
	mut server := pool.servers[key] or {
		pool.evict_least_recently_used()
		mut started := start_diagnostics_server(exe, args, work_dir) or {
			log('no diagnostics server for ${work_dir}: ${err}')
			pool.unsupported['${key}\n${fingerprint}'] = true
			return none
		}
		started.fingerprint = fingerprint
		pool.servers[key] = started
		started
	}
	pool.requests++
	token := '${os.getpid()}-${pool.requests}-${time.now().unix_nano()}'
	line := if question == '' { 'check ${token}' } else { 'query ${token} ${question}' }
	result := server.ask(line, token, timeout_ms, cancelled) or {
		log('the diagnostics server stopped answering: ${err}')
		server.stop()
		pool.servers.delete(key)
		return none
	}
	server.last_used = time.now().unix_milli()
	// A child killed by a signal leaves no diagnostics to trust, so the caller
	// runs the compiler itself for this check. The server stays: it is the
	// parent, and it is fine.
	if result.exit_code >= 128 && result.exit_code != diagnostics_check_cancelled {
		log('the diagnostics server child died with ${result.exit_code}; running the compiler instead')
		return none
	}
	return result
}

fn (mut pool DiagnosticsServerPool) evict_least_recently_used() {
	if pool.servers.len < diagnostics_server_limit {
		return
	}
	// Every question about a directory goes to the server of its program, `.`;
	// the one of a test file, a program of its own, serves while a rename or a
	// request about that file lasts. Such a server goes first.
	mut oldest_key := pool.least_recently_used(false)
	if oldest_key == '' {
		oldest_key = pool.least_recently_used(true)
	}
	if mut server := pool.servers[oldest_key] {
		server.stop()
	}
	pool.servers.delete(oldest_key)
}

// least_recently_used returns the key of the server used longest ago, the
// servers of the program of a directory, `.`, included only when `programs`.
fn (pool &DiagnosticsServerPool) least_recently_used(programs bool) string {
	mut oldest_key := ''
	mut oldest := i64(0)
	for key, server in pool.servers {
		if !programs && key.ends_with('\n.') {
			continue
		}
		if oldest_key == '' || server.last_used < oldest {
			oldest_key = key
			oldest = server.last_used
		}
	}
	return oldest_key
}

// stop_all ends every server and removes the files they checked.
fn (mut pool DiagnosticsServerPool) stop_all() {
	pool.mutex.lock()
	defer {
		pool.mutex.unlock()
	}
	for _, mut server in pool.servers {
		server.stop()
	}
	pool.servers.clear()
	os.rmdir_all(pool.base) or {}
}

fn start_diagnostics_server(exe string, args []string, work_dir string) !&DiagnosticsServer {
	mut p := os.new_process(exe)
	// The memory watchdog runs on a thread of its own, and a server forks only
	// while the worker pools are the sole threads.
	mut full := ['-no-memory-limit']
	full << args
	p.set_args(full)
	p.set_work_folder(work_dir)
	mut env := os.environ()
	env['V_DIAGNOSTICS_SERVER'] = '1'
	p.set_environment(env)
	p.set_redirect_stdio()
	p.run()
	mut server := &DiagnosticsServer{
		process: p
	}
	greeting := server.read_until(diagnostics_server_ready, diagnostics_server_start_ms) or {
		output := server.leftover
		server.stop()
		return error('the compiler does not serve diagnostics: ${output#[..160]}')
	}
	if !greeting.contains(diagnostics_server_ready) {
		server.stop()
		return error('unexpected greeting: ${greeting#[..160]}')
	}
	return server
}

// ask sends the request `line`, which carries `token`, and returns what the
// child printed and its exit code. The answer ends on
// `v-diagnostics-server: end <code> <token>`, with a token fresh for every
// request, so a diagnostic that quotes a source line holding the marker text
// cannot end the answer early.
fn (mut s DiagnosticsServer) ask(line string, token string, timeout_ms int, cancelled fn () bool) !os.Result {
	if s.process == unsafe { nil } || !s.process.is_alive() {
		return error('the diagnostics server is gone')
	}
	s.process.stdin_write('${line}\n')
	// The server names the child first; a newer check stops it.
	child_line := s.read_until(' ${token}\n', timeout_ms) or {
		return error('no answer within ${timeout_ms} ms')
	}
	if !child_line.contains(diagnostics_server_child) {
		return error('malformed start of answer: ${child_line#[..80]}')
	}
	child_start := child_line.last_index(diagnostics_server_child) or { 0 }
	child_pid := child_line[child_start + diagnostics_server_child.len..].all_before(' ').int()
	// Unbuffered output of the child can come before the line that names it.
	early_output := child_line[..child_start]
	suffix := ' ${token}\n'
	answer, was_cancelled := s.read_until_or_cancel(suffix, timeout_ms, fn [cancelled, child_pid] () bool {
		if !cancelled() {
			return false
		}
		$if !windows {
			C.kill(child_pid, 9)
		}
		return true
	}) or { return error('no answer within ${timeout_ms} ms') }
	collected := early_output + answer
	if was_cancelled {
		return os.Result{
			exit_code: diagnostics_check_cancelled
		}
	}
	suffix_start := collected.index(suffix) or { return error('malformed answer') }
	line_start := (collected[..suffix_start].last_index('\n') or { -1 }) + 1
	end_line := collected[line_start..suffix_start]
	if !end_line.starts_with(diagnostics_server_end) {
		return error('malformed end of answer: ${end_line#[..80]}')
	}
	mut output := collected[..line_start]
	// The server starts its end line on a line of its own.
	if output.ends_with('\n') {
		output = output[..output.len - 1]
	}
	return os.Result{
		exit_code: end_line[diagnostics_server_end.len..].int()
		output:    output
	}
}

// read_until_or_cancel is read_until that calls `poll` every few milliseconds
// while it waits, until `poll` reports that it cancelled the check, and returns
// whether it did.
fn (mut s DiagnosticsServer) read_until_or_cancel(marker string, timeout_ms int, poll fn () bool) ?(string, bool) {
	mut collected := s.leftover
	s.leftover = ''
	watch := time.new_stopwatch()
	mut last_poll := i64(0)
	mut cancelled := false
	for !collected.contains(marker) {
		if s.process == unsafe { nil } {
			return none
		}
		chunk := s.process.stdout_read()
		if chunk != '' {
			collected += chunk
			continue
		}
		if !s.process.is_alive() {
			s.leftover = collected
			return none
		}
		elapsed := watch.elapsed().milliseconds()
		if elapsed > timeout_ms {
			s.leftover = collected
			return none
		}
		if !cancelled && elapsed - last_poll >= 2 {
			last_poll = elapsed
			cancelled = poll()
		}
		time.sleep(100 * time.microsecond)
	}
	after := (collected.index(marker) or { collected.len }) + marker.len
	if after < collected.len {
		s.leftover = collected[after..]
	}
	return collected[..after], cancelled
}

// project_config_fingerprint names the v.mod and .vvmrc files the compiler
// finds from `dir` upwards, with their size and time of change.
fn project_config_fingerprint(dir string) string {
	mut parts := []string{}
	mut current := dir
	for _ in 0 .. 64 {
		for name in ['v.mod', '.vvmrc'] {
			path := os.join_path(current, name)
			if os.exists(path) {
				parts << '${path}:${os.file_size(path)}:${os.file_last_mod_unix(path)}'
			}
		}
		parent := os.dir(current)
		if parent == current || parent == '' {
			break
		}
		current = parent
	}
	return parts.join(';')
}

// read_until collects output until `marker` shows up and returns it, keeping
// whatever came after the marker for the next read. `os.Process.stdout_read`
// does not wait for data, so this waits for it, and gives up rather than
// hanging the diagnostics worker.
fn (mut s DiagnosticsServer) read_until(marker string, timeout_ms int) ?string {
	mut collected := s.leftover
	s.leftover = ''
	watch := time.new_stopwatch()
	for !collected.contains(marker) {
		if s.process == unsafe { nil } {
			return none
		}
		chunk := s.process.stdout_read()
		if chunk != '' {
			collected += chunk
			continue
		}
		if !s.process.is_alive() {
			s.leftover = collected
			return none
		}
		if watch.elapsed().milliseconds() > timeout_ms {
			s.leftover = collected
			return none
		}
		time.sleep(100 * time.microsecond)
	}
	after := (collected.index(marker) or { collected.len }) + marker.len
	if after < collected.len {
		s.leftover = collected[after..]
	}
	return collected[..after]
}

// stop ends the server: the `quit` line lets it finish on its own, and one that
// is already gone is just released.
fn (mut s DiagnosticsServer) stop() {
	if s.process == unsafe { nil } {
		return
	}
	if s.process.is_alive() {
		s.process.stdin_write('quit\n')
		// A server that does not end, as one whose child hangs, is killed:
		// waiting for it would freeze VLS.
		for _ in 0 .. 100 {
			if !s.process.is_alive() {
				break
			}
			time.sleep(10 * time.millisecond)
		}
		if s.process.is_alive() {
			s.process.signal_kill()
		}
		s.process.wait()
	}
	s.process.close()
	s.process = unsafe { nil }
}

// resolve_diagnostics_server_exe picks the compiler that answers checks and
// queries from one process: VLS_DIAGNOSTICS_SERVER names it, or turns the
// servers off with `off`, and otherwise it is the V in use. A V without a
// server, or where it cannot run one, finishes as a one-shot check without
// saying it is ready, and VLS then starts a compiler for every check.
fn resolve_diagnostics_server_exe() ?string {
	from_env := os.getenv('VLS_DIAGNOSTICS_SERVER')
	if from_env == 'off' {
		return none
	}
	if from_env != '' {
		return if os.exists(from_env) { from_env } else { none }
	}
	v_exe := resolve_v_compiler_exe()
	return if os.exists(v_exe) { v_exe } else { none }
}

// stable_dir returns the directory that stands for `source` in every check run
// through a server of this pool. A one-shot run can use a fresh directory each
// time; a server cannot, since its input was fixed when it started.
fn (pool &DiagnosticsServerPool) stable_dir(kind string, source string) string {
	return os.join_path(pool.base, '${kind}_${source.hash().hex()}')
}

// stop_diagnostics_servers ends the servers the diagnostics worker used.
fn (mut app App) stop_diagnostics_servers() {
	if mut scheduler := app.diagnostics_scheduler {
		scheduler.servers.stop_all()
	}
}
