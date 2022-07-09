module server

import lsp

pub fn (mut ls Vls) code_lens(params lsp.CodeLensParams, mut wr ResponseWriter) ?[]lsp.CodeLens {
	if Feature.code_lens !in ls.enabled_features {
		return none
	}

	// TODO: compute codelenses, for now return empty result
	return none
}
