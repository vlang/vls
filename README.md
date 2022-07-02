> ## ⚠️ Warning (Please read this first) ⚠️
> What you're seeing is the developmental branch of the V Language server. This means that it may not be guaranteed to work reliably on your system.
>
> If you are experiencing problems, please consider [filing a bug report](#error-reporting).

# V Language Server
[![CI](https://github.com/vlang/vls/actions/workflows/ci.yml/badge.svg)](https://github.com/vlang/vls/actions/workflows/ci.yml)

V Language Server (also known as "VLS") is a LSP v3.15-compatible language server for [the V programming language](https://github.com/vlang/v).

# Download / Installation
### Pre-built/Precompiled Binaries (Recommended)
Pre-built binaries for Windows (x64), MacOS (x64/M1), and Linux (x64) can be found [here](https://github.com/vlang/vls/releases/latest).

### VSCode
The official [V VSCode extension](https://github.com/vlang/vscode-vlang) provides a way to automatically download and install VLS by checking the "Enable VLS" in the extension settings in which a message prompt will appear for you to install VLS.

### Build from Source
> **NOTE**: TCC, the default compiler shipped with V, is not recommended ATM due to
> some issues in the Tree Sitter's output.

To build the language server from source, you need to have the following:
- GCC/Clang (Latest),
- [Git](https://git-scm.com/download)
- [V](https://github.com/vlang/v) (0.2.2 and later).

> **NOTE**: If you are downloading V from [Homebrew](https://brew.sh) 
> and other community-maintained packages, please do `v up` first
> before proceeding.

Linux and MacOS users are also expected to install the Boehm GC library.
- For Debian/Ubuntu users: `sudo apt-get install libgc-dev`
- For MacOS (via Homebrew): `brew install bdw-gc`

Afterwards, open your operating system's terminal and execute the following:
```
## Clone the project:
git clone https://github.com/vlang/vls && cd vls

## Build the project
## Use " v run build.vsh gcc" if you're compiling VLS with GCC.
v run build.vsh clang

# The binary will be created in the current root directory `vls`.
```

## Setup / Usage
To use the language server, you need to have an editor with [LSP](https://microsoft.github.io/language-server-protocol/) support. See [this link](https://microsoft.github.io/language-server-protocol/implementors/tools/) for a full list of supported editors.

### VSCode, VSCodium, and other derivatives
> [GitHub Web Editor](https://github.dev) is not supported yet at this moment. See this [issue comment](https://github.com/vlang/vscode-vlang/issues/272#issuecomment-898271911).

For [Visual Studio Code](https://code.visualstudio.com) and other derivatives, all you need to do is to install 0.1.4 or above versions of the [V VSCode extension](https://github.com/vlang/vscode-vlang). Afterwards, go to settings and scroll to the V extension section. From there, enable VLS by checking the "Enable VLS" box.

If you have VLS downloaded in a custom directory, you need to input the absolute path of the `vls` language server executable to the "Custom Path" setting. If you cloned the repository and compiled it from source, the executable will be in the `vls` root directory. So make sure to add `vls/bin/vls` or `vls/bin/vls.exe` (for Windows).

![Instructions](images/instructions.png)

### Sublime Text (3 and 4)
For Sublime Text, please install the [LSP extension](https://packagecontrol.io/packages/LSP) via [Package Control](https://packagecontrol.io). Afterwards, open the command palette, select `Preferences: LSP Settings`, and add the following configuration:
```json
{
    "clients": {
        "vls": {
            "enabled": true,
            "command": ["<vls-dir>/vls"],
            "selector": "source.v"
        }
    }
}
```

If you cloned the repository and compiled it from source, the executable will be in the `vls` root directory. So make sure to set the `command` array to `vls/bin/vls` or `vls/bin/vls.exe` (for Windows).

### Vim
For Vim, please install [vim-lsp](https://github.com/prabirshrestha/vim-lsp) and [vim-lsp-settings](https://github.com/mattn/vim-lsp-settings). Afterwards, open any `.v` file, and execute `:LspInstallServer`.

### Other Editors
> VLS on JetBrain IDEs does not work at this moment. See [issue 52](https://github.com/vlang/vls/issues/52) for more details.

For other editors, please refer to the plugin's/editor's documentation for instructions on how to setup an LSP server connection.

## Roadmap
- [ ] Queue support (support for cancelling requests)

### General
- [x] `initialize` (Activates features based on VSCode's capabilities for now.)
- [x] `initialized`
- [x] `shutdown`
- [x] `exit`
- [ ] `$/cancelRequest`
<!-- - [ ] `$/progress` -->
### Window
- [x] `showMessage`
- [x] `showMessageRequest`
- [x] `logMessage`
- [ ] `progress/create`
- [ ] `progress/cancel`
### Telemetry
- [ ] `event` (Implemented but not usable)
### Client
- [ ] `registerCapability`
- [ ] `unregisterCapability`
### Workspace
- [ ] `workspaceFolders`
- [ ] `didChangeWorkspaceFolder`
- [ ] `didChangeConfiguration`
- [ ] `configuration`
- [x] `didChangeWatchedFiles`
- [x] `symbol`
- [ ] `executeCommand`
- [ ] `applyEdit`
### Text Synchronization
- [x] `didOpen`
- [x] `didChange`
- [ ] `willSave`
- [ ] `willSaveWaitUntil`
- [x] `didSave`
- [x] `didClose`
### Diagnostics
- [x] `publishDiagnostics`
### Language Features
- [x] `completion`
- [ ] `completion resolve`
- [x] `hover`
- [x] `signatureHelp`
- [ ] `declaration`
- [x] `definition`
- [ ] `typeDefinition`
- [x] `implementation`
- [ ] `references`
- [ ] `documentHighlight`
- [x] `documentSymbol`
- [ ] `codeAction`
- [ ] `codeLens`
- [ ] `codeLens resolve`
- [ ] `documentLink`
- [ ] `documentLink resolve`
- [ ] `documentColor`
- [ ] `colorPresentation`
- [x] `formatting`
- [ ] `rangeFormatting`
- [ ] `onTypeFormatting`
- [ ] `rename`
- [ ] `prepareRename`
- [x] `foldingRange`

## Crash Reporting
When reporting a crash in the language server, you just need to copy the contents of the latest auto-generated error which can be found in the home directory (`C:\Users\<user_name>\.vls\reports` for Windows, `/home/<user_name>/.vls/reports` for Linux, and `/Users/<user_name>/.vls/reports` for MacOS). The contents of the file can be then pasted into the [issue tracker form](https://github.com/vlang/vls/issues/new).

Bugs that are not crashes however can still generate report by passing the `--generate-report` flag to the language server CLI.

## Debugging
VLS provides a log file (`${workspacePath}/vls.log`) for debugging the language server incoming requests and outgoing responses / notifications. By default, this can only be saved and accessed on server crash. To save the log on every exit, pass the `--debug` flag to the language server CLI.

# Contributing
## Submitting a pull request
- Fork it (https://github.com/vlang/vls/fork)
- Create your feature branch (git checkout -b my-new-feature)
- Commit your changes (git commit -am 'Add some feature')
- Push to the branch (git push origin my-new-feature)
- Create a new Pull Request

# Contributors
- [nedpals](https://github.com/nedpals) - creator and maintainer
- [danieldaeschle](https://github.com/danieldaeschle) - maintainer
- [hungrybluedev](https://github.com/hungrybluedev) - contributor
- [streaksu](https://github.com/streaksu) - contributor
- [ylluminarious](https://github.com/ylluminarious) - contributor
- [yuyi98](https://github.com/yuyi98) - contributor
