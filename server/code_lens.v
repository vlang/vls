module server

// import lsp
// import json

fn (mut ls Vls) code_lens(id string, params string) {
	if Feature.code_lens !in ls.enabled_features {
		return
	}

	// json.decode(lsp.CodeLensParams, params) or {
	// 	ls.panic(err.msg())
	// 	return
	// }

	// TODO: compute codelenses, for now return empty result
	ls.send_null(id)
}
