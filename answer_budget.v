// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

// answer_budget_ms is what a compiler answer may cost before answering a request
// twice is what a held check makes worthwhile. gopls answers a request from what
// it already knows when the authoritative answer would take longer than a budget,
// and replaces that answer when it arrives. Below the budget the wait is shorter
// than a second popup, so the compiler's answer is waited for instead.
const answer_budget_ms = 50

// AnswerFollowup is the answer a held compiler owes a request the index has
// already answered.
struct AnswerFollowup {
	id        int
	raw_id    string
	method    Method
	uri       string
	position  Position
	line_info string
}

// answer_budget_key names a measured answer: one document and one method, since
// an answer that is quick in one file is not thereby quick in another.
fn answer_budget_key(uri string, method Method) string {
	return '${uri}\x00${method}'
}

// schedule_answer_followup defers the compiler's answer to a request that the
// index has already answered, when that answer is held: a diagnostics check for
// the document waits or runs, and the last answer measured for it was not quick
// enough to make asking twice cheaper than waiting. Nothing is scheduled
// otherwise, so a request the compiler answers in time is answered once.
// Completion is never deferred: its index answer and the compiler's differ in
// ways that make a stale list confusing.
fn (mut app App) schedule_answer_followup(method Method, request Request, uri string, position Position, line_info string) {
	if !app.compiler_answer_is_held(uri, method) {
		return
	}
	// The session outlives the request, so the thread shares it: the pooled
	// compilers it asks through and the transport it writes on are the ones the
	// request itself would have used.
	mut session := &app
	app.answer_followups.add(1)
	spawn run_answer_followup(mut session, AnswerFollowup{
		id:        request.id
		raw_id:    app.current_request_raw_id
		method:    method
		uri:       uri
		position:  position
		line_info: line_info
	})
}

// run_answer_followup asks the compiler for the answer the index gave and writes
// it in place of that one, on the same request id. It runs on a thread of its own
// so the request it belongs to is not held by the compiler the check holds.
fn run_answer_followup(mut app App, followup AnswerFollowup) {
	defer {
		app.answer_followups.done()
	}
	started_ms := time.now().unix_milli()
	result := app.compiler_answer(followup.method, followup.uri, followup.position,
		followup.line_info)
	app.note_compiler_answer(followup.uri, followup.method, time.now().unix_milli() - started_ms)
	app.write_deferred_response(followup.id, followup.raw_id, Response{
		id:     followup.id
		result: result
	})
}

// compiler_answer_is_held reports whether the compiler's answer for the document
// at `uri` is held: a diagnostics check for it waits for its debounce or already
// runs, and the last answer measured for it and this method was not quick enough
// to make asking twice cheaper than waiting.
fn (app &App) compiler_answer_is_held(uri string, method Method) bool {
	if !app.diagnostics_enabled {
		return false
	}
	scheduler := app.diagnostics_scheduler or { return false }
	if !scheduler.check_in_flight(uri) {
		return false
	}
	return !app.compiler_answer_is_quick(uri, method)
}

// compiler_answer_is_quick reports whether the compiler answered this document
// and this method in under the budget the last time it was asked: then its
// answer costs no more than the index's and must not be doubled.
fn (app &App) compiler_answer_is_quick(uri string, method Method) bool {
	elapsed_ms := app.compiler_answer_ms[answer_budget_key(uri, method)] or { return false }
	return elapsed_ms in 0 .. answer_budget_ms
}

// note_compiler_answer records what the compiler's answer for the document at
// `uri` cost, so the next question about it knows whether to answer twice.
fn (mut app App) note_compiler_answer(uri string, method Method, elapsed_ms i64) {
	if elapsed_ms < 0 {
		return
	}
	app.compiler_answer_ms[answer_budget_key(uri, method)] = elapsed_ms
}

// wait_answer_followups joins the threads that replace an index answer with the
// compiler's. They ask through the pooled compilers and write on the transport,
// so both must outlive the request loop that scheduled them and be joined
// before the session stops them.
fn (mut app App) wait_answer_followups() {
	app.answer_followups.wait()
}
