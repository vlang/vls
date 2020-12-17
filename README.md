# vls
VLS (V Language Server) is a LSP v3.15-compatible language server for V.

## Current Status
VLS is a work-in-progress. It has issues with memory management (for now) and may not be guaranteed to work on large codebases.

Windows support is also unstable for now. Please file an issue if you experience problems with it.

## Installation
Installation requires you to have Git and V installed and compile the language server by yourself. You need to execute the following:
```
git clone https://github.com/nedpals/vls2.git vls && cd vls/

# Build the project
v -prod cmd/vls
# The binary will be create in the subfolder by default
```

## Usage
In order to use the language server, you need to have a text editor with support for LSP. In this case, the recommended editor for testing (for now) is to have [Visual Studio Code](https://code.visualstudio.com) and the [vscode-vlang](https://github.com/vlang/vscode-vlang) extension version 0.1.4 or above installed.

![Instructions](instructions.png)

Afterwards, go to your editor's configuration and scroll to the V extension section. From there, enable VLS by checking the box and input the absolute path of where the language server is located.

## Roadmap
> Note: For now, symbols are recomputed during `didOpen`/`didSave`. On-demand recomputation will be implemented in the future.

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
- [ ] `symbol` (initial support)
- [ ] `executeCommand`
- [ ] `applyEdit`
### Text Synchronization
- [ ] `didOpen`
- [ ] `didChange`
- [ ] `willSave`
- [ ] `willSaveWaitUntil`
- [ ] `didSave`
- [ ] `didClose`
### Diagnostics
- [x] `publishDiagnostics` (initial support)
### Language Features
- [ ] `completion` (disabled for now)
- [ ] `completion resolve`
- [ ] `hover` (disabled for now)
- [ ] `signatureHelp`
- [ ] `declaration`
- [ ] `definition`
- [ ] `typeDefinition`
- [ ] `implementation`
- [ ] `references`
- [ ] `documentHighlight`
- [ ] `documentSymbol` (initial support)
- [ ] `codeAction`
- [ ] `codeLens`
- [ ] `codeLens resolve`
- [ ] `documentLink`
- [ ] `documentLink resolve`
- [ ] `documentColor`
- [ ] `colorPresentation`
- [ ] `formatting`
- [ ] `rangeFormatting`
- [ ] `onTypeFormatting`
- [ ] `rename`
- [ ] `prepareRename`
- [ ] `foldingRange`

# Contributing
## Submitting a pull request
- Fork it (https://github.com/nedpals/vls2/fork)
- Create your feature branch (git checkout -b my-new-feature)
- Commit your changes (git commit -am 'Add some feature')
- Push to the branch (git push origin my-new-feature)
- Create a new Pull Request

# Contributors
- [nedpals](https://github.com/nedpals) - creator and maintainer
- [danieldaeschle](https://github.com/danieldaeschle) - maintainer
