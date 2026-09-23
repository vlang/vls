## VLS - V Language Server

Build with: `v .`

Place the vls binary in your `PATH`. For example, on Linux you can place it in `/usr/local/bin`. On
Windows, you can place it in a directory that is included in your `PATH`
environment variable.

Otherwise, you can set the path to the vls binary in your editor's settings.

### Installing VLS for your editor

- [Sublime Text](#sublime-text)

- [VS Code](#vs-code)

[Other editor?][EDITORS.md]

### Sublime Text

1. Build VLS with `v .` and place the resulting `vls` binary in your `PATH`.
2. In Sublime Text, open `Package Control: Install Package` from the Command Palette and install
   both `V` (for the `source.v` syntax) and `LSP`.
3. Open `Preferences > Package Settings > LSP > Server Configurations` and add this to
   `Packages/User/LanguageServers.sublime-settings`:

```json
{
  "vls": {
    "enabled": true,
    "command": ["vls"],
    "selector": "source.v"
  }
}
```

If `vls` is not in Sublime Text's `PATH`, replace it with the absolute path to the binary. If the
V compiler is not in that `PATH` either, use absolute paths and add `VLS_V_COMMAND`:

```json
{
  "vls": {
    "enabled": true,
    "command": ["/absolute/path/to/vls"],
    "selector": "source.v",
    "env": {
      "VLS_V_COMMAND": "/absolute/path/to/v"
    }
  }
}
```

Open a folder containing a V project, then open a `.v` file. The Sublime status bar should show
that VLS has started. Use `Tools > Developer > Show Scope Name` to confirm that the file's base
scope is `source.v` if the server does not start.

### VS Code

Install the
[V extension](https://marketplace.visualstudio.com/items?itemName=vlanguage.vscode-vlang)
from the Visual Studio Marketplace. Its source and build instructions are in
[vlang/vscode-vlang](https://github.com/vlang/vscode-vlang).

Build VLS with `v .` and make the `vls` binary available in VS Code's `PATH`, or set
`v.vls.command` to its path. Set `v.executablePath` if the V compiler is not on that `PATH`.

The extension includes `V: Build`, `V: Run`, and `V: Test` in the Command Palette and in
`Tasks: Run Task`. Runnable CodeLens actions show their output in a task terminal. Test tasks
also visualize line coverage; set `v.vls.coverage.enabled` to `false` to turn that off.

### Features

#### Instant errors

<img width="1932" height="432" alt="image" src="https://github.com/user-attachments/assets/a842e103-b3c2-427f-956f-fffff07970dc" />

#### Go to definition

https://github.com/user-attachments/assets/fb4ee6ff-4765-46b7-a21e-267691253d8e

#### Autocomplete for module functions

<img width="1246" height="592" alt="image" src="https://github.com/user-attachments/assets/0d4e1849-2e6c-47f8-9a45-322fe25d9bef" />

#### Information about function parameters

<img width="1494" height="450" alt="image" src="https://github.com/user-attachments/assets/46cc391b-fcdc-4083-ab62-97edd815ddd9" />

#### Autocomplete for struct fields and methods

<img width="1804" height="392" alt="image" src="https://github.com/user-attachments/assets/478bfd20-201a-476f-88cd-583fad52d6cc" />
