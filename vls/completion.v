// TODO: This code will be probably moved to features.v depending on the
// complexity of the code. What you're seeing here is not final so please
// bear in mind about it. 
// TODO: Add tests for it
module vls

import lsp
import os
import jsonrpc
import json
import v.ast
import v.table

struct CompletionItemConfig {
	pub_only    bool = true
	fields_only bool
	mod         string
	file        ast.File
	offset      int
	table       &table.Table
}

fn (ls Vls) completion_item_stmt(stmt ast.Stmt, mut completion_items []lsp.CompletionItem, cfg CompletionItemConfig) {
	match stmt {
		ast.StructDecl {
			if cfg.pub_only && !stmt.is_pub {
				return
			}
			if !cfg.fields_only {
				label := stmt.name.all_after('${cfg.mod}.') + '{}'
				completion_items << lsp.CompletionItem{
					label: label
					kind: .struct_
					insert_text: label
				}
			} else {
				for field in stmt.fields {
					completion_items << lsp.CompletionItem{
						label: field.name
						kind: .field
						insert_text: field.name
					}
				}
			}
		}
		ast.ConstDecl {
			if cfg.pub_only && !stmt.is_pub {
				return
			}
			completion_items << stmt.fields.map(lsp.CompletionItem{
				label: it.name.all_after('${cfg.mod}.')
				kind: .constant
				insert_text: it.name.all_after('${cfg.mod}.')
			})
		}
		ast.EnumDecl {
			if cfg.pub_only && !stmt.is_pub {
				return
			}
			for field in stmt.fields {
				label := stmt.name.all_after('${cfg.mod}.') + '.' + field.name
				completion_items << lsp.CompletionItem{
					label: label
					kind: .enum_member
					insert_text: label
				}
			}
		}
		ast.TypeDecl {
			match stmt {
				ast.AliasTypeDecl, ast.SumTypeDecl, ast.FnTypeDecl {
					label := stmt.name.all_after('${cfg.mod}.')
					completion_items << lsp.CompletionItem{
						label: label
						kind: .type_parameter
						insert_text: label
					}
				}
			}
		}
		ast.FnDecl {
			if (cfg.pub_only && !stmt.is_pub) || stmt.name == 'main.main' {
				return
			}
			label := stmt.name.all_after('${cfg.mod}.')
			completion_items << lsp.CompletionItem{
				label: label
				kind: .function
				insert_text: '${label}()'
			}
		}
		ast.InterfaceDecl {
			if cfg.pub_only && !stmt.is_pub {
				return
			}
			label := stmt.name.all_after('${cfg.mod}.')
			completion_items << lsp.CompletionItem{
				label: label
				kind: .interface_
				insert_text: label
			}
		}
		ast.ExprStmt {
			ls.completion_item_expr(stmt.expr, mut completion_items, cfg)
		}
		else {}
	}
}

fn (ls Vls) completion_item_expr(expr ast.Expr, mut completion_items []lsp.CompletionItem, cfg CompletionItemConfig) {
	// TODO: Support more nodes.
	mut expr_typ := 0
	match expr {
		ast.SelectorExpr { expr_typ = expr.expr_type }
		else {}
	}
	if expr_typ != 0 {
		typ_name := cfg.table.type_to_str(expr_typ)
		typ_sym := cfg.table.get_type_symbol(expr_typ)
		mut ls_symbol_name := typ_name
		if typ_name.starts_with('[]') {
			ls_symbol_name = 'array'
		} else if typ_name.starts_with('map[') {
			ls_symbol_name = 'map'
		}
		ls.log_message('$typ_name | ls_symbol_name: ' + ls_symbol_name, .info)
		if ls_symbol_name in ls.symbols {
			stmt := ls.symbols[ls_symbol_name]
			ls.completion_item_stmt(stmt, mut completion_items, {
				cfg |
				fields_only: true
			})
		}
		// list all methods
		for m in typ_sym.methods {
			completion_items << lsp.CompletionItem{
				label: m.name
				kind: .method
				insert_text: '${m.name}()'
			}
		}
	}
	// TODO: crashes
	//  else { 
	// 	if expr is ast.SelectorExpr {
	// 		if expr.expr is ast.Ident {
	// 			ident := expr.expr

	// 			if ident.name !in cfg.file.imports.map(if it.alias.len > 0 { it.alias } else { it.mod }) {	
	// 				return
	// 			}

	// 			for sym_name, stmt in ls.symbols {
	// 				if !sym_name.starts_with(ident.name) {
	// 					continue
	// 				}

	// 				ls.completion_item_stmt(stmt, mut completion_items, cfg)
	// 			}
	// 		}
	// 	}
	// }
}

fn (mut ls Vls) completion(id int, params string) {
	completion_params := json.decode(lsp.CompletionParams, params) or { panic(err) }
	file_uri := completion_params.text_document.uri
	dir := os.dir(file_uri)
	file := ls.files[file_uri.str()]
	src := ls.sources[file_uri.str()]
	table := ls.tables[dir]
	ctx := completion_params.context
	pos := completion_params.position
	// TODO: temporary. will remove it later
	raw_offset := compute_offset(src.bytestr(), pos.line, pos.character)
	offset := raw_offset - 4
	// mut has_str_method := false
	mut show_global := false
	mut show_local := true
	mut completion_items := []lsp.CompletionItem{}
	ls.log_message('offset: $offset | trigger_kind: $ctx.trigger_kind', .info)
	if ctx.trigger_kind == .trigger_character {
		// NB: not really sure why there's no difference between
		// invoked through typing and through control+enter. my idea
		// supposedly is to cache the results related to that node 
		// when a user presses esc after it presses one of the trigger
		// characters (like dot). instead, it regenerates a new output
		// again but uses local variables which sounds dumb.
		node := ls.get_ast_by_pos(pos.line, pos.character - 2, src.bytestr(), file.stmts.map(AstNode(it))) or {
			ls.log_message('ast node not found... sending cached one', .info)
			ls.send(json.encode(jsonrpc.Response<[]lsp.CompletionItem>{
				id: id
				result: ls.cached_completion
			}))
			return
		}
		if ctx.trigger_character == '.' {
			show_global = false
			show_local = false
			if node is ast.Stmt {
				ls.log_message('node: ' + typeof(node), .info)
				ls.completion_item_stmt(node, mut completion_items, file: file, table: table)
			}
		}
		// if ctx.trigger_character == '=' {
		// 	ls.log_message(src.str(),.info)
		// }
		// if ctx.trigger_character == '=' src[offset-1] != `:` {
		// 	need_more = false
		// } 
	} else {
		show_global = false
	}
	if show_local {
		scope := file.scope.innermost(offset)
		// TODO: get the module names
		// for imp in file.imports {
		// 	completion_items << lsp.CompletionItem{
		// 		label: if imp.alias.len > 0 { imp.alias } else { imp.mod }
		// 		kind: .module_
		// 	}
		// }

		// get variables inside the scope
		for _, obj in scope.objects {
			if obj is ast.Var {
				completion_items << lsp.CompletionItem{
					label: obj.name
					kind: .variable
					insert_text: obj.name
				}
			}
		}
	}
	if show_global {
		// get all functions with the relative dir
		for fpath, ffile in ls.files {
			if !fpath.starts_with(dir) {
				continue
			}
			for stmt in ffile.stmts {
				ls.completion_item_stmt(stmt, mut completion_items, 
					mod: ffile.mod.name
					file: ffile
					table: table
				)
			}
		}
	}

	if completion_items.len > 0 {
		ls.cached_completion = completion_items.clone()
		ls.send(json.encode(jsonrpc.Response<[]lsp.CompletionItem>{
			id: id
			result: completion_items
		}))
	}
	
	unsafe {completion_items.free()}
}