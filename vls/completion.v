module vls

import lsp
import os
import jsonrpc
import json
import v.ast

fn stmt_to_completion_item(mod_prefix string, stmt ast.Stmt) ?[]lsp.CompletionItem {
	match stmt {
		ast.StructDecl {
			return [lsp.CompletionItem{
				label: stmt.name.all_after('${mod_prefix}.')
				kind: .struct_
			}]
		}
		ast.ConstDecl {
			return stmt.fields.map(lsp.CompletionItem{
				label: it.name.all_after('${mod_prefix}.')
				kind: .constant
			})
		} 
		ast.EnumDecl {
			mut fields := []lsp.CompletionItem{}
			for field in stmt.fields {
				fields << lsp.CompletionItem{
					label: stmt.name.all_after('${mod_prefix}.') + '.' + field.name
					kind: .enum_member
				}
			}
			return fields
		}
		// TODO: typedecl
		// ast.TypeDecl {

		// }
		ast.FnDecl {
			if stmt.name == 'main.main' {
				return none
			}

			return [lsp.CompletionItem{
				label: stmt.name.all_after('${mod_prefix}.')
				kind: .function
			}]
		}
		ast.InterfaceDecl {
			return [lsp.CompletionItem{
				label: stmt.name.all_after('${mod_prefix}.')
				kind: .interface_
			}]
		}
		else {
			return none
		}
	}
}

fn (mut ls Vls) completion(id int, params string) {
	completion_params := json.decode(lsp.CompletionParams, params) or { panic(err) }
	ctx := completion_params.context
	file_path := completion_params.text_document.uri.path()
	dir := os.dir(file_path)
	mut has_errors := false
	mut show_all := true
	mut completion_items := []lsp.CompletionItem{}
	src := ls.sources[file_path]
	pos := completion_params.position
	offset := compute_offset(src, pos.line, pos.character)

	if ctx.trigger_kind == .trigger_character {
		file := ls.files[file_path]

		if ctx.trigger_character == '.' {
			if node := ls.get_ast_by_pos(pos.line, pos.character, src, file.stmts) {
				show_all = false

				// ls.show_message(typeof(node), .info)
				// if node is ast.Stmt {
				// 	ls.show_message(typeof(node), .info)
				// }
			} else {
				ls.show_message('not found', .info)
			}
		}

		// TODO support for '='
		// if ctx.trigger_character == '=' src[offset-1] != `:` {
		// 	need_more = false
		// } 
	}
	
	if show_all {
		for fpath, file in ls.files {
			if !fpath.starts_with(dir) {
				continue
			}

			if file.path == file_path {
				if file.stmts.len == 0 {
					has_errors = true
					break
				}

				scope := file.scope.innermost(offset)
				for _, obj in scope.objects {
					if obj is ast.Var {
						completion_items << lsp.CompletionItem{
							label: obj.name
							kind: .variable
						}
					}
				}
			}

			for stmt in file.stmts {
				items := stmt_to_completion_item(file.mod.name, stmt) or { continue }
				completion_items << items
				unsafe {
					items.free()
				}
			}
		}

		if !has_errors {
			ls.cached_completion = completion_items
		}
	}
	
	ls.send(json.encode(jsonrpc.Response<[]lsp.CompletionItem>{
		id: id
		result: ls.cached_completion
	}))

	unsafe {
		completion_items.free()
	}
}