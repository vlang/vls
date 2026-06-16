// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

// Request represents an LSP request sent from the client.
struct Request {
	id      int
	method  string
	jsonrpc string
	params  string // raw JSON for method-specific params
}

// Position represents a position in a text document (zero-based line and character).
struct Position {
	line int
	char int @[json: 'character']
}

// TextDocumentIdentifier identifies a text document by its URI.
struct TextDocumentIdentifier {
	uri string
}

// Params contains parameters for various LSP requests.
struct Params {
	content_changes []ContentChange @[json: 'contentChanges']
	position        Position
	range           LSPRange
	text_document   TextDocumentIdentifier @[json: 'textDocument']
	new_name        string                 @[json: 'newName']
}

// ContentChange represents a change to a document's content.
struct ContentChange {
	text         string
	range        ?LSPRange
	range_length ?int @[json: 'rangeLength']
}

// Response represents an LSP response sent to the client.
struct Response {
	id      int
	result  ResponseResult
	jsonrpc string = '2.0'
}

// ResponseError represents the JSON-RPC error payload.
struct ResponseError {
	code    int
	message string
}

// ErrorResponse represents an LSP/JSON-RPC error response.
struct ErrorResponse {
	id      int
	error   ResponseError
	jsonrpc string = '2.0'
}

// JSON-RPC error codes.
const jsonrpc_err_parse_error = -32700
const jsonrpc_err_invalid_request = -32600
const jsonrpc_err_method_not_found = -32601
const jsonrpc_err_invalid_params = -32602
const jsonrpc_err_internal_error = -32603
// LSP-specific error codes.
const jsonrpc_err_server_not_initialized = -32002
const jsonrpc_err_request_cancelled = -32800

// A Location represents a specific location in a file.
struct Location {
	uri   string
	range LSPRange
}

type ResponseResult = string
	| []Detail
	| CompletionList
	| Capabilities
	| SignatureHelp
	| Location
	| Hover
	| []Location
	| WorkspaceEdit
	| []TextEdit
	| []DocumentSymbol
	| []InlayHint
	| []CodeAction
	| []WorkspaceSymbol
	| PrepareRenameResult
	| SemanticTokens
	| []FoldingRange
	| []CallHierarchyItem
	| []CallHierarchyIncomingCall
	| []CallHierarchyOutgoingCall
	| []DocumentHighlight
	| []SelectionRange
	| []CodeLens
	| CodeLens
	| []InlineValueText
	| LinkedEditingRanges

// WorkspaceSymbol represents a symbol found across the workspace.
struct WorkspaceSymbol {
	name           string
	kind           int
	tags           ?[]int  @[json: 'tags']
	container_name ?string @[json: 'containerName']
	location       Location
}

// PrepareRenameResult is returned by textDocument/prepareRename to indicate the
// range and placeholder text for an upcoming rename operation.
struct PrepareRenameResult {
	range       LSPRange
	placeholder string
}

// DocumentSymbol represents a symbol in a document (e.g., function, class).
struct DocumentSymbol {
	name            string
	kind            int
	tags            ?[]int @[json: 'tags']
	range           LSPRange
	selection_range LSPRange @[json: 'selectionRange']
mut:
	children []DocumentSymbol
}

// LSP SymbolKind constants (see https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind)
const sym_kind_class = 5
const sym_kind_method = 6
const sym_kind_field = 8
const sym_kind_enum = 10
const sym_kind_interface = 11
const sym_kind_function = 12
const sym_kind_constant = 14
const sym_kind_enum_member = 22
const sym_kind_struct = 23

// LSP CodeActionKind constants
const code_action_kind_quickfix = 'quickfix'
const code_action_kind_source_organize_imports = 'source.organizeImports'

// Notification represents an LSP notification sent to the client.
struct Notification {
	method  string
	params  PublishDiagnosticsParams
	jsonrpc string = '2.0'
}

// PublishDiagnosticsParams contains diagnostics for a document.
struct PublishDiagnosticsParams {
	uri         string
	version     ?int
	diagnostics []LSPDiagnostic
}

// LSPDiagnostic represents a diagnostic, such as a compiler error or warning.
struct LSPDiagnostic {
	range    LSPRange
	message  string
	severity int
	source   ?string @[json: 'source'] // diagnostic source identifier, e.g. 'vlang'
	code     ?string @[json: 'code']   // optional diagnostic code, e.g. 'unused_variable'
	tags     ?[]int  @[json: 'tags']   // 1 = unnecessary, 2 = deprecated
}

// LSPRange represents a range in a text document.
struct LSPRange {
	start Position
	end   Position
}

// Detail represents a completion or symbol detail item.
struct Detail {
	kind               int    // The type of item (e.g., Method, Function, Field)
	label              string // The name of the completion item
	detail             string // Additional info like the function signature or return type
	declaration        string // Full fn declaration, e.g. "fn greet(name string) string"
	documentation      string // The documentation for the item
	sort_text          ?string @[json: 'sortText']   // sort key, defaults to label
	filter_text        ?string @[json: 'filterText'] // filter key, defaults to label
	insert_text        ?string @[json: 'insertText']
	insert_text_format ?int    @[json: 'insertTextFormat'] // 1 for PlainText, 2 for Snippet
	tags               ?[]int  @[json: 'tags']             // 1 = deprecated
	deprecated         ?bool   @[json: 'deprecated']       // legacy deprecated flag
}

// Capabilities describes the server's capabilities.
struct Capabilities {
	capabilities Capability
	server_info  ?ServerInfo @[json: 'serverInfo']
}

// ServerInfo identifies the server in the initialize response.
struct ServerInfo {
	name    string
	version ?string
}

// ExecuteCommandOptions lists commands the server supports.
struct ExecuteCommandOptions {
	commands []string
}

// RenameOptions advertises rename support. Setting prepare_provider = true means
// the server also supports textDocument/prepareRename (LSP §3.17 RenameOptions).
struct RenameOptions {
	prepare_provider bool @[json: 'prepareProvider']
}

// FileOperationFilter describes which files match a file operation.
struct FileOperationFilter {
	scheme  ?string
	pattern FileOperationPattern
}

// FileOperationPattern is a glob pattern for file operations.
struct FileOperationPattern {
	glob string
}

// FileOperationRegistrationOptions describes file operations the server wants to receive.
struct FileOperationRegistrationOptions {
	filters []FileOperationFilter
}

// WorkspaceFileOperations advertises server interest in workspace file operations.
struct WorkspaceFileOperations {
	will_create ?FileOperationRegistrationOptions @[json: 'willCreate']
	will_rename ?FileOperationRegistrationOptions @[json: 'willRename']
	will_delete ?FileOperationRegistrationOptions @[json: 'willDelete']
}

// WorkspaceFoldersServerCapability advertises support for workspace folders
// and runtime folder change notifications.
struct WorkspaceFoldersServerCapability {
	supported            bool
	change_notifications bool @[json: 'changeNotifications']
}

// WorkspaceCapability advertises workspace-level server features.
struct WorkspaceCapability {
	file_operations   ?WorkspaceFileOperations          @[json: 'fileOperations']
	workspace_folders ?WorkspaceFoldersServerCapability @[json: 'workspaceFolders']
}

// CodeLensOptions advertises server support for code lenses.
struct CodeLensOptions {
	resolve_provider ?bool @[json: 'resolveProvider']
}

// Capability lists supported LSP features for the server.
struct Capability {
	completion_provider                CompletionProvider       @[json: 'completionProvider']
	text_document_sync                 TextDocumentSyncOptions  @[json: 'textDocumentSync']
	signature_help_provider            SignatureHelpOptions     @[json: 'signatureHelpProvider']
	definition_provider                bool                     @[json: 'definitionProvider']
	declaration_provider               bool                     @[json: 'declarationProvider']
	type_definition_provider           bool                     @[json: 'typeDefinitionProvider']
	implementation_provider            bool                     @[json: 'implementationProvider']
	hover_provider                     bool                     @[json: 'hoverProvider']
	references_provider                bool                     @[json: 'referencesProvider']
	rename_provider                    RenameOptions            @[json: 'renameProvider']
	execute_command_provider           ExecuteCommandOptions    @[json: 'executeCommandProvider']
	document_formatting_provider       bool                     @[json: 'documentFormattingProvider']
	document_range_formatting_provider bool                     @[json: 'documentRangeFormattingProvider']
	document_symbol_provider           bool                     @[json: 'documentSymbolProvider']
	workspace_symbol_provider          bool                     @[json: 'workspaceSymbolProvider']
	inlay_hint_provider                bool                     @[json: 'inlayHintProvider']
	code_action_provider               bool                     @[json: 'codeActionProvider']
	code_lens_provider                 CodeLensOptions          @[json: 'codeLensProvider']
	inline_value_provider              bool                     @[json: 'inlineValueProvider']
	linked_editing_range_provider      bool                     @[json: 'linkedEditingRangeProvider']
	on_type_formatting_provider        ?OnTypeFormattingOptions @[json: 'documentOnTypeFormattingProvider']
	semantic_tokens_provider           SemanticTokensOptions    @[json: 'semanticTokensProvider']
	folding_range_provider             bool                     @[json: 'foldingRangeProvider']
	call_hierarchy_provider            bool                     @[json: 'callHierarchyProvider']
	document_highlight_provider        bool                     @[json: 'documentHighlightProvider']
	selection_range_provider           bool                     @[json: 'selectionRangeProvider']
	workspace                          WorkspaceCapability
	position_encoding                  ?string @[json: 'positionEncoding']
}

// OnTypeFormattingOptions describes the triggers for on-type formatting.
struct OnTypeFormattingOptions {
	first_trigger_character string   @[json: 'firstTriggerCharacter']
	more_trigger_characters []string @[json: 'moreTriggerCharacters']
}

// SemanticTokensLegend describes the token types and modifiers used by the server.
struct SemanticTokensLegend {
	token_types     []string @[json: 'tokenTypes']
	token_modifiers []string @[json: 'tokenModifiers']
}

// SemanticTokensOptions advertises semantic token support in server capabilities.
struct SemanticTokensOptions {
	legend SemanticTokensLegend
	full   bool
	range  bool
}

// SemanticTokens is the response payload for a semantic tokens request.
struct SemanticTokens {
	result_id ?string @[json: 'resultId'] // optional cache key for delta requests
	data      []int
}

// SemanticTokensParams holds parameters for the textDocument/semanticTokens/full request.
struct SemanticTokensParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
}

// FoldingRange represents a collapsible region in a text document.
struct FoldingRange {
	start_line int @[json: 'startLine']
	end_line   int @[json: 'endLine']
	kind       string // 'comment', 'imports', or 'region'
}

// FoldingRangeParams holds parameters for the textDocument/foldingRange request.
struct FoldingRangeParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
}

// CallHierarchyItem represents a function or method node in the call hierarchy.
struct CallHierarchyItem {
	name            string
	kind            int // SymbolKind: 12 = Function, 6 = Method
	uri             string
	range           LSPRange
	selection_range LSPRange @[json: 'selectionRange']
	detail          string
}

// CallHierarchyIncomingCall describes a caller of the queried function.
struct CallHierarchyIncomingCall {
	from        CallHierarchyItem
	from_ranges []LSPRange @[json: 'fromRanges']
}

// CallHierarchyOutgoingCall describes a function called by the queried function.
struct CallHierarchyOutgoingCall {
	to          CallHierarchyItem
	from_ranges []LSPRange @[json: 'fromRanges']
}

// PrepareCallHierarchyParams holds parameters for textDocument/prepareCallHierarchy.
struct PrepareCallHierarchyParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	position      Position
}

// CallHierarchyIncomingCallsParams holds parameters for callHierarchy/incomingCalls.
struct CallHierarchyIncomingCallsParams {
	item CallHierarchyItem
}

// CallHierarchyOutgoingCallsParams holds parameters for callHierarchy/outgoingCalls.
struct CallHierarchyOutgoingCallsParams {
	item CallHierarchyItem
}

// WorkspaceVlsSettings contains VLS-specific user configuration that affects
// server behaviour. Fields use optional types so that absent keys are ignored
// and existing values are not clobbered.
struct WorkspaceVlsSettings {
	inlay_hints ?bool @[json: 'inlayHints'] // enable / disable inlay type hints
	diagnostics ?bool // enable / disable live diagnostics
}

// WorkspaceInlayHintsSettings supports client payloads that send
// `settings.vls.inlayHints.enabled` as a nested object.
struct WorkspaceInlayHintsSettings {
	enabled ?bool
}

// WorkspaceVlsSettingsCompat mirrors WorkspaceVlsSettings but with nested
// inlay-hints shape used by some clients.
struct WorkspaceVlsSettingsCompat {
	inlay_hints WorkspaceInlayHintsSettings @[json: 'inlayHints']
	diagnostics ?bool
}

// WorkspaceSettings is the top-level object inside DidChangeConfigurationParams.
struct WorkspaceSettings {
	vls WorkspaceVlsSettings
}

// DidChangeConfigurationParams holds workspace settings sent by the client.
struct DidChangeConfigurationParams {
	settings WorkspaceSettings
}

// WorkspaceSettingsCompat is an alternate decode shape for clients that send
// nested inlay hints under `settings.vls.inlayHints.enabled`.
struct WorkspaceSettingsCompat {
	vls WorkspaceVlsSettingsCompat
}

// DidChangeConfigurationParamsCompat is the alternate top-level settings shape.
struct DidChangeConfigurationParamsCompat {
	settings WorkspaceSettingsCompat
}

// DidChangeConfigurationDirectParams covers clients that send the VLS section
// directly in `settings` (without a nested `settings.vls` object).
struct DidChangeConfigurationDirectParams {
	settings WorkspaceVlsSettings
}

// DidChangeConfigurationDirectParamsCompat covers the direct settings shape
// when `inlayHints` is itself a nested object with `enabled`.
struct DidChangeConfigurationDirectParamsCompat {
	settings WorkspaceVlsSettingsCompat
}

// WorkspaceFolder describes a workspace root provided during initialize.
struct WorkspaceFolder {
	uri  string
	name ?string
}

// WorkspaceFoldersChangeEvent describes workspace folders added/removed at runtime.
struct WorkspaceFoldersChangeEvent {
	added   []WorkspaceFolder
	removed []WorkspaceFolder
}

// DidChangeWorkspaceFoldersParams holds the event for workspace/didChangeWorkspaceFolders.
struct DidChangeWorkspaceFoldersParams {
	event WorkspaceFoldersChangeEvent
}

// GeneralClientCapabilities carries the general section of client capabilities.
struct GeneralClientCapabilities {
	position_encodings ?[]string @[json: 'positionEncodings']
}

// WindowClientCapabilities carries the window section of client capabilities.
struct WindowClientCapabilities {
	work_done_progress bool @[json: 'workDoneProgress']
}

// DidChangeWatchedFilesClientCapabilities describes support for dynamic watched-files registration.
struct DidChangeWatchedFilesClientCapabilities {
	dynamic_registration bool @[json: 'dynamicRegistration']
}

// WorkspaceClientCapabilities carries the workspace section of client capabilities.
struct WorkspaceClientCapabilities {
	did_change_watched_files ?DidChangeWatchedFilesClientCapabilities @[json: 'didChangeWatchedFiles']
}

// ClientCapabilities is a minimal subset of the client capabilities object from InitializeParams.
struct ClientCapabilities {
	general   ?GeneralClientCapabilities
	window    ?WindowClientCapabilities
	workspace ?WorkspaceClientCapabilities
}

// CompletionList is the preferred completion response shape (LSP §3.17).
// isIncomplete=true tells the client to re-query as the user types.
struct CompletionList {
	is_incomplete bool @[json: 'isIncomplete']
	items         []Detail
}

// ShowMessageParams is the params payload for window/showMessage notifications.
// Type: 1=Error, 2=Warning, 3=Info, 4=Log.
struct ShowMessageParams {
	type_   int @[json: 'type']
	message string
}

// LogMessageParams is the params payload for window/logMessage notifications.
// Type: 1=Error, 2=Warning, 3=Info, 4=Log.
struct LogMessageParams {
	type_   int @[json: 'type']
	message string
}

// FileSystemWatcher describes a file glob pattern to watch.
struct FileSystemWatcher {
	glob_pattern string @[json: 'globPattern']
}

// WatcherRegisterOptions contains file watcher registration options.
struct WatcherRegisterOptions {
	watchers []FileSystemWatcher
}

// WatcherRegistration registers a single capability with the client.
struct WatcherRegistration {
	id               string
	method           string
	register_options WatcherRegisterOptions @[json: 'registerOptions']
}

// WatcherRegistrationParams is the params for client/registerCapability.
struct WatcherRegistrationParams {
	registrations []WatcherRegistration
}

// RegisterCapabilityRequest is a server-to-client request to register dynamic capabilities.
struct RegisterCapabilityRequest {
	id      int
	method  string = 'client/registerCapability'
	params  WatcherRegistrationParams
	jsonrpc string = '2.0'
}

// WorkDoneProgressBegin is the initial payload for a work-done progress sequence.
struct WorkDoneProgressBegin {
	kind        string = 'begin'
	title       string
	cancellable bool
	message     ?string
	percentage  ?int
}

// WorkDoneProgressReport sends an incremental update for a work-done progress.
struct WorkDoneProgressReport {
	kind       string = 'report'
	message    ?string
	percentage ?int
}

// WorkDoneProgressEnd sends the final update for a work-done progress.
struct WorkDoneProgressEnd {
	kind    string = 'end'
	message ?string
}

// ProgressCreateParams is used to request a new progress token from the client.
struct ProgressCreateParams {
	token string
}

// Command represents an LSP command with optional arguments.
struct Command {
	title     string
	command   string
	arguments ?[]string
}

// CodeLens represents a command that should be shown along with a source text range.
struct CodeLens {
	range   LSPRange
	command ?Command
	data    ?string
}

// CodeLensParams holds parameters for textDocument/codeLens.
struct CodeLensParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
}

// ExecuteCommandParams holds parameters for workspace/executeCommand.
struct ExecuteCommandParams {
	command   string
	arguments ?[]string
}

// InlineValueParams holds parameters for textDocument/inlineValue.
struct InlineValueParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	range         LSPRange
}

// InlineValueText is a simple text-based inline value.
struct InlineValueText {
	range LSPRange
	text  string
}

// LinkedEditingRangeParams holds parameters for textDocument/linkedEditingRange.
struct LinkedEditingRangeParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	position      Position
}

// LinkedEditingRanges is the result for textDocument/linkedEditingRange.
struct LinkedEditingRanges {
	ranges       []LSPRange
	word_pattern ?string @[json: 'wordPattern']
}

// FileOperationParams is used for willCreateFiles / willRenameFiles / willDeleteFiles.
struct FileOperationParams {
	files []FileOperationItem
}

// FileOperationItem describes a single file involved in a file operation.
struct FileOperationItem {
	uri string
}

// RenameFileItem describes a file rename operation (old → new URI).
struct RenameFileItem {
	old_uri string @[json: 'oldUri']
	new_uri string @[json: 'newUri']
}

// WillRenameFilesParams holds parameters for workspace/willRenameFiles.
struct WillRenameFilesParams {
	files []RenameFileItem
}

// OnTypeFormattingParams holds parameters for textDocument/onTypeFormatting.
struct OnTypeFormattingParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	position      Position
	ch            string
}

// InitializeParams holds client startup parameters relevant to server workspace scope.
struct InitializeParams {
	root_uri          ?string            @[json: 'rootUri']
	root_path         ?string            @[json: 'rootPath']
	workspace_folders ?[]WorkspaceFolder @[json: 'workspaceFolders']
	capabilities      ?ClientCapabilities
}

// CancelRequestParams holds the id of a request to cancel.
struct CancelRequestParams {
	id int
}

// CompletionItemCapability describes client completion item capabilities.
struct CompletionItemCapability {
	snippet_support bool @[json: 'snippetSupport']
}

// CompletionProvider describes completion trigger characters and options.
struct CompletionProvider {
	trigger_characters []string @[json: 'triggerCharacters']
}

// SaveOptions configures whether the server wants file text included in
// textDocument/didSave notifications (LSP §3.17 SaveOptions).
struct SaveOptions {
	include_text bool @[json: 'includeText']
}

// TextDocumentSyncOptions describes document synchronization options.
struct TextDocumentSyncOptions {
	open_close           bool @[json: 'openClose']
	change               int         // 1 for Full, 2 for Incremental
	save                 SaveOptions // emit {"includeText":true} to receive text in didSave
	will_save            bool @[json: 'willSave']
	will_save_wait_until bool @[json: 'willSaveWaitUntil']
}

// SignatureHelpOptions describes signature help trigger characters.
struct SignatureHelpOptions {
	trigger_characters []string @[json: 'triggerCharacters']
}

// SignatureHelp contains signature information for a function or method.
struct SignatureHelp {
	signatures       []SignatureInformation
	active_signature int @[json: 'activeSignature']
	active_parameter int @[json: 'activeParameter']
}

// SignatureInformation describes a callable signature.
struct SignatureInformation {
	label      string
	parameters []ParameterInformation
}

// ParameterInformation describes a parameter of a callable signature.
struct ParameterInformation {
	label string
}

// Hover represents hover information at a text document position.
struct Hover {
	contents MarkupContent
	range    ?LSPRange
}

// MarkupContent represents marked up text (markdown or plaintext).
struct MarkupContent {
	kind  string // "plaintext" or "markdown"
	value string
}

// WorkspaceEdit represents changes to many resources managed in the workspace.
struct WorkspaceEdit {
	changes          map[string][]TextEdit
	document_changes ?[]TextDocumentEdit @[json: 'documentChanges']
}

// VersionedTextDocumentIdentifier identifies a versioned text document.
struct VersionedTextDocumentIdentifier {
	uri     string
	version ?int
}

// TextDocumentEdit represents a list of edits applied to a versioned document.
struct TextDocumentEdit {
	text_document VersionedTextDocumentIdentifier @[json: 'textDocument']
	edits         []TextEdit
}

// TextEdit represents a textual edit applicable to a text document.
struct TextEdit {
	range    LSPRange
	new_text string @[json: 'newText']
}

// InlayHintKind 1 = Type hint, 2 = Parameter hint
const inlay_hint_kind_type = 1

// InlayHint represents a hint shown inline in the editor (type or parameter).
struct InlayHint {
	position     Position
	label        string
	kind         int  @[json: 'kind']
	padding_left bool @[json: 'paddingLeft']
}

// CodeAction represents a code action (e.g., quick fix) for the client.
struct CodeAction {
	title        string
	kind         string
	is_preferred ?bool @[json: 'isPreferred'] // true marks the primary fix in the UI
	edit         ?WorkspaceEdit
	diagnostics  ?[]LSPDiagnostic
}

// LSP CodeActionParams struct
// CodeActionParams contains parameters for a code action request.
struct CodeActionParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	range         LSPRange
	context       CodeActionContext
}

// CodeActionContext contains context for a code action request.
struct CodeActionContext {
	diagnostics []LSPDiagnostic
}

// DocumentHighlight represents a highlighted occurrence of a symbol in a document.
// Kind: 1 = Text, 2 = Read, 3 = Write.
struct DocumentHighlight {
	range LSPRange
	kind  int
}

// DocumentHighlightParams holds parameters for textDocument/documentHighlight.
struct DocumentHighlightParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	position      Position
}

// SelectionRange represents a range for smart selection expansion.
// A parent SelectionRange (pointer) holds the next larger enclosing range.
struct SelectionRange {
	range  LSPRange
	parent ?&SelectionRange
}

// SelectionRangeParams holds parameters for textDocument/selectionRange.
struct SelectionRangeParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	positions     []Position
}

// SemanticTokensRangeParams holds parameters for textDocument/semanticTokens/range.
struct SemanticTokensRangeParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	range         LSPRange
}

// DocumentRangeFormattingParams holds parameters for textDocument/rangeFormatting.
struct DocumentRangeFormattingParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	range         LSPRange
	options       FormattingOptions
}

// DidChangeWatchedFilesParams holds file-change events sent by the client watcher.
struct DidChangeWatchedFilesParams {
	changes []FileEvent
}

// FileEvent describes a single file-watcher event.
// Type: 1 = Created, 2 = Changed, 3 = Deleted.
struct FileEvent {
	uri        string
	event_type int @[json: 'type']
}

enum Method {
	unknown                                 @['unknown']
	initialize                              @['initialize']
	initialized                             @['initialized']
	did_open                                @['textDocument/didOpen']
	did_change                              @['textDocument/didChange']
	did_close                               @['textDocument/didClose']
	did_save                                @['textDocument/didSave']
	definition                              @['textDocument/definition']
	declaration                             @['textDocument/declaration']
	type_definition                         @['textDocument/typeDefinition']
	implementation                          @['textDocument/implementation']
	completion                              @['textDocument/completion']
	signature_help                          @['textDocument/signatureHelp']
	hover                                   @['textDocument/hover']
	references                              @['textDocument/references']
	rename                                  @['textDocument/rename']
	prepare_rename                          @['textDocument/prepareRename']
	formatting                              @['textDocument/formatting']
	document_symbols                        @['textDocument/documentSymbol']
	workspace_symbol                        @['workspace/symbol']
	inlay_hint                              @['textDocument/inlayHint']
	code_action                             @['textDocument/codeAction']
	semantic_tokens                         @['textDocument/semanticTokens/full']
	folding_range                           @['textDocument/foldingRange']
	callhierarchy_prepare                   @['textDocument/prepareCallHierarchy']
	callhierarchy_incoming                  @['callHierarchy/incomingCalls']
	callhierarchy_outgoing                  @['callHierarchy/outgoingCalls']
	workspace_did_change_configuration      @['workspace/didChangeConfiguration']
	workspace_did_change_workspace_folders  @['workspace/didChangeWorkspaceFolders']
	document_highlight                      @['textDocument/documentHighlight']
	selection_range                         @['textDocument/selectionRange']
	semantic_tokens_range                   @['textDocument/semanticTokens/range']
	range_formatting                        @['textDocument/rangeFormatting']
	will_save                 @['textDocument/willSave']
	will_save_wait_until      @['textDocument/willSaveWaitUntil']
	did_change_watched_files  @['workspace/didChangeWatchedFiles']
	code_lens                 @['textDocument/codeLens']
	code_lens_resolve         @['codeLens/resolve']
	execute_command           @['workspace/executeCommand']
	inline_value              @['textDocument/inlineValue']
	linked_editing_range      @['textDocument/linkedEditingRange']
	will_create_files         @['workspace/willCreateFiles']
	will_rename_files         @['workspace/willRenameFiles']
	will_delete_files         @['workspace/willDeleteFiles']
	on_type_formatting        @['textDocument/onTypeFormatting']
	set_trace                 @['$/setTrace']
	cancel_request            @['$/cancelRequest']
	shutdown                  @['shutdown']
	exit                      @['exit']
}

// TextDocumentPositionParams for position-based requests
struct TextDocumentPositionParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	position      Position
}

// DidOpenTextDocumentItem contains the document payload sent by didOpen.
// LSP includes the full in-memory file text in this object.
struct DidOpenTextDocumentItem {
	uri         string
	language_id ?string @[json: 'languageId']
	version     ?int
	text        ?string
}

// DidOpenTextDocumentParams for didOpen.
struct DidOpenTextDocumentParams {
	text_document DidOpenTextDocumentItem @[json: 'textDocument']
}

// DidChangeTextDocumentParams for didChange
struct DidChangeTextDocumentParams {
	text_document   VersionedTextDocumentIdentifier @[json: 'textDocument']
	content_changes []ContentChange                 @[json: 'contentChanges']
}

// DidCloseTextDocumentParams for didClose
struct DidCloseTextDocumentParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
}

// DidSaveTextDocumentParams for didSave
struct DidSaveTextDocumentParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	text          ?string
}

// WillSaveTextDocumentParams for willSave/willSaveWaitUntil.
// Reason: 1 = Manual, 2 = AfterDelay, 3 = FocusOut.
struct WillSaveTextDocumentParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	reason        int
}

// ReferenceContext carries the includeDeclaration flag for references requests.
struct ReferenceContext {
	include_declaration bool @[json: 'includeDeclaration']
}

// ReferenceParams for references
struct ReferenceParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	position      Position
	context       ReferenceContext
}

// RenameParams for rename
struct RenameParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	position      Position
	new_name      string @[json: 'newName']
}

// FormattingOptions carries client formatting preferences (LSP §3.17).
// VLS ignores these and always delegates to `v fmt`.
struct FormattingOptions {
	tab_size      int  @[json: 'tabSize']
	insert_spaces bool @[json: 'insertSpaces']
}

// DocumentFormattingParams for formatting
struct DocumentFormattingParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	options       FormattingOptions
}

// DocumentSymbolParams for documentSymbol
struct DocumentSymbolParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
}

// InlayHintParams for inlayHint
struct InlayHintParams {
	text_document TextDocumentIdentifier @[json: 'textDocument']
	range         LSPRange
}

// WorkspaceSymbolParams for workspace/symbol
struct WorkspaceSymbolParams {
	query string
}

fn Method.from_string(s string) Method {
	$for m in Method.values {
		if s == m.attrs[0] {
			return m.value
		}
	}
	return Method.unknown
}

fn (m Method) str() string {
	$for v in Method.values {
		if m == v.value {
			return v.attrs[0]
		}
	}
	return 'unknown'
}
