# VLS roadmap — from gopls / rust-analyzer / zls comparison

Decisions (2026-10-08): foundation first, support a V version
range (not lockstep), aim for full gopls-grade refactors last.
See COMPARISON.md for the evidence behind each phase.

## Phase 0 — baselines (current)

Add opt-in timing logs, no behavior change by default.
Set `VLS_PERF_LOG=1` to collect numbers.

- `request method=<m> elapsed_ms=<n>` per position request.
- `diagnostics uri=<u> elapsed_ms=<n>` per diagnostics job.
- Collect p50/p95 on 3 repos (self, small app, vlib-heavy)
  before any Phase 1 change. Record below.

Baselines (`VLS_PERF_LOG=1`, sampler sleeps 8s between
edits; first sample cold, rest warm; loaded box):

- small (16-line file, own project): completion warm 3-112ms,
  diagnostics warm 250-310ms (cold 2184ms)
- medium (main.v, vls project): completion warm 22-140ms,
  diagnostics warm 1528-1625ms (cold 5102ms)
- heavy (handlers.v, vls project): completion warm 63-205ms,
  diagnostics warm 1580-1694ms (cold 5059ms)

Reading: diagnostics cost is project-size dominated — a
one-line edit re-checks the whole program (~1.6s warm for
vls itself). That is the Phase 1 target.

## Phase 1a — done (2026-10-08): fast/slow tiers

Every edit schedules two jobs: fast (index-only unknown-import
check, 150ms debounce) and slow (full compiler check, 800ms
debounce). The slow answer replaces the fast one; a fast error
the slow check drops is cleared by the replacement publish.
Empty fast answers publish nothing, so clean files see zero
extra traffic. New code: fast_diagnostics.v, tiered scheduler.

Measured (`Temp/opencode/vls-sample.py`, fixed harness):

- bad import: fast 0-28ms (`unknown module`, quickfix-ready),
  slow ~1.1s (full compiler errors) right after, every edit.
- clean files: fast finds nothing, slow unchanged
  (small 315-358ms, vls project ~1.5-1.6s).
- Server-mode note: with the diagnostics server on, the first
  check pays ~2s server start + builtin parse; with
  `VLS_DIAGNOSTICS_SERVER=off` the first check was 285ms and
  warm checks identical (~270ms). Server value is unproven
  for small projects; revisit in Phase 1b.

Harness lesson: the first sampler never drained stdout, so the
~4KB pipe filled mid-run and the server blocked mid-write —
whole edits "vanished". Discard any run whose message count
disagrees with the protocol; the sampler now drains
continuously into a file.

## Phase 1b — done (2026-10-08): persistent fingerprint cache

`run_v_check` fingerprints the program (compiler id + sorted
per-file content hashes, buffers winning over disk) before touching
the overlay or the compiler. Identical states reuse the answer from
memory, or from a per-program JSON file under the OS cache dir,
across restarts. New code: diag_cache.v. Two adjacent fixes fell out:
a missing compiler panicked the spawn path (now an ordinary error
result), and the disk save first keyed on a different root than the
load (unified on the program dir).

Measured: reopening this repo unchanged serves diagnostics in ~15ms
from disk instead of ~5s cold (~340x). Clean-file traffic unchanged.

Known environment failure (pre-existing, verified on the pristine
base): `test_conditional_methods_request_receiver_completion_fallback`
needs the V1 compatibility compiler, which this host cannot build
(`make` missing).

## Phase 1c — done: pooled line-info, fast parse errors, compat matrix

- `run_v_line_info_once` answers from the shared diagnostics-server
  pool first (same copy the slow check uses), one-shot fallback
  preserved; compat/missing modes untouched.
- Fast tier also reports certain parse errors (stray closers,
  unclosed delimiters/strings/comments at EOF); mid-keystroke
  states stay silent.
- Compiler-compatibility matrix tests: modern-direct, old-flag,
  and dead-end stub compilers assert probed mode, diagnostics,
  and mode stability.

## Phase 1 — foundation (remaining)

- Split diagnostics: fast (parse + open-file errors, ~100ms
  debounce) vs slow (workspace check after ~1s idle).
- Persistent export-summary cache across restarts; only
  re-check importers whose summary changed.
- Per-request cancellation + completion budget (~100-200ms)
  that shrinks scope instead of failing.
- Compat matrix test: old/mid/new compiler stubs.

## Phase 2 — navigation / hints parity

- Fuzzy workspace symbols (trigram index): DONE — per-symbol
  trigram caches in index entries, overlap then match-class
  ranking, case/underscore insensitive, capped per symbol.
- Granular inlay-hint toggles, conservative defaults: DONE —
  `vls.inlayHints.variableTypes` / `.parameterNames`, both
  default on, runtime toggle, no restart.
- Richer hover (const values, methods, doc links).

## Phase 3 — refactors (partial)

- Safe rename: DONE — refuses names already live in the
  enclosing scope (locals, parameters, import aliases, outer
  scopes a nested reference would capture) and names that are
  members of an interface, naming the conflict.
- Fill struct literal quickfix: DONE (assists.v) — missing
  fields added with zero values, existing ones untouched;
  skipped for unknown types and complete literals.
- Extract function/variable, inline, stub-missing-members:
  NOT started.

## Phase 5 — finish or drop stubs: DONE

Advertised now they are implemented and tested: range formatting
(emits a hunk only inside the requested range), inline values
(type of a `:=` literal). Linked editing was same-line text
matching — replaced with the occurrence set a rename would edit,
across files, and advertised. On-type formatting stays
unadvertised by design (would run `v fmt` per keystroke);
file-operation hooks and willSave remain unadvertised no-ops.
