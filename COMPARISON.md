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

- Incrementality: all three peers beat vls (export
  summaries / Salsa / per-module units vs full re-check).
- Diagnostics tiers: peers split fast/slow; vls is one-tier.
- Refactors: gopls and rust-analyzer offer extract/inline/
  fill/struct assists with safety checks; vls has 2 actions
  (remove unknown import, contiguous organizeImports).
- Rename safety: gopls checks shadowing + interface
  satisfaction; vls refuses on incomplete scope only.
- Config: zls layers editor > `zls.json` (+ schema) >
  per-build file; vls relies on `VLS_V_COMMAND`/`VFLAGS`.
- Compat: zls chose lockstep; vls probes compiler modes
  (`unknown/direct/compat/missing`) for a version range.

## Criticism (what to fix, in roadmap order)

1. No real incrementality — full re-check per keystroke.
2. One-tier diagnostics — latency or staleness, no middle.
3. Index masks compiler gaps instead of measuring them.
4. Refactors are text edits, not semantic operations.
5. Config is env-var folklore (`VFLAGS`-in-shell).
6. Dispatched stubs (inlineValue literals-only,
   same-line linkedEditing, empty onTypeFormatting).
7. No perf budget or observability story.

## Sources

- https://go.dev/gopls/ and /features/, /workspace/, /settings/
- https://go.dev/blog/gopls-scalability
- https://rust-analyzer.github.io/book/ (features, assists,
  diagnostics, architecture, non_cargo_based_projects)
- https://github.com/zigtools/zls and https://zigtools.org/zls/
- vls tree: index.v, interop.v, diagnostics_scheduler.v,
  diagnostics_server.v, handlers.v, main.v, v3_line_info.v
