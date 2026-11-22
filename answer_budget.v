// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

const answer_budget_ms = 50

// answer_budget_key identifies a measured compiler answer. The cost can differ
// by document and by method.
fn answer_budget_key(uri string, method Method) string {
	return '${uri}\x00${method}'
}

// compiler_answer_is_held reports whether a pending or active diagnostics job
// may delay a compiler-backed hover beyond its budget. Measurements come from
// requests that needed the compiler.
fn (mut app App) compiler_answer_is_held(uri string, method Method) bool {
	if !app.diagnostics_enabled_for_uri(uri) {
		return false
	}
	mut scheduler := app.diagnostics_scheduler or { return false }
	if !scheduler.check_in_flight(uri) {
		return false
	}
	return !app.compiler_answer_is_quick(uri, method)
}

fn (app &App) compiler_answer_is_quick(uri string, method Method) bool {
	elapsed_ms := app.compiler_answer_ms[answer_budget_key(uri, method)] or { return false }
	return elapsed_ms in 0 .. answer_budget_ms
}

fn (mut app App) note_compiler_answer(uri string, method Method, elapsed_ms i64) {
	if elapsed_ms >= 0 {
		app.compiler_answer_ms[answer_budget_key(uri, method)] = elapsed_ms
	}
}
