module lsp

// method: ‘initialize’
// response: InitializeResult
// notes: should be map[string]string
pub struct InitializeParams {
pub mut:
	process_id int [json:processId]
	client_info ClientInfo [json:clientInfo]
	root_uri string [json:rootUri]
	root_path string [json:rootPath]
	initialization_options string [raw;json:initializationOptions]
	capabilities ClientCapabilities
	trace string
	workspace_folders []WorkspaceFolder [json:workspaceFolders]
}

pub struct ClientInfo {
pub mut:
	name string [json:name]
	version string [json:version]
}

pub struct InitializeResult {
	capabilities ServerCapabilities
}

// method: ‘initialized’
// notification
// pub struct InitializedParams {}

pub enum InitializeErrorCode {
	unknown_protocol_version = 1
}

pub struct InitializeError {
	retry bool
}

/**
 * The kind of resource operations supported by the client.
 */
pub enum ResourceOperationKind {
	create 
	rename 
	delete
}

pub enum FailureHandlingKind {
	abort
	transactional
	undo
	text_only_transactional
}

// TextDocumentSyncKind
pub enum TextDocumentSyncKind {
	@none = 0
	full = 1
	incremental = 2
}

pub struct ExecuteCommandOptions {
	commands []string
}

pub struct StaticRegistrationOptions {
	id string
}

// method: ‘shutdown’
// response: none

// method: ‘exit’
// response: none