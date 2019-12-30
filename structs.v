module main

type DocumentUri string

// struct NotificationMessage {
//     method string
//     params map[string]string
// }

// // method: $/cancelRequest
struct CancelParams {
    id int
}

struct Position {
    line int
    character int
}

struct Range {
    start Position
    end Position
}

struct Location {
    uri string
    range Range
}

struct LocationLink {
	origin_selection_range Range [json:originSelectionRange]
	target_uri string [json:targetUri]
	target_range Range [json:targetRange]
	target_selection_range Range [json:targetSelectionRange]
}

struct Diagnostic {
	range Range
	severity int
	code string
	source string
	message string
	related_information []DiagnosticRelatedInformation [json:relatedInformation]
}

enum DiagnosticSeverity {
	zero
	error 
	warning 
	information 
	hint
}

struct WorkspaceFolder {
	uri DocumentUri
	name string
}

struct DiagnosticRelatedInformation {
	location Location
	message string
}

struct Command {
	title string
	command string
	arguments []string
}

struct TextEdit {
	range Range
	new_text string
}

// struct TextDocumentEdit {
// 	text_document Ve
// }

enum ResourceOperationKind {
	create rename delete
}

enum FailureHandlingKind {
	abort transactional undo text_only_transactional
}

enum Trace {
	off messages verbose
}

struct UserInitializationOptions {
	vroot_folder string [json:vrootFolder]
	lsp_location string [json:lspLocation]
}

// initializeParams
struct InitializeParams {
	process_id int [json:processId]
	root_uri string [json:rootUri]
	initialization_options UserInitializationOptions [json:initializationOptions]
	capabilities ClientCapabilities
	trace string
	workspace_folders []WorkspaceFolder [json:workspaceFolders]
}

// struct InitializedParams {

// }

struct ClientCapabilities {
	workspace WorkspaceClientCapabilities
	text_document TextDocumentClientCapabilities [json:textDocument]
}

struct WorkspaceClientCapabilities {
	apply_edit bool [json:applyEdit]
	workspace_edit WorkspaceEdit [json:workspaceEdit]
	did_change_configuration DidChange [json:didChangeConfiguration]
	did_change_watched_files DidChange [json:didChangeWatchedFiles]
	execute_command DidChange [json:executeCommand]
	workspace_folders bool [json:workspaceFolders]
	configuration bool
}

struct WorkspaceSymbol {
	dynamic_registration bool [json:dynamicRegistration]
	symbol_kind WorkspaceSymbolKind [json:symbolKind]
}

struct WorkspaceSymbolKind {
	value_set []SymbolKind [json:valueSet]
}

struct DidChange {
	dynamic_registration bool [json:dynamicRegistration]
}

struct WorkspaceEdit {
	document_changes bool [json:documentChanges]
	resource_operations []string [json:resourceOperations]
	failure_handling string [json:failureHandling]
}

struct TextDocumentClientCapabilities {
	synchronization TextDocumentSync
	completion  CompletionCapability
}

struct CompletionCapability {
	dynamic_registration bool [json:dynamicRegistration]
	completion_item CompletionItemSettings [json:completionItem]
	completion_item_kind CompletionItemKindSettings [json:completionItemKind]
	context_support bool [json:contextSupport]
} 

// struct HoverSettings {
// 	dynamic_registration bool [json:dynamicRegistration]
// 	content_format []MarkupKind [json:contentFormat]
// }

struct CompletionItemKindSettings {
	value_set []CompletionItemKind [json:valueSet]
}

struct CompletionItemSettings {
	snippet_support bool [json:snippetSupport]
	commit_characters_support bool [json:commitCharactersSupport]
	documentation_format bool [json:documentationFormat]
	preselect_support bool [json:preselectSupport]
}

enum CompletionItemKind {
	text = 1
	method = 2
	function = 3
	constructor = 4
	field = 5
	variable = 6
	class = 7
	@interface = 8
	@module = 9
	property = 10
	unit = 11
	value = 12
	@enum = 13
	keyword = 14
	snippet = 15
	color = 16
	file = 17
	reference = 18
	folder = 19
	enum_member = 20
	constant = 21
	@struct = 22
	event = 23
	operator = 24
	type_parameter = 25
}

enum SymbolKind {
	file = 1
	@module = 2
	namespace = 3
	package = 4
	class = 5
	method = 6
	property = 7
	field = 8
	constructor = 9
	@enum = 10
	@interface = 11
	function = 12
	variable = 13
	constant = 14
	string = 15
	number = 16
	boolean = 17
	array = 18
	object = 19
	key = 20
	null = 21
	enum_member = 22
	@struct = 23
	event = 24
	operator = 25
	type_parameter = 26
}

struct TextDocumentSync {
	dynamic_registration bool [json:dynamicRegistration]
	will_save bool [json:willSave]
	will_save_wait_until bool [json:willSaveWaitUntil]
	did_save bool [json:didSave]
}