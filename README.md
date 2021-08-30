> ## ⚠️ Warning (Please read this first) ⚠️
> What you're seeing is the developmental branch of the V Language server.This means that it may not be guaranteed to work reliably on your system.
>
> If you are experiencing problems, please consider [filing a bug report](https://github.com/vlang/vls/issues/new).

# V Language Server
[![CI](https://github.com/vlang/vls/actions/workflows/ci.yml/badge.svg)](https://github.com/vlang/vls/actions/workflows/ci.yml)

V Language Server (also known as "VLS") is a LSP v3.15-compatible language server for [the V programming language](https://github.com/vlang/v).

# Download / Installation
### Pre-built/Precompiled Binaries (Recommended)
Pre-built binaries for Windows x64, MacOS x64/M1 (via Rosetta), and Linux x64 can be found [here](https://github.com/vlang/vls/releases/latest). 

### VSCode
The official [V VSCode extension](https://github.com/vlang/vscode-vlang) provides a way to download/install VLS without manually downloading the source. If you installed the extension for the first time, a message prompt will appear for you to install VLS. Click "Yes" or "Install" and it will automatically do the setup process for you.

### Build from Source
> **NOTE**: TCC, the default compiler shipped with V, is not recommended ATM due to
> some issues in the Tree Sitter's output.

To build the language server from source, you need to have the following:
- GCC/Clang (Latest), 
- [Git](https://git-scm.com/download) 
- [V](https://github.com/vlang/v) (0.2.2 and later).

Linux users are also expected to install the Boehm GC library. (`sudo apt-get install libgc-dev` for Debian/Ubuntu users).

Afterwards, open your operating system's terminal and execute the following:
```
## Clone the project:
git clone https://github.com/vlang/vls && cd vls

## Build the project
## Use " v run build.vsh gcc" if you're compiling VLS with GCC.
v run build.vsh clang

# The binary will be created in the `cmd/vls` subfolder by default.
```

## Setup / Usage
To use the language server, you need to have an editor with [LSP](https://microsoft.github.io/language-server-protocol/) support. See [this link](https://microsoft.github.io/language-server-protocol/implementors/tools/) for a full list of supported editors and tools.

### VSCode, VSCodium, and other VSCode derivatives
> [GitHub Codespaces](https://github.dev) is not supported yet at this moment. See this [issue comment](https://github.com/vlang/vscode-vlang/issues/272#issuecomment-898271911).

For [Visual Studio Code](https://code.visualstudio.com) and other derivatives, all you need is to install 0.1.4 or above versions of the [V VSCode extension](https://github.com/vlang/vscode-vlang). Afterwards, go to settings and scroll to the V extension section. From there, enable VLS by checking the "Enable VLS" box. 

If you have VLS downloaded in a custom directory, you need to input the absolute path of the `vls` language server executable to the "Custom Path" setting. If you cloned the repository and compiled it from source, the executable will be in the `cmd/vls` directory. So make sure to add `cmd/vls/vls` or `cmd/vls/vls.exe` (for Windows).

![Instructions](images/instructions.png)

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
- [ ] `didChangeWatchedFiles`
- [x] `symbol`
- [ ] `executeCommand`
- [ ] `applyEdit`
### Text Synchronization
- [x] `didOpen`
- [x] `didChange`
- [ ] `willSave`
- [ ] `willSaveWaitUntil`
- [ ] `didSave`
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

## Debugging
> By default, log can only be accessed and saved on server crash.
To save the log on exit, pass the `--debug` flag to the language server CLI. 

VLS provides a log file (`${workspacePath}/vls.log`) for debugging language server for certain situations (e.g unexpected crash). To read the contents
of the `vls.log` file, simply upload the file to the [LSP Inspector](https://iwanabethatguy.github.io/language-server-protocol-inspector/) and select `vls.log`.

![LSP Inspector](images/inspector-output.png)

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
