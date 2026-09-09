# Change Log

## 0.0.3 — Interim release (2026-09-10)

V development commands are now first-class VS Code tasks:

- `Run Main`, `Run File`, and `Run Test` CodeLens actions reveal a task terminal and stream the
  compiler and program output there.
- `V: Build`, `V: Run`, and `V: Test` are available in the Command Palette.
- `V: Build`, `V: Run`, and `V: Test` are preconfigured in `Tasks: Run Task` for each workspace
  folder.
- `vls.vCommand` selects the V compiler used by the language server, tasks, and CodeLens actions.
- V compiler errors and warnings emitted by tasks appear in VS Code's Problems panel.

This is an interim extension release intended to make the new runnable CodeLens support useful in
everyday development while the wider VLS feature set continues to evolve.
