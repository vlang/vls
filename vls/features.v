module vls

import lsp
import json
import jsonrpc
import v.ast
import v.fmt
import v.table
import v.parser
import v.pref
import os

fn (ls Vls) formatting(id int, params string) {
	formatting_params := json.decode(lsp.DocumentFormattingParams, params) or { panic(err) }
	uri := formatting_params.text_document.uri.str()
	path := formatting_params.text_document.uri.path()
	source := ls.sources[uri].bytestr()
	source_lines := source.split_into_lines()
	mut prefs := pref.new_preferences()
	prefs.is_fmt = true
	table := table.new_table()
	file_ast := parser.parse_text(source, path, table, .parse_comments, prefs, &ast.Scope{
		parent: 0
	})
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
					character: if source_lines.last().len > 0 {
						source_lines.last().len - 1
					} else {
						0
					}
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

fn (mut ls Vls) workspace_symbol(id int, params string) {
	mut symbols := []lsp.SymbolInformation{}
	for file_uri, file in ls.files {
		if !file_uri.starts_with(ls.root_path.str()) {
			continue
		}
		symbols << ls.generate_symbols(file, file_uri)
	}
	ls.send(json.encode(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: id
		result: symbols
	}))
}

fn (mut ls Vls) document_symbol(id int, params string) {
	document_symbol_params := json.decode(lsp.DocumentSymbolParams, params) or { panic(err) }
	uri := document_symbol_params.text_document.uri
	file := ls.files[uri.str()]
	symbols := ls.generate_symbols(file, uri)
	ls.send(json.encode(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: id
		result: symbols
	}))
}

fn (mut ls Vls) generate_symbols(file ast.File, uri lsp.DocumentUri) []lsp.SymbolInformation {
	mut symbols := []lsp.SymbolInformation{}
	sym_is_cached := uri.str() in ls.doc_symbols
	if file.errors.len > 0 && sym_is_cached {
		return ls.doc_symbols[uri.str()]
	}
	source := ls.sources[uri.str()]
	dir := os.dir(uri.str())
	// NB: should never happen. just in case
	// the requests aren't executed in order
	if dir !in ls.tables {
		return symbols
	}
	table := ls.tables[dir]
	for stmt in file.stmts {
		mut name := ''
		mut kind := lsp.SymbolKind.null
		mut pos := position_to_lsp_range(source, stmt.position())
		match stmt {
			ast.ConstDecl {
				for field in stmt.fields {
					symbols << lsp.SymbolInformation{
						name: field.name
						kind: .constant
						location: lsp.Location{
							uri: uri
							range: position_to_lsp_range(source, field.pos)
						}
					}
				}
				continue
			}
			ast.EnumDecl {
				name = stmt.name
				kind = .enum_
			}
			ast.StructDecl {
				name = stmt.name
				kind = .struct_
			}
			ast.InterfaceDecl {
				name = stmt.name
				kind = .interface_
			}
			ast.TypeDecl {
				match stmt {
					ast.AliasTypeDecl, ast.FnTypeDecl, ast.SumTypeDecl {
						name = stmt.name
						kind = .type_parameter
					}
				}
			}
			ast.FnDecl {
				name = stmt.name
				kind = .function
				if stmt.is_method && stmt.receiver.typ != 0 {
					rec_type := table.type_to_str(stmt.receiver.typ)
					name = rec_type + '.' + name
					kind = .method
				}
			}
			else {
				continue
			}
		}
		symbols << lsp.SymbolInformation{
			name: name.all_after(file.mod.name + '.')
			kind: kind
			location: lsp.Location{
				uri: uri
				range: pos
			}
		}
	}
	ls.doc_symbols[uri.str()] = symbols
	return symbols
}
