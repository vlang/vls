# VLS VS Code Extension

This extension integrates the V Language Server (VLS) with Visual Studio Code. It provides
diagnostics, completion, navigation, inlay hints, runnable CodeLens actions, and built-in V tasks.

## Installation

1. Build the VLS binary from the repository root:

   ```sh
   v .
   ```

2. Build the VS Code extension:

   ```sh
   cd vscode-extension
   npm install
   npm run build
   ```

   Alternatively, download the `.vsix` from the
   [releases page](https://github.com/vlang/vls/releases).

3. In VS Code, run `Extensions: Install from VSIX...` and select the `.vsix` file.

## Build, run, and test

The extension supplies three tasks for every workspace folder:

- `V: Build` runs `v .`.
- `V: Run` runs `v run .`.
- `V: Test` runs `v test .`.

Open `Tasks: Run Task` to select one. The same actions are available as `V: Build`, `V: Run`, and
`V: Test` in the Command Palette (`Ctrl+Shift+P` on Linux and Windows).

The Command Palette actions use the active V file when useful: Run starts its containing module,
and Test runs the active `_test.v` file. Otherwise, they operate on the workspace folder.

`Run Main`, `Run File`, and `Run Test` CodeLens actions use these tasks too. Their terminal is
revealed automatically and displays the command, compiler output, stdout, stderr, and exit status.
The active file is saved before it runs so the terminal executes the source currently in the
editor.

## Configuration

Open VS Code settings and search for `vls`:

- **`vls.command`**: Path to the VLS binary. It is detected from `PATH` when unset.
- **`vls.args`**: Extra arguments passed to the VLS process.
- **`vls.vCommand`**: Path to the V compiler used by the language server and all build, run, test,
  and CodeLens tasks. It is detected from `PATH` when unset. Absolute paths, `~`, `${env:NAME}`,
  and `${workspaceFolder}` are supported. Reload VS Code after changing it.
- **`vls.inlayHints.enabled`**: Enable or disable inlay hints for V files (default: `true`).
- **`vls.diagnostics.enabled`**: Enable or disable live diagnostics (default: `true`).

Example `settings.json`:

```json
{
  "vls.command": "/path/to/vls",
  "vls.args": [],
  "vls.vCommand": "/path/to/v",
  "vls.inlayHints.enabled": true,
  "vls.diagnostics.enabled": true
}
```

## Troubleshooting

- Ensure the VLS and V binaries are executable.
- Set `vls.command` if VLS is not available through `PATH`.
- Set `vls.vCommand` if V is not available through the environment inherited by VS Code.
- CodeLens and task output is in the Terminal panel under a terminal named for the selected task.
- Language-server logs are in the Output panel under `V Language Server`.

## Updating

- After updating the VLS binary, restart VS Code or reload the window.
- To update the extension, rebuild and reinstall the `.vsix` file.

## License

VLS is licensed under GPL-2.0-only. See the
[repository license](https://github.com/vlang/vls/blob/master/LICENSE).
