module vls

import lsp
import json

fn (ls Vls) formatting(id int, params string) {
	formatting_params := json.decode(lsp.DocumentFormattingParams , params) or { panic(err) }
}
