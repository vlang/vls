module server

// import lsp
// import json
import jsonrpc

fn (mut ls Vls) code_lens(id string, params string, mut wr ResponseWriter) {
	if Feature.code_lens !in ls.enabled_features {
		return
	}

	// json.decode(lsp.CodeLensParams, params) or {
	// 	ls.panic(err.msg())
	// 	return
	// }

	// TODO: compute codelenses, for now return empty result
	wr.write(jsonrpc.null)
}
