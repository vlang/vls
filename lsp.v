// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
struct Request {
	id      int
	method  string
	jsonrpc string
	params  Params
}

struct Position {
	line int
	char int @[json: 'character']
}

struct TextDocumentIdentifier {
	uri string
}

struct Params {
	content_changes []ContentChange @[json: 'contentChanges']
	position        Position
	text_document   TextDocumentIdentifier @[json: 'textDocument']
}

struct ContentChange {
	text string
}

struct Response {
	id      int
	result  ResponseResult
	jsonrpc string = '2.0'
}

// A Location represents a specific location in a file.
struct Location {
	uri   string
	range LSPRange
}

type ResponseResult = string | []Detail | Capabilities | SignatureHelp | Location

struct Notification {
	method  string
	params  PublishDiagnosticsParams
	jsonrpc string = '2.0'
}

struct PublishDiagnosticsParams {
	uri         string
	diagnostics []LSPDiagnostic
}

struct LSPDiagnostic {
	range    LSPRange
	message  string
	severity int
}

struct LSPRange {
	start Position
	end   Position
}

struct Detail {
	kind               int    // The type of item (e.g., Method, Function, Field)
	label              string // The name of the completion item
	detail             string // Additional info like the function signature or return type
	documentation      string // The documentation for the item
	insert_text        ?string @[json: 'insertText']
	insert_text_format ?int    @[json: 'insertTextFormat'] // 1 for PlainText, 2 for Snippet
}

struct Capabilities {
	capabilities Capability
}

struct Capability {
	completion_provider     CompletionProvider      @[json: 'completionProvider']
	text_document_sync      TextDocumentSyncOptions @[json: 'textDocumentSync']
	signature_help_provider SignatureHelpOptions    @[json: 'signatureHelpProvider']
	definition_provider     bool                    @[json: 'definitionProvider']
}

struct CompletionItemCapability {
	snippet_support bool @[json: 'snippetSupport']
}

struct CompletionProvider {
	trigger_characters []string                  @[json: 'triggerCharacters']
	completion_item    ?CompletionItemCapability @[json: 'completionItem']
}

struct TextDocumentSyncOptions {
	open_close bool @[json: 'openClose']
	change     int // 1 for Full, 2 for Incremental
}

struct SignatureHelpOptions {
	trigger_characters []string @[json: 'triggerCharacters']
}

struct SignatureHelp {
	signatures       []SignatureInformation
	active_signature int @[json: 'activeSignature']
	active_parameter int @[json: 'activeParameter']
}

struct SignatureInformation {
	label      string
	parameters []ParameterInformation
}

struct ParameterInformation {
	label string
}

enum Method {
	unknown         @['unknown']
	initialize      @['initialize']
	initialized     @['initialized']
	did_open        @['textDocument/didOpen']
	did_change      @['textDocument/didChange']
	definition      @['textDocument/definition']
	completion      @['textDocument/completion']
	signature_help  @['textDocument/signatureHelp']
	set_trace       @['$/setTrace']
	cancel_request  @['$/cancelRequest']
	shutdown        @['shutdown']
	exit            @['exit']
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
