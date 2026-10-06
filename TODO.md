# VLS Improvement Plan

## Phase 1 — High Impact, Achievable

- [ ] Fuzzy matching for completions
- [ ] Postfix completions (`.if`, `.match`, `.for`, `.ptr`, `.unwrap`)
- [ ] More code actions (extract variable, extract function, generate method, flip binary)
- [ ] Snapshot testing infrastructure

## Phase 2 — Medium Impact, Medium Effort

- [ ] Completion budget system
- [ ] Static analysis integration
- [ ] Configuration expansion (matcher, diagnostics delay, inlay hints, file watcher)
- [ ] Better file watching (server-side with fsnotify/poll fallback)

## Phase 3 — High Impact, High Effort

- [ ] Incremental computation framework
- [ ] Disk-based caching
- [ ] SSR (Structural Search and Replace)
- [ ] Proc-macro/build script isolation
