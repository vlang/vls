module vls

import lsp
import json
import jsonrpc
import v.fmt
import os

fn (mut ls Vls) formatting(id int, params string) {
	formatting_params := json.decode(lsp.DocumentFormattingParams, params) or { panic(err) }
	uri := formatting_params.text_document.uri.str()
	table := ls.tables[os.dir(uri)]
	file_ast := ls.files[uri]
	source := ls.sources[uri]
	source_lines := source.split_into_lines()
	formatted_content := fmt.fmt(file_ast, table, false)
	resp := jsonrpc.Response<[]lsp.TextEdit>{
		id: id
		result: [lsp.TextEdit{
			range: lsp.Range{
				start: lsp.Position{
					line: 0
					character: 0
				}
				end: lsp.Position{
					line: source_lines.len
					character: if source_lines.last().len > 0 { source_lines.last().len - 1 } else { 0 }
				}
			}
			new_text: formatted_content
		}]
	}
	ls.send(json.encode(resp))
	unsafe {
		source_lines.free()
		formatted_content.free()
	}
}
