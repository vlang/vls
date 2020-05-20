module lsp

pub struct CodeActionOptions {
	code_action_kinds []CodeActionKind [json:codeActionKinds]
}

// method: ‘textDocument/codeAction’
// response [](Command | CodeAction) | null
pub struct CodeActionParams {
	text_document TextDocumentIdentifier [json:textDocument]
	range Range
	context CodeActionContext
}

// type CodeActionKind string
pub const (
	Empty = ''
	QuickFix = 'quickfix'
	Refactor = 'refactor'
	RefactorExtract = 'refactor.extract'
	RefactorInline = 'refactor.inline'
	RefactorRewrite = 'refactor.rewrite'
	Source = 'source'
	SourceOrganizeImports = 'source.organizeImports'
)

pub struct CodeActionContext {
	diagnostics []Diagnostic
	only []string
}

pub struct CodeAction {
	title string
	kind string // CodeActionKind
	diagnostics []Diagnostic
	edit WorkspaceEdit
	command Command
}

pub struct CodeActionRegistrationOptions {
	document_selector []DocumentFilter [json:documentSelector]
	code_action_kinds []CodeActionKind [json:codeActionKinds]
}