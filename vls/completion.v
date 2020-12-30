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
mut:
	pub_only       bool = true
	file           ast.File
	offset         int
	table          &table.Table
	show_global    bool = true
	show_global_fn bool
	show_local     bool = true
	filter_type    table.Type = table.Type(0)
	fields_only    bool
	ls             Vls
}

fn (mut cfg CompletionItemConfig) completion_items_from_stmt(stmt ast.Stmt) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	match stmt {
		ast.ExprStmt {
			completion_items << cfg.completion_items_from_expr(stmt.expr)
		}
		ast.AssignStmt {
			// TODO: support for multi assign
			if stmt.op != .decl_assign {
				cfg.show_global = false
				cfg.show_global_fn = false
				cfg.filter_type = stmt.left_types[stmt.left_types.len - 1]
			}
		}
		else {}
	}
	return completion_items
}

fn (mut cfg CompletionItemConfig) completion_items_from_expr(expr ast.Expr) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	mut expr_type := table.Type(0)
	// TODO: support for infix/postfix expr
	match expr {
		ast.SelectorExpr {
			expr_type = expr.expr_type
			if expr_type == 0 && expr.expr is ast.Ident {
				ident := expr.expr as ast.Ident
				if ident.name !in cfg.file.imports.map(if it.alias.len > 0 {
					it.alias
				} else {
					it.mod
				}) {
					return completion_items
				}
				// NB: symbols of the said module does not show the full list
				// unless by pressing cmd/ctrl+space or by pressing escape key
				// + deleting the dot + typing again the dot
				for sym_name, idx in cfg.table.type_idxs {
					if idx <= 0 ||
						idx >= cfg.table.types.len || !sym_name.starts_with(ident.name + '.') {
						continue
					}
					// TODO: support for typedefs
					type_sym := unsafe { &cfg.table.types[idx] }
					completion_items <<
						cfg.completion_items_from_type_info(sym_name.all_after(ident.name + '.'), type_sym.info, false)
				}
				for _, fnn in cfg.table.fns {
					if fnn.mod != ident.name || !fnn.is_pub {
						continue
					}
					completion_items << cfg.completion_items_from_fn(fnn, false)
				}
			} else if expr_type != 0 {
				type_sym := cfg.table.get_type_symbol(expr_type)
				completion_items <<
					cfg.completion_items_from_type_info('', type_sym.info, true)
				if type_sym.kind == .array || type_sym.kind == .map {
					base_symbol_name := if type_sym.kind == .array { 'array' } else { 'map' }
					if base_type_sym := cfg.table.find_type(base_symbol_name) {
						completion_items <<
							cfg.completion_items_from_type_info('', base_type_sym.info, true)
					}
				}
				// list all methods
				for m in type_sym.methods {
					completion_items << cfg.completion_items_from_fn(m, true)
				}
			}
			return completion_items
		}
		ast.CallExpr {
			current_arg_idx := expr.args.len
			if current_arg_idx < expr.expected_arg_types.len {
				cfg.show_local = true
				cfg.show_global = false
				cfg.filter_type = expr.expected_arg_types[current_arg_idx]
			} else {
				cfg.show_local = false
				cfg.show_global = false
			}
			return completion_items
		}
		ast.StructInit {
			cfg.show_global = false
			cfg.show_local = false
			field_node := expr.fields.map(AstNode(it)).find_by_pos(cfg.offset - 1) or { AstNode{} }
			if field_node is ast.StructInitField {
				// NB: enable local results only if the node is a field
				cfg.show_local = true
				field_type_sym := cfg.table.get_type_symbol(field_node.expected_type)
				completion_items <<
					cfg.completion_items_from_type_info('', field_type_sym.info, field_type_sym.info is table.Enum)
				cfg.filter_type = field_node.expected_type
			} else {
				// if structinit is empty or not within the field position, 
				// it must show the list of missing fields instead
				defined_fields := expr.fields.map(it.name)
				struct_type_sym := cfg.table.get_type_symbol(expr.typ)
				struct_type_info := struct_type_sym.info as table.Struct
				for field in struct_type_info.fields {
					if field.name in defined_fields {
						continue
					}
					completion_items << lsp.CompletionItem{
						label: '$field.name:'
						kind: .field
						insert_text: '$field.name: \$0'
						insert_text_format: .snippet
					}
				}
			}
		}
		else {}
	}
	return completion_items
}

fn (mut cfg CompletionItemConfig) completion_items_from_fn(fnn table.Fn, is_method bool) lsp.CompletionItem {
	mut i := 0
	mut insert_text := fnn.name.all_after(fnn.mod + '.')
	mut kind := lsp.CompletionItemKind.function
	if is_method {
		kind = .method
	}
	if fnn.is_generic {
		insert_text += '<\${$i:T}>'
	}
	insert_text += '('
	for j, param in fnn.params {
		if is_method && j == 0 {
			continue
		}
		i++
		insert_text += '\${$i:$param.name}'
		if j < fnn.params.len - 1 {
			insert_text += ', '
		}
	}
	insert_text += ')'
	if fnn.return_type.has_flag(.optional) {
		insert_text += ' or { panic(err) }'
	}
	return lsp.CompletionItem{
		label: fnn.name.all_after(fnn.mod + '.')
		kind: kind
		insert_text_format: .snippet
		insert_text: insert_text
	}
}

fn (mut cfg CompletionItemConfig) completion_items_from_type_info(name string, type_info table.TypeInfo, fields_only bool) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	match type_info {
		table.Struct {
			if !fields_only {
				mut insert_text := '$name{\n'
				mut i := type_info.fields.len - 1
				for field in type_info.fields {
					if field.has_default_expr {
						continue
					}
					// TODO: trigger autocompletion
					insert_text += '\t$field.name: \$$i\n'
					i--
				}
				insert_text += '}'
				completion_items << lsp.CompletionItem{
					label: '$name{}'
					kind: .struct_
					insert_text: insert_text
					insert_text_format: .snippet
				}
			} else {
				for field in type_info.fields {
					completion_items << lsp.CompletionItem{
						label: field.name
						kind: .field
						insert_text: field.name
					}
				}
			}
		}
		table.Enum {
			for val in type_info.vals {
				completion_items << lsp.CompletionItem{
					label: if fields_only {
						'.$val'
					} else {
						'${name}.$val'
					}
					kind: .enum_member
					insert_text: if fields_only {
						'.$val'
					} else {
						'${name}.$val'
					}
				}
			}
		}
		table.Alias, table.SumType, table.FnType, table.Interface {
			completion_items << lsp.CompletionItem{
				label: name
				kind: .type_parameter
				insert_text: name
			}
		}
		else {}
	}
	return completion_items
}

// TODO: make params use lsp.CompletionParams in the future
fn (mut ls Vls) completion(id int, params string) {
	completion_params := json.decode(lsp.CompletionParams, params) or { panic(err) }
	file_uri := completion_params.text_document.uri
	dir := os.dir(file_uri)
	file := ls.files[file_uri.str()]
	src := ls.sources[file_uri.str()]
	mut pos := completion_params.position
	mut ctx := completion_params.context
	mut completion_items := []lsp.CompletionItem{}
	mut cfg := CompletionItemConfig{
		file: file
		offset: compute_offset(src, pos.line, pos.character)
		table: ls.tables[dir]
		ls: ls
	}
	// adjust context data if the trigger symbols are on the left
	if ctx.trigger_kind == .invoked && cfg.offset - 1 >= 0 && file.stmts.len > 0 && src.len > 3 {
		if src[cfg.offset - 1] in [`.`, `:`, `=`, `{`, `,`, `(`] {
			ctx = lsp.CompletionContext{
				trigger_kind: .trigger_character
				trigger_character: src[cfg.offset - 1].str()
			}
		} else if src[cfg.offset - 1] == ` ` &&
			cfg.offset - 2 >= 0 && src[cfg.offset - 2] !in [src[cfg.offset - 1], `.`] {
			ctx = lsp.CompletionContext{
				trigger_kind: .trigger_character
				trigger_character: src[cfg.offset - 2].str()
			}
			cfg.offset -= 2
			pos = {
				pos |
				character: pos.character - 2
			}
		}
	}
	// ls.log_message('position: { line: $pos.line, col: $pos.character } | offset: $offset | trigger_kind: $ctx', .info)
	if ctx.trigger_kind == .trigger_character {
		// TODO: enum support inside struct fields
		if ctx.trigger_character == '.' && (cfg.offset - 1 >= 0 && src[cfg.offset - 1] != ` `) {
			cfg.show_global = false
			cfg.show_local = false
			cfg.offset -= 2
		}
		// TODO: will be replaced with the v.ast one
		node := file.stmts.map(AstNode(it)).find_by_pos(cfg.offset) or { AstNode{} }
		if node is ast.Stmt {
			completion_items << cfg.completion_items_from_stmt(node)
		} else if node is ast.Expr {
			completion_items << cfg.completion_items_from_expr(node)
		}
	} else if ctx.trigger_kind == .invoked && (file.stmts.len == 0 || src.len <= 3) {
		// should never happen but just to make sure
		cfg.show_global = false
		cfg.show_local = false
		folder_name := os.base(os.dir(file_uri.str())).replace(' ', '_')
		module_name_suggestions := ['module main', 'module $folder_name']
		for sg in module_name_suggestions {
			completion_items << lsp.CompletionItem{
				label: sg
				insert_text: sg
				kind: .variable
			}
		}
	} else {
		cfg.show_global_fn = true
	}
	if cfg.show_local {
		if cfg.filter_type == 0 {
			// get the module names
			for imp in file.imports {
				if imp.mod in ls.invalid_imports[file_uri.str()] {
					continue
				}
				completion_items << lsp.CompletionItem{
					label: if imp.alias.len > 0 {
						imp.alias
					} else {
						imp.mod
					}
					kind: .module_
				}
			}
		}
		for _, obj in file.scope.objects {
			if obj is ast.ConstField {
				if cfg.filter_type != 0 && obj.typ != cfg.filter_type {
					continue
				}
				completion_items << lsp.CompletionItem{
					label: obj.name.all_after('${obj.mod}.')
					kind: .constant
					insert_text: obj.name.all_after('${obj.mod}.')
				}
			}
		}
		scope := file.scope.innermost(cfg.offset)
		// get variables inside the scope
		for _, obj in scope.objects {
			if obj is ast.Var {
				if cfg.filter_type != 0 && obj.typ != cfg.filter_type {
					continue
				}
				completion_items << lsp.CompletionItem{
					label: obj.name
					kind: .variable
					insert_text: obj.name
				}
			}
		}
	}
	if cfg.show_global {
		if !cfg.show_global_fn {
			for sym_name, idx in cfg.table.type_idxs {
				if idx <= 0 ||
					idx >= cfg.table.types.len || !sym_name.starts_with(file.mod.name + '.') {
					continue
				}
				type_sym := unsafe { &cfg.table.types[idx] }
				completion_items <<
					cfg.completion_items_from_type_info(sym_name.all_after(file.mod.name + '.'), type_sym.info, false)
			}
		}
		for _, fnn in cfg.table.fns {
			if fnn.mod != file.mod.name || fnn.name == 'main.main' {
				continue
			}
			completion_items << cfg.completion_items_from_fn(fnn, false)
		}
	}
	ls.send(json.encode(jsonrpc.Response<[]lsp.CompletionItem>{
		id: id
		result: completion_items
	}))
	unsafe { completion_items.free() }
}
