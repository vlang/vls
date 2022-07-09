module server

import lsp

pub fn (mut ls Vls) document_link(params lsp.DocumentLinkParams, mut wr ResponseWriter) ?[]lsp.DocumentLink {
	if Feature.document_link !in ls.enabled_features {
		return none
	}

	return none
}