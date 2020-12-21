// THIS FEATURE CANNOT BE USED OR MERGED BEFORE A RELEVANT PR IN PARSER 
// HAS BEEN MERGED: <link to the PR has not been available yet>
//
// TODO: This code will be probably moved to features.v depending on the
// complexity of the code. What you're seeing here is not final so please
// bear in mind about it. 
//
// @ned: The problem I'm encountering right now is the delays of the changes
// applied from textDocument/didEdit. The delay causes to have innacurate
// converted positions which is very important in finding the AST node. The 
// AST node is used in order to get more information and accurately suggest
// what the user is trying to type. So far I've tried to processing the file
// on completion but the same thing happens. I'm also thinking of using a
// WaitGroup instead and attach it to the did_edit method and invoke the
// `.wait` method on completion as well as in other features.   
// 
// Another problem is that only one variable is handled at a time. The meaning
// for this is that the server cannot access variable A information without
// commenting variable B.
//
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
				completion_items << lsp.CompletionItem{
					label: stmt.name.all_after('${cfg.mod}.') + '{}'
					kind: .struct_
				}
			} else {
				for field in stmt.fields {
					completion_items << lsp.CompletionItem{
						label: field.name
						kind: .field
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
			})
		}
		ast.EnumDecl {
			if cfg.pub_only && !stmt.is_pub {
				return
			}
			for field in stmt.fields {
				completion_items << lsp.CompletionItem{
					label: stmt.name.all_after('${cfg.mod}.') + '.' + field.name
					kind: .enum_member
				}
			}
		}
		// TODO: Add support for type definitions
		// ast.TypeDecl {
		// }
		ast.FnDecl {
			if (cfg.pub_only && !stmt.is_pub) || stmt.name == 'main.main' {
				return
			}
			completion_items << lsp.CompletionItem{
				label: stmt.name.all_after('${cfg.mod}.')
				kind: .function
			}
		}
		ast.InterfaceDecl {
			if cfg.pub_only && !stmt.is_pub {
				return
			}
			completion_items << lsp.CompletionItem{
				label: stmt.name.all_after('${cfg.mod}.')
				kind: .interface_
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
			}
		}
	}
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
	offset := compute_offset(src, pos.line, pos.character) - 3
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
		node := ls.get_ast_by_pos(pos.line, pos.character - 2, src, file.stmts.map(AstNode(it))) or {
			ls.log_message('ast node not found... sending cached one', .info)
			ls.send_cached_completion(id)
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
		// if ctx.trigger_character == '=' src[offset-1] != `:` {
		// 	need_more = false
		// } 
	} else {
		show_global = false
	}
	if show_local {
		scope := file.scope.innermost(offset)
		for child in file.scope.children {
			ls.log_message([child.start_pos, child.end_pos].str(), .info)
		}
		for _, obj in scope.objects {
			if obj is ast.Var {
				completion_items << lsp.CompletionItem{
					label: obj.name
					kind: .variable
				}
			}
		}
	}
	if show_global {
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
	// if !show_global && !show_local && !has_str_method {
	// 	completion_items << lsp.CompletionItem{
	// 		label: 'str'
	// 		kind: .method
	// 	}
	// }
	if completion_items.len > 0 {
		ls.cached_completion = completion_items.clone()
	} else {
		ls.send_cached_completion(id)
	}
	ls.send(json.encode(jsonrpc.Response<[]lsp.CompletionItem>{
		id: id
		result: completion_items
	}))
	unsafe {completion_items.free()}
}

fn (ls Vls) send_cached_completion(id int) {
	ls.send(json.encode(jsonrpc.Response<[]lsp.CompletionItem>{
		id: id
		result: ls.cached_completion
	}))
}
