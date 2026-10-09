## VLS - V Language Server

Build with: `v .`

Check the installed version with `vls --version` or `vls version`. Both print `VLS 0.0.3`
and exit without starting the server. LSP `initialize` reports the same version in `serverInfo`.

Place the vls binary in your `PATH`. For example, on Linux you can place it in `/usr/local/bin`. On
Windows, you can place it in a directory that is included in your `PATH`
environment variable.

Otherwise, you can set the path to the vls binary in your editor's settings.

### Installing VLS for your editor

- [Sublime Text](#sublime-text)

- [VS Code](#vs-code)

- [Zed](#zed)

[Other editor?](EDITORS.md)

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

### Code behind a compile-time flag

V compiles the code inside `$if flag ? { ... }` only when the program is built with `-d flag`.
VLS runs the compiler without defines, so that code used to get no errors, and hover and
go-to-definition found little or nothing in it. It now checks that code when the flag is given.

Set `vls.defines` in the editor's settings for VLS, naming the flag the code uses:

```json
"vls.defines": ["-d", "flag"]
```

The joined spelling, `["-dflag"]`, is accepted too. To keep the flag with the project rather than
in the editor, put a `vls.json` in the folder that holds the nearest `v.mod`:

```json
{ "defines": ["-d", "flag"] }
```

A `vls.json` may also set `inlayHints` and `diagnostics`, the two feature switches. The settings
the editor sends win over the project's file, and the file over `VLS_DEFINES` in the environment,
which also works for an editor with no settings of its own. The defines reach the checks only:
`v fmt`, hover, go-to-definition and completion run without them. The code inside
`$if !flag ? { ... }` is then the one left unchecked.

### Features

#### Instant errors

![image](https://github.com/user-attachments/assets/a842e103-b3c2-427f-956f-fffff07970dc)

#### Go to definition

https://github.com/user-attachments/assets/fb4ee6ff-4765-46b7-a21e-267691253d8e

#### Autocomplete for module functions

![image](https://github.com/user-attachments/assets/0d4e1849-2e6c-47f8-9a45-322fe25d9bef)

#### Information about function parameters

![image](https://github.com/user-attachments/assets/46cc391b-fcdc-4083-ab62-97edd815ddd9)

#### Autocomplete for struct fields and methods

![image](https://github.com/user-attachments/assets/478bfd20-201a-476f-88cd-583fad52d6cc)

### Zed

> NOTE: the Zed editor lacks first-party support for the V programming language.

1. Build VLS with `v .` and place the resulting `vls` binary in your `PATH`.
2. Open `Zed > Open Settings File` and add this to your settings file:

```json
{
  "languages": {
    "V": {
      "formatter": {
        "external": {
          "command": "vls",
          "arguments": ["-"]
        }
      }
    }
  }
}
```

or alternatively if the `vls` binary is NOT in your `PATH`:

```json
{
  "languages": {
    "V": {
      "formatter": {
        "external": {
          "command": "/absolute/path/to/vls",
          "arguments": ["-"]
        }
      }
    }
  }
}
```
