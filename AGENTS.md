# AGENTS Guide for vls — concise rules for automated agents

Purpose
- Short, actionable rules for automated agents working in this repository.

High level
- vls is the V Language Server, which provides diagnostics and code actions for V code.

Build & test (development)
- Build: from repo root run `v .` (do not use `-o` during normal development).
  - If there are multiple source files in the project, do NOT compile them individually.
    For example, do not run `v <file>` for `.v` files in a multi-file project.
    Always use `v .` from the repo root to ensure all dependencies and types are resolved.
  - Do NOT rebuild the project if only `_test` files were changed.

# V struct JSON attributes
- Use `@[json]` attributes only when a field name does not exactly match the JSON name.

Mandatory guardrails (enforced for all agent work)
 - Add `2>&1` to commands so all output is captured.
 - Keep `.md` lines ≤ 100 characters.
 - Use `//` for V doc comments — do NOT use `///` or `/**`.
 - Use `[T]` style for generics - do NOT use `<T>` or other styles.
 - Do NOT create repository-local temporary files; use subdirectories under `/tmp` or another
   out-of-repo location for any artifacts you must write.
 - Avoid module-level mutable globals in repository source code; prefer struct fields or explicit
   parameters.

End of agent rules.
