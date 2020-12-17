module vls

import lsp
import json
import jsonrpc
import v.parser
import v.table
import v.pref
import v.fmt
import v.ast

fn (ls Vls) formatting(id int, params string) {
	formatting_params := json.decode(lsp.DocumentFormattingParams , params) or { panic(err) }
	mut pref := pref.new_preferences()
	pref.is_fmt = true
	table := table.new_table()
	scope := ast.Scope{
		parent: 0
	}
	source := ls.files[formatting_params.text_document.uri.str()]
	file_path := formatting_params.text_document.uri.path()
	file_ast := parser.parse_text(source, file_path, table, .skip_comments, &pref, &scope)
	formatted_content := fmt.fmt(file_ast, table, false)
	lines := formatted_content.split('\n')
	ls.log_message('lines.len: $lines.len, character: ${lines.last().len}', .info)
	resp := jsonrpc.Response<[]lsp.TextEdit>{
		id: id
		result: [lsp.TextEdit{
			range: lsp.Range{
				start: lsp.Position{
					line: 0
					character: 0
				}
				end: lsp.Position{
					line: if lines.len > 0 { lines.len - 1 } else { 0 }
					character: if lines.last().len > 0 { lines.last().len - 1 } else { 0 }
				}
			}
			new_text: formatted_content
		}]
	}
	ls.log_message(resp.str(), .info)
	ls.send(json.encode(resp))
}
