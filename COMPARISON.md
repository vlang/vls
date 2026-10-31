# Language-server comparison: gopls, rust-analyzer, zls vs vls

Why these three: Go is V's syntactic parent, Rust is the
aspirational maturity target, Zig is the closest lifecycle
peer (young systems language, breaking compiler).

## Architecture

- gopls: per-package summaries, persistent file cache,
  pruned invalidation (skip importers when exports
  unchanged). Two-tier diagnostics (instant + deferred vet).
- rust-analyzer: Salsa queries over ItemTree/DefMap/Body;
  laziness first, incrementality second; proc-macros and
  flycheck out-of-process; per-request cancellation.
- zls: per-file `std.zig.Ast` + heuristic semantics (no
  full comptime); strict 1:1 version lock with Zig; custom
  build runner; opt-in build-on-save via a `check` step.
- vls: per-file token index + full project re-check;
  shell-free compiler argv + overlay; scheduler + pool
  of max 3 diagnostic servers; index-first fallbacks.

## Feature gap summary

Measured against the tree as of the last pass over it. What this
branch closed is marked; what stands is kept as it was found.

- Incrementality: all three peers beat vls (export
  summaries / Salsa / per-module units vs full re-check).
  Still open — a change confined to a function body now
  checks that file's module rather than the whole tree,
  and a slow check is reused from a per-program
  fingerprint cache, but the unit of re-check is still a
  program, not an item.
- Diagnostics tiers: peers split fast/slow. **Closed** —
  each edit schedules a fast index-only check (150ms
  debounce) and the full compiler check (800ms idle),
  and the slow answer replaces the fast one.
- Refactors: gopls and rust-analyzer offer extract/inline/
  fill/struct assists with safety checks; vls has 2 actions
  (remove unknown import, contiguous organizeImports).
  **Closed** — ten actions, all gated on a kind filter and
  a shape check: quick fixes for a diagnostic, organize
  imports, fill struct literal, extract or inline a
  variable, extract function, add an import, implement
  missing members, move a declaration to a module of its
  own, and structural search and replace.
- Rename safety: gopls checks shadowing + interface
  satisfaction; vls refuses on incomplete scope only.
  **Closed** — rename refuses names that shadow a binding
  or break an interface, and renames an interface's
  members across its implementors.
- Config: zls layers editor > `zls.json` (+ schema) >
  per-build file; vls relies on `VLS_V_COMMAND`/`VFLAGS`.
  **Closed** — editor settings > project `vls.json` >
  `VLS_DEFINES`, with the schema published and defines
  salted into the diagnostics fingerprint.
- Compat: zls chose lockstep; vls probes compiler modes
  (`unknown/direct/compat/missing`) for a version range.
  Still true, and the missing-compat case is reported
  rather than answered emptily.

## Criticism (what to fix, in roadmap order)

1. No real incrementality — the cached answer is per
   program and per fingerprint, not per item.
2. One-tier diagnostics — **closed** by the two-tier
   scheduler above.
3. Index masks compiler gaps instead of measuring them —
   still open.
4. Refactors are text edits, not semantic operations —
   still open for the text edits; the structural replace
   is deliberately scope-negative and refuses rather than
   guesses, and rename now checks the scope it moves into.
5. Config is env-var folklore (`VFLAGS`-in-shell) —
   **closed** by layered configuration.
6. Dispatched stubs (inlineValue literals-only,
   same-line linkedEditing, empty onTypeFormatting) —
   **closed**; all three are implemented and advertised.
7. No perf budget or observability story — partly closed:
   `VLS_PERF_LOG=1` logs a per-stage breakdown of a slow
   check, first measurement being the compiler run at 97
   percent of it. A budget is still undecided.

## Sources

- https://go.dev/gopls/ and /features/, /workspace/, /settings/
- https://go.dev/blog/gopls-scalability
- https://rust-analyzer.github.io/book/ (features, assists,
  diagnostics, architecture, non_cargo_based_projects)
- https://github.com/zigtools/zls and https://zigtools.org/zls/
- vls tree: index.v, interop.v, diagnostics_scheduler.v,
  diagnostics_server.v, handlers.v, main.v, v3_line_info.v
