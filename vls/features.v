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
import strings

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

fn (ls Vls) signature_help(id int, params string) {
	signature_params := json.decode(lsp.SignatureHelpParams, params) or { panic(err) }

	uri := signature_params.text_document.uri
	pos := signature_params.position
	ctx := signature_params.context
	mut result := '{"jsonrpc":"2.0","id":$id,"result":null}'
	if Feature.signature_help !in ls.enabled_features {
		ls.send(result)
		return
	}

// TODO: detect current argument
	if ctx.trigger_kind == .trigger_character && ctx.trigger_character == ',' && ctx.is_retrigger {
		mut active_sighelp := ctx.active_signature_help

		if active_sighelp.signatures.len > 0 && 
			 active_sighelp.active_parameter < active_sighelp.signatures[0].parameters.len {
			active_sighelp.active_parameter++
		}

		result = json.encode(jsonrpc.Response<lsp.SignatureHelp>{
			id: id
			result: active_sighelp
		})

		ls.send(result)
		return
	}

	file := ls.files[uri.str()]
	src := ls.sources[uri.str()]
	table := ls.tables[os.dir(uri.str())]
	offset := compute_offset(src, pos.line, pos.character)
	
	// ls.log_message(ctx.str(), .info)
	// ls.log_message(pos.str(), .info)
	// ls.log_message(offset.str(), .info)

	node := find_ast_by_pos(file.stmts.map(ast.Node(it)), offset) or {
		ls.send(result) // null
		ls.show_message(err, .info)
		return
	}

	mut expr := ast.Expr{}
	if node is ast.Stmt {
		if node is ast.ExprStmt {
			expr = node.expr
		}
	} else if node is ast.Expr {
		expr = node
	}
	
	// ls.log_message(typeof(expr), .info)
	if expr is ast.CallExpr {
		call_expr := expr as ast.CallExpr
		mut label := ''
		mut param_infos := []lsp.ParameterInformation{}
		mut params_data := []table.Param{}
		mut skip_receiver := false

		if call_expr.is_method {
			left_type_sym := table.get_type_symbol(call_expr.left_type)
			if method := table.type_find_method(left_type_sym, call_expr.name) {
				skip_receiver = true
				label = table.fn_signature(method, skip_receiver: true, type_only: false)
				params_data << method.params
			}
		} else {
			if fn_data := table.find_fn(call_expr.name) {
				label = table.fn_signature(fn_data, skip_receiver: false, type_only: false)
				params_data << fn_data.params
			}
		}

		start := int(skip_receiver)
		for i in start .. params_data.len {
			param := params_data[i]
			mut sb := strings.new_builder(1)
			mut typ := param.typ
			if param.is_mut {
				typ = typ.deref()
				sb.write('mut ')
			}
			sb.write('$param.name ')
			styp := table.type_to_str(typ)
			sb.write('$styp')
			param_infos << lsp.ParameterInformation{
				label: sb.str()
			}
			unsafe { sb.free() }
		}

		result = json.encode(jsonrpc.Response<lsp.SignatureHelp>{
			id: id
			result: lsp.SignatureHelp{
				signatures: [lsp.SignatureInformation{
					label: label
					parameters: param_infos
				}]
			}
		})
	}

	ls.send(result)
}