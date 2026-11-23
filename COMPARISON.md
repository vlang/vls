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
- vls: per-file source index, immediate buffer diagnostics and a debounced compiler check.
  V's Linux diagnostics server can reuse parsed libraries and unchanged function checks.
  Other platforms use one-shot checks by default.

## Measured latency against gopls

Build VLS with `v .` and install `gopls` using the official Go instructions.
[Gopls installation](https://go.dev/gopls/)

```sh
python3 benchmarks/lsp_latency.py --vls ./vls --gopls gopls
```

The harness generates equivalent Go and V programs with 30 declarations per sibling file.
It times stdio round trips on fresh server processes and measures warm requests before and after
unsaved edits. It checks that completion includes the expected function, hover describes it, and
definition points to its sibling file. Diagnostic timing requires the expected error or an empty
clearing publish for the current document version. The percentiles cover elapsed wall time,
including debounce, transport and compiler startup.

The recorded runs used an Apple Silicon Mac under heavy concurrent load, V 0.5.2
(`60a5e1f`), Go 1.27.4, and `gopls` v0.24.0. Each configuration used two fresh
processes, 30 warm samples per request, and three edit rounds per process. The baseline
was VLS `41a7973`, using a compiler wrapper that lets its type diagnostics use the same
compiler's default checker. Both VLS runs used one-shot checks.

Times are p50 / p95 in milliseconds. The two startup samples report their maximum as p95.

### 1 sibling file (30 declarations)

| Operation | VLS before | VLS after | gopls |
| --- | ---: | ---: | ---: |
| Initialize | 139.93 / 258.75 | 140.89 / 269.02 | 361.82 / 635.43 |
| First completion | 4215.52 / 4319.76 | 3185.85 / 3311.57 | 604.29 / 812.09 |
| Completion | 2.68 / 431.31 | 3.61 / 79.45 | 0.76 / 1.71 |
| Hover | 1008.42 / 1660.20 | 1.52 / 33.11 | 0.27 / 0.59 |
| Definition | 1.10 / 3.75 | 1.18 / 77.34 | 0.20 / 0.96 |
| Edit + completion | 172.88 / 1057.82 | 125.41 / 633.35 | 2.48 / 3.25 |
| Edit + hover | 2.99 / 482.70 | 5.76 / 28.38 | 2.80 / 33.68 |
| Edit + definition | 18.37 / 263.34 | 8.14 / 67.74 | 10.13 / 17.59 |
| Syntax diagnostic | 152.44 / 165.21 | 52.55 / 96.64 | 3.97 / 32.68 |
| Syntax recovery | 2769.52 / 4105.08 | 22.91 / 62.38 | 2.98 / 48.59 |
| Type diagnostic | 2414.82 / 2705.21 | 2164.09 / 2707.84 | 3.32 / 10.62 |
| Type recovery | 3270.42 / 3774.65 | 2562.20 / 3740.97 | 1.69 / 2.77 |

### 40 sibling files (1200 declarations)

| Operation | VLS before | VLS after | gopls |
| --- | ---: | ---: | ---: |
| Initialize | 14.32 / 16.45 | 15.57 / 16.87 | 35.51 / 37.58 |
| First completion | 4018.40 / 4550.71 | 2665.43 / 2708.19 | 305.63 / 313.59 |
| Completion | 11.76 / 574.03 | 16.67 / 168.40 | 16.53 / 153.17 |
| Hover | 1223.95 / 1664.10 | 7.31 / 135.90 | 0.58 / 20.83 |
| Definition | 7.35 / 28.61 | 3.46 / 59.82 | 0.30 / 11.26 |
| Edit + completion | 352.51 / 711.76 | 18.33 / 377.21 | 46.30 / 202.10 |
| Edit + hover | 7.63 / 100.89 | 3.62 / 253.63 | 12.97 / 71.01 |
| Edit + definition | 69.10 / 156.19 | 3.04 / 4.84 | 10.61 / 21.90 |
| Syntax diagnostic | 172.04 / 212.96 | 0.31 / 108.53 | 8.96 / 14.97 |
| Syntax recovery | 3521.59 / 3819.06 | 0.23 / 21.58 | 8.18 / 29.17 |
| Type diagnostic | 3220.24 / 3421.67 | 3086.63 / 3654.23 | 8.96 / 24.44 |
| Type recovery | 3703.04 / 4237.89 | 3175.39 / 4094.13 | 8.30 / 15.01 |

The larger fixture reached similar warm completion latency and lower median completion and
navigation latency immediately after an edit. Cold completion, warm hover and definition,
and type diagnostics still have measurable gaps. The high p95 values also vary across
successive runs on this host.

A compiler trace for the small fixture parsed about 29,500 lines across 100 files during
a one-shot check. An isolated macOS experiment that reused a prepared compiler reduced
median end-to-end type diagnostic latency to 555 ms on the small fixture and 2,205 ms
on the larger fixture. The isolated prototype used the existing server protocol with one
compiler worker. The tables above use the stock compiler.

### First completion and interactive type diagnostics

VLS returns indexed completion items while it discovers optional auto-imports in a
background worker. The completion list is marked incomplete while the scan runs.
Explicit import completions and requests with no matching indexed items still
search for imports before responding.

The fast diagnostics tier reports unresolved bare call arguments when it can check
their source scope, and incompatible scalar literals in explicitly typed returns.
The full compiler handles the remaining cases and supplies the authoritative result.

Run the two workloads separately on the same VLS build.

```sh
python3 benchmarks/lsp_latency.py --type-error undefined-name --samples 8 --runs 9 --edits 5
python3 benchmarks/lsp_latency.py --type-error return-type --samples 8 --runs 9 --edits 5
```

On the same Apple Silicon Mac with V 0.5.2 (`60a5e1f`), Go 1.27.4, and
`gopls` v0.24.0, each workload and project size used nine fresh server processes
per language and 45 edits. First completion validates a sibling declaration.
The diagnostic benchmark waits for an error at the edited line and version.
The cold p95 is the maximum of nine samples. Times are p50 / p95 in milliseconds.

| Declarations | Operation | VLS | gopls |
| ---: | --- | ---: | ---: |
| 30 | First completion (undefined name fixture) | 5.17 / 16.05 | 244.10 / 281.20 |
| 30 | Undefined name diagnostic | 0.57 / 15.91 | 1.11 / 2.30 |
| 30 | Undefined name recovery | 0.29 / 0.84 | 1.18 / 3.62 |
| 1200 | First completion (undefined name fixture) | 34.80 / 88.15 | 279.69 / 366.88 |
| 1200 | Undefined name diagnostic | 2.76 / 13.54 | 8.49 / 120.64 |
| 1200 | Undefined name recovery | 0.35 / 24.08 | 8.59 / 37.99 |
| 30 | First completion (return mismatch fixture) | 8.83 / 59.26 | 347.05 / 503.79 |
| 30 | Return mismatch diagnostic | 0.46 / 22.64 | 1.54 / 11.51 |
| 30 | Return mismatch recovery | 0.56 / 29.68 | 1.72 / 14.18 |
| 1200 | First completion (return mismatch fixture) | 87.52 / 180.34 | 344.68 / 389.25 |
| 1200 | Return mismatch diagnostic | 0.56 / 40.97 | 9.12 / 69.81 |
| 1200 | Return mismatch recovery | 0.63 / 30.69 | 9.31 / 74.88 |

First completion and both type diagnostics had lower median latency on both fixtures.
The small fixture's diagnostic p95 was higher during this run under heavy concurrent load.

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
  each edit schedules an immediate buffer check and the compiler check after 75ms idle.
  The compiler's answer replaces the early result.
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
