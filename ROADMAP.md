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

## Phase 1 — foundation

- Split diagnostics: fast (parse + open-file errors, ~100ms
  debounce) vs slow (workspace check after ~1s idle).
- Persistent export-summary cache across restarts; only
  re-check importers whose summary changed.
- Per-request cancellation + completion budget (~100-200ms)
  that shrinks scope instead of failing.
- Compat matrix test: old/mid/new compiler stubs.

## Phase 2 — navigation / hints parity

- Fuzzy workspace symbols (trigram index).
- Granular inlay-hint toggles, conservative defaults.
- Richer hover (const values, methods, doc links).

## Phase 3 — full refactors

- Safe rename (shadowing, interface satisfaction).
- Extract function/variable, inline, fillStruct/fillSwitch,
  stub-missing-members. Each with before/after doc-tests.

## Phase 4 — build / config UX

- Layered config: settings > `vls.json` (+ schema) >
  per-project overrides > env. `defines: [...]`
  replaces `VFLAGS`-in-shell folklore.
- Fast `v check`-only mode vs full build (zls check-step).

## Phase 5 — finish or drop stubs

Implement or unadvertise: range-formatting, on-type
formatting, file-op hooks, inlineValue, linkedEditing.
