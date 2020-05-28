# vls
V Language Server

## Current Status
vls is still a work-in-progress. Transport methods such as via STDIO and via TCP have been implemented but haven't been able to communicate with the client and vice versa successfully. If you have experience working with language servers, please let us know by submitting an issue.

## Development
To start working with vls, you need to have git and the latest version of [V](https://github.com/vlang/v) installed. Then do the following:
```
git clone https://github.com/vlang/vls.git && cd vls/

# Build the project
v -o vls .

# Run the server
./vls

# or in TCP mode which will open in a fixed port of 23556.
./vls -tcp
```

## Roadmap
- [ ] Queue support (support for cancelling requests)

### General
- [x] `initialize`
- [x] `initialized`
- [x] `shutdown`
- [x] `exit`
- [ ] `$/cancelRequest` (VLS does not support request cancellation yet.)
### Window
- [ ] `showMessage`
- [ ] `showMessageRequest`
- [ ] `logMessage`
### Telemetry
- [ ] `event`
### Client
- [ ] `registerCapability`
- [ ] `unregisterCapability`
### Workspace
- [ ] `workspaceFolders`
- [ ] `didChangeWorkspaceFolder`
- [ ] `didChangeConfiguration`
- [ ] `configuration`
- [ ] `didChangeWatchedFiles`
- [ ] `symbol`
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
- [x] `publishDiagnostics`
### Language Features
- [ ] `completion`
- [ ] `completion resolve`
- [ ] `hover`
- [ ] `signatureHelp`
- [ ] `declaration`
- [ ] `definition`
- [ ] `typeDefinition`
- [ ] `implementation`
- [ ] `references`
- [ ] `documentHighlight`
- [ ] `documentSymbol`
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
    
    
    
    

