module vls

import lsp
import json
import jsonrpc
import v.ast
import v.fmt
import v.parser
import v.pref
import v.token
import os
// import strings

[manualfree]
fn (mut ls Vls) formatting(id int, params string) {
	formatting_params := json.decode(lsp.DocumentFormattingParams, params) or { 
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}
	uri := formatting_params.text_document.uri.str()
	path := formatting_params.text_document.uri.path()
	source := ls.sources[uri].bytestr()
	mut prefs := pref.new_preferences()
	prefs.output_mode = .silent
	prefs.is_fmt = true
	table := ast.new_table()
	file_ast := parser.parse_text(source, path, table, .parse_comments, prefs, &ast.Scope{
		parent: 0
	})
	if file_ast.errors.len > 0 {
		ls.send_null(id)
		return
	}
	source_lines := source.split_into_lines()
	formatted_content := fmt.fmt(file_ast, table, prefs, false)
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
	ls.send(resp)
	unsafe {
		source_lines.free()
		formatted_content.free()
	}
}

fn (mut ls Vls) workspace_symbol(id int, _ string) {
	mut symbols := []lsp.SymbolInformation{}
	for file_uri, file in ls.files {
		if !file_uri.starts_with(ls.root_uri.str()) {
			continue
		}
		symbols << ls.generate_symbols(file, file_uri)
	}
	ls.send(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: id
		result: symbols
	})
}

fn (mut ls Vls) document_symbol(id int, params string) {
	document_symbol_params := json.decode(lsp.DocumentSymbolParams, params) or { 
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}
	uri := document_symbol_params.text_document.uri
	file := ls.files[uri.str()]
	symbols := ls.generate_symbols(file, uri)
	ls.send(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: id
		result: symbols
	})
}

fn (mut ls Vls) generate_symbols(file ast.File, uri lsp.DocumentUri) []lsp.SymbolInformation {
	mut symbols := []lsp.SymbolInformation{}
	sym_is_cached := uri.str() in ls.doc_symbols
	if file.errors.len > 0 && sym_is_cached {
		return ls.doc_symbols[uri.str()]
	}
	dir := uri.dir()
	// NB: should never happen. just in case
	// the requests aren't executed in order
	if dir !in ls.tables {
		return symbols
	}
	table := ls.tables[dir]
	for stmt in file.stmts {
		mut name := ''
		mut kind := lsp.SymbolKind.null
		mut pos := position_to_lsp_range(stmt.pos)
		match stmt {
			ast.ConstDecl {
				for field in stmt.fields {
					symbols << lsp.SymbolInformation{
						name: field.name.all_after(file.mod.name + '.')
						kind: .constant
						location: lsp.Location{
							uri: uri
							range: position_to_lsp_range(field.pos)
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

fn (mut ls Vls) signature_help(id int, params string) {
	signature_params := json.decode(lsp.SignatureHelpParams, params) or { 
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}
	uri := signature_params.text_document.uri
	pos := signature_params.position
	ctx := signature_params.context
	if Feature.signature_help !in ls.enabled_features {
		ls.send_null(id)
		return
	}

	file := ls.files[uri.str()]
	tbl := ls.tables[uri.dir()]
	offset := compute_offset(ls.sources[uri.str()], pos.line, pos.character)
	node := find_ast_by_pos(file.stmts.map(ast.Node(it)), offset) or {
		ls.send_null(id)
		return
	}

	mut expr := ast.empty_expr()
	if node is ast.Stmt {
		// if the selected node is an ExprStmt,
		// the expr content of the ExprStmt node
		// will be used.
		if node is ast.ExprStmt {
			expr = node.expr
		}
	} else if node is ast.Expr {
		expr = node
	}
	// signature help supports function calls for now
	// hence checking the expr if it's a CallExpr node.
	if expr is ast.CallExpr {
		call_expr := expr as ast.CallExpr

		// for retrigger, it utilizes the current signature help data
		if ctx.is_retrigger {
			mut active_sighelp := ctx.active_signature_help

			if ctx.trigger_kind == .content_change {
				// change the current active param value to the length of the current args.
				active_sighelp.active_parameter = call_expr.args.len - 1
			} else if ctx.trigger_kind == .trigger_character && ctx.trigger_character == ','
				&& active_sighelp.signatures.len > 0
				&& active_sighelp.active_parameter < active_sighelp.signatures[0].parameters.len {
				// when pressing comma, it must proceed to the next parameter
				// by incrementing the active parameter.
				active_sighelp.active_parameter++
			}

			ls.send(jsonrpc.Response<lsp.SignatureHelp>{
				id: id
				result: active_sighelp
			})
			return
		}
		// create a signature help info based on the
		// call expr info
		// TODO: use string concat in the meantime as
		// the msvc CI fails when using strings.builder
		// as it produces bad output (in the case of msvc)
		mut label := 'fn '
		mut return_type := ''
		mut param_infos := []lsp.ParameterInformation{}
		mut params_data := []ast.Param{}
		mut skip_receiver := false

		if call_expr.is_method {
			left_type_sym := tbl.get_type_symbol(call_expr.left_type)
			if method := tbl.type_find_method(left_type_sym, call_expr.name) {
				skip_receiver = true
				label += '($left_type_sym.name) ${method.name}('

				if method.return_type != ast.Type(0) {
					return_type = tbl.type_to_str(method.return_type)
				}

				params_data << method.params
			}
		} else if fn_data := tbl.find_fn(call_expr.name) {
			if fn_data.return_type != ast.Type(0) {
				return_type = tbl.type_to_str(fn_data.return_type)
			}

			label += '${fn_data.name}('
			params_data << fn_data.params
		}

		start := int(skip_receiver) // index 1 for true, 0 for false
		for i in start .. params_data.len {
			if i != start {
				label += ', '
			}
			param := params_data[i]
			// TODO: revert back to strings.builder once
			//  the issue with MSVC has been fully resolved.
			mut param_signature := ''
			mut typ := param.typ
			if param.is_mut {
				typ = typ.deref()
				param_signature += 'mut '
			}
			styp := tbl.type_to_str(typ)
			param_signature += '$param.name $styp'
			label += param_signature
			param_infos << lsp.ParameterInformation{
				label: param_signature
			}
		}
		label += ') $return_type'

		ls.send(jsonrpc.Response<lsp.SignatureHelp>{
			id: id
			result: lsp.SignatureHelp{
				signatures: [lsp.SignatureInformation{
					label: label
					parameters: param_infos
				}]
			}
		})
		return
	}
	// send null result for unsupported node
	ls.send_null(id)
}

struct CompletionItemConfig {
mut:
	file                ast.File
	offset              int // position of the cursor. used for finding the AST node
	table               &ast.Table
	show_global         bool = true // for displaying global (project) symbols
	show_only_global_fn bool     // for displaying only the functions of the project
	show_local          bool     = true // for displaying local variables
	filter_type         ast.Type = ast.Type(0) // filters results by type
	fields_only         bool     // for displaying only the struct/enum fields
	modules_aliases     []string // for displaying module symbols or module list
	imports_list        []string // for completion_items_from_dir and import symbols list
	is_mut              bool     // filters results based on the object's mutability state.
}

// completion_items_from_stmt returns a list of results from the extracted Stmt node info.
fn (mut cfg CompletionItemConfig) completion_items_from_stmt(stmt ast.Stmt) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	match stmt {
		ast.ExprStmt {
			completion_items << cfg.completion_items_from_expr(stmt.expr)
		}
		ast.AssignStmt {
			if stmt.op != .decl_assign {
				// When reassigning a new value, the server must display
				// the list of available symbols that have the same type
				// as the variable on the left.
				cfg.show_global = false
				cfg.show_only_global_fn = false
				cfg.filter_type = stmt.left_types[stmt.left_types.len - 1]
			}
		}
		ast.Import {
			cfg.show_global = false
			cfg.show_local = false
			dir := os.dir(cfg.file.path)
			dir_contents := os.ls(dir) or { []string{} }

			// Checks the offset if it is within the import symbol section
			// a.k.a import <module_name> { <import symbols> }
			if is_within_pos(cfg.offset, stmt.syms_pos) {
				already_imported := stmt.syms.map(it.name)

				for _, idx in cfg.table.type_idxs {
					type_sym := unsafe { &cfg.table.type_symbols[idx] }
					name := type_sym.name.all_after(type_sym.mod + '.')
					if type_sym.mod != stmt.mod || name in already_imported {
						continue
					}
					match type_sym.kind {
						.struct_ {
							completion_items << lsp.CompletionItem{
								label: name
								kind: .struct_
								insert_text: name
							}
						}
						.enum_ {
							completion_items << lsp.CompletionItem{
								label: name
								kind: .enum_
								insert_text: name
							}
						}
						.interface_ {
							completion_items << lsp.CompletionItem{
								label: name
								kind: .interface_
								insert_text: name
							}
						}
						.sum_type, .alias {
							completion_items << lsp.CompletionItem{
								label: name
								kind: .type_parameter
								insert_text: name
							}
						}
						else {
							continue
						}
					}
				}

				for _, fnn in cfg.table.fns {
					name := fnn.name.all_after(fnn.mod + '.')

					if fnn.mod == stmt.mod && name !in already_imported && fnn.is_pub {
						completion_items << lsp.CompletionItem{
							label: name
							kind: .function
							insert_text: name
						}
					}
				}
			} else {
				// list all folders
				completion_items << cfg.completion_items_from_dir(dir, dir_contents, '')
				// list all vlib
				// TODO: vlib must be computed at once only
			}
		}
		ast.Module {
			completion_items << cfg.suggest_mod_names()
		}
		else {}
	}
	return completion_items
}

// completion_items_from_table returns a list of results extracted from the type symbols of the ast.
fn (mut cfg CompletionItemConfig) completion_items_from_table(mod_name string, symbols ...string) []lsp.CompletionItem {
	// NB: symbols of the said module does not show the full list
	// unless by pressing cmd/ctrl+space or by pressing escape key
	// + deleting the dot + typing again the dot
	mut completion_items := []lsp.CompletionItem{}

	// Do not proceed if the functions the only ones required
	// to be displayed to the client
	if cfg.show_global && cfg.show_only_global_fn {
		return completion_items
	}

	for sym_name, idx in cfg.table.type_idxs {
		// Just to make sure, negative type indexes or greater than the type table
		// length are not allowed. Symbols names that does not start with a given
		// module name are also not allowed.
		valid_type := idx >= 0 || idx < cfg.table.type_symbols.len
		sym_part_of_module := mod_name.len > 0 && sym_name.starts_with('${mod_name}.')
		name := sym_name.all_after('${mod_name}.')
		if valid_type || sym_part_of_module || (symbols.len > 0 && name in symbols) {
			type_sym := unsafe { &cfg.table.type_symbols[idx] }
			if type_sym.mod != mod_name {
				continue
			}
			completion_items << cfg.completion_items_from_type_sym(name, type_sym, false)
		}
	}
	return completion_items
}

// completion_items_from_expr returns a list of results extracted from the Expr node info.
fn (mut cfg CompletionItemConfig) completion_items_from_expr(expr ast.Expr) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}

	match expr {
		ast.SelectorExpr {
			cfg.show_global = false
			cfg.show_local = false

			// If the expr_type is zero and the ident is a
			// module, then it should include a list of public
			// symbols of that module.
			if expr.expr_type == 0 && expr.expr is ast.Ident {
				ident := expr.expr as ast.Ident
				if ident.name !in cfg.modules_aliases {
					return completion_items
				}
				completion_items << cfg.completion_items_from_table(ident.name)
				for _, fnn in cfg.table.fns {
					if fnn.mod == ident.name && fnn.is_pub {
						completion_items << cfg.completion_items_from_fn(fnn, false)
					}
				}
			} else if expr.expr_type != 0 || expr.typ != 0 {
				selected_typ := if expr.typ != 0 { expr.typ } else { expr.expr_type }
				type_sym := cfg.table.get_type_symbol(selected_typ)
				if root := expr.root_ident() {
					if root.obj is ast.Var {
						cfg.is_mut = root.obj.is_mut
					}
				}

				// Include the list of available struct fields based on the type info
				completion_items << cfg.completion_items_from_type_sym('', type_sym, true)

				// If the selected type is an array or map type, it should
				// include the fields and methods of map/array type.
				if type_sym.kind == .array || type_sym.kind == .map {
					base_symbol_name := if type_sym.kind == .array { 'array' } else { 'map' }
					if base_type_sym := cfg.table.find_type(base_symbol_name) {
						completion_items << cfg.completion_items_from_type_sym('', base_type_sym,
							true)
					}
				}
				// Include all the type methods
				for m in type_sym.methods {
					// If SelectorExpr is immutable and the method is mutable,
					// it should be excluded.
					if !cfg.is_mut && m.params[0].is_mut {
						continue
					}
					completion_items << cfg.completion_items_from_fn(m, true)
				}
			}
			return completion_items
		}
		ast.CallExpr {
			// Filter the list of local symbols based on
			// the current arg's type.
			if expr.args.len < expr.expected_arg_types.len {
				cfg.show_local = true
				cfg.filter_type = expr.expected_arg_types[expr.args.len]
			} else {
				cfg.show_local = false
			}
			cfg.show_global = false
			return completion_items
		}
		ast.StructInit {
			cfg.show_global = false
			cfg.show_local = false
			field_node := find_ast_by_pos(expr.fields.map(ast.Node(it)), cfg.offset - 1) or {
				ast.empty_node()
			}
			if field_node is ast.StructInitField {
				completion_items << cfg.completion_items_from_struct_init_field(field_node)
			} else {
				// if structinit is empty or not within the field position,
				// it must include the list of missing fields instead
				defined_fields := expr.fields.map(it.name)
				struct_type_sym := cfg.table.get_type_symbol(expr.typ)
				struct_type_info := struct_type_sym.info as ast.Struct
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

// completion_items_from_struct_init_field returns the list of items extracted from the ast.StructInitField information
// TODO: move it to a single method once other nodes are supported.
fn (mut cfg CompletionItemConfig) completion_items_from_struct_init_field(field ast.StructInitField) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}

	// NB: enable local results only if the node is a field
	cfg.show_local = true
	cfg.show_global = false
	field_type_sym := cfg.table.get_type_symbol(field.expected_type)
	completion_items << cfg.completion_items_from_type_sym('', field_type_sym, field_type_sym.info is ast.Enum)
	cfg.filter_type = field.expected_type

	return completion_items
}

// completion_items_from_fn returns the list of items extracted from the table.Fn information
fn (mut _ CompletionItemConfig) completion_items_from_fn(fnn ast.Fn, is_method bool) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}

	if fnn.is_main {
		return completion_items
	}

	fn_name := fnn.name.all_after(fnn.mod + '.')
	// This will create a snippet that will automatically
	// create a call expression based on the information of the function
	mut insert_text := fn_name
	mut i := 0

	kind := if is_method { lsp.CompletionItemKind.method } else { lsp.CompletionItemKind.function }
	if fnn.generic_names.len > 0 {
		insert_text += '<'
		for gi, gn in fnn.generic_names {
			if gi != 0 {
				insert_text += ', '
			}
			insert_text += '\${$i:$gn}'
			i++
		}
		insert_text += '>'
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
		insert_text += ' or { panic(err.msg) }'
	}
	completion_items << lsp.CompletionItem{
		label: fn_name
		kind: kind
		insert_text_format: .snippet
		insert_text: insert_text
	}
	return completion_items
}

// completion_items_from_type_sym returns the list of items extracted from the type symbol.
fn (mut cfg CompletionItemConfig) completion_items_from_type_sym(name string, type_sym ast.TypeSymbol, fields_only bool) []lsp.CompletionItem {
	type_info := type_sym.info
	mut completion_items := []lsp.CompletionItem{}
	match type_info {
		ast.Struct {
			if fields_only {
				for field in type_info.fields {
					if !field.is_pub && cfg.file.mod.name != type_sym.mod {
						continue
					}
					completion_items << lsp.CompletionItem{
						label: field.name
						kind: .field
						insert_text: field.name
					}
				}
			} else {
				mut insert_text := '$name{\n'
				mut i := type_info.fields.len - 1
				for field in type_info.fields {
					if (!field.is_pub && cfg.file.mod.name != type_sym.mod)
						|| field.has_default_expr {
						continue
					}
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
			}
		}
		ast.Enum {
			for val in type_info.vals {
				// Use short enum syntax when reassigning, within
				// struct fields, and etc.
				label := if fields_only { '.$val' } else { '${name}.$val' }
				completion_items << lsp.CompletionItem{
					label: label
					kind: .enum_member
					insert_text: label
				}
			}
		}
		ast.Alias, ast.SumType, ast.FnType, ast.Interface {
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

// completion_items_from_dir returns the list of import-able folders for autocompletion.
fn (cfg CompletionItemConfig) completion_items_from_dir(dir string, dir_contents []string, prefix string) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	for name in dir_contents {
		full_path := os.join_path(dir, name)
		if !os.is_dir(full_path) || name in cfg.imports_list || name.starts_with('.') {
			continue
		}
		subdir_contents := os.ls(full_path) or { []string{} }
		mod_name := if prefix.len > 0 { '${prefix}.$name' } else { name }
		if name == 'modules' {
			completion_items << cfg.completion_items_from_dir(full_path, subdir_contents,
				mod_name)
			continue
		}
		completion_items << lsp.CompletionItem{
			label: mod_name
			kind: .folder
			insert_text: mod_name
		}
		completion_items << cfg.completion_items_from_dir(full_path, subdir_contents,
			mod_name)
	}
	return completion_items
}

fn (mut cfg CompletionItemConfig) suggest_mod_names() []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	// Explicitly disabling the global and local completion
	// should never happen but just to make sure.
	cfg.show_global = false
	cfg.show_local = false
	folder_name := os.base(os.dir(cfg.file.path)).replace(' ', '_')
	module_name_suggestions := ['module main', 'module $folder_name']
	for sg in module_name_suggestions {
		completion_items << lsp.CompletionItem{
			label: sg
			insert_text: sg
			kind: .variable
		}
	}
	return completion_items
}

// TODO: make params use lsp.CompletionParams in the future
[manualfree]
fn (mut ls Vls) completion(id int, params string) {
	if Feature.completion !in ls.enabled_features {
		return
	}
	completion_params := json.decode(lsp.CompletionParams, params) or { 
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}
	file_uri := completion_params.text_document.uri
	file := ls.files[file_uri.str()]
	src := ls.sources[file_uri.str()]
	pos := completion_params.position

	// The context is used for if and when to trigger autocompletion.
	// See comments `cfg` for reason.
	mut ctx := completion_params.context

	// This is where the items will be pushed and sent to the client.
	mut completion_items := []lsp.CompletionItem{}

	// The config is used by all methods for determining the results to be sent
	// to the client. See the field comments in CompletionItemConfig for their
	// purposes.
	//
	// Other parsers use line character-based position for determining the AST node.
	// The V parser on the other hand, uses a byte offset (line number is supplied
	// but for certain cases) hence the need to convert the said positions to byte
	// offsets.
	//
	// NOTE: Transfer it back to struct fields after
	// https://github.com/vlang/v/pull/7976 has been merged.
	modules_aliases := file.imports.map(it.alias)
	imports_list := file.imports.map(it.mod)
	mut cfg := CompletionItemConfig{
		file: file
		modules_aliases: modules_aliases
		imports_list: imports_list
		offset: compute_offset(src, pos.line, pos.character)
		table: ls.tables[file_uri.dir()]
	}
	// There are some instances that the user would invoke the autocompletion
	// through a combination of shortcuts (like Ctrl/Cmd+Space) and the results
	// wouldn't appear even though one of the trigger characters is on the left
	// or near the cursor. In that case, the context data would be modified in
	// order to satisfy those specific cases.
	if ctx.trigger_kind == .invoked && cfg.offset - 1 >= 0 && file.stmts.len > 0 && src.len > 3 {
		mut prev_idx := cfg.offset
		mut ctx_changed := false
		if src[cfg.offset - 1] in [`.`, `:`, `=`, `{`, `,`, `(`] {
			prev_idx--
			ctx_changed = true
		} else if src[cfg.offset - 1] == ` ` && cfg.offset - 2 >= 0
			&& src[cfg.offset - 2] !in [src[cfg.offset - 1], `.`] {
			prev_idx -= 2
			cfg.offset -= 2
			ctx_changed = true
		}

		if ctx_changed {
			ctx = lsp.CompletionContext{
				trigger_kind: .trigger_character
				trigger_character: src[prev_idx].str()
			}
		}
	}
	// The language server uses the `trigger_character` as a sole basis for triggering
	// the data extraction and autocompletion. The `trigger_character` kind is only
	// received by the server if the user presses one of the server-defined trigger
	// characters [dot, parenthesis, curly brace, etc.]
	if ctx.trigger_kind == .trigger_character {
		// NOTE: DO NOT REMOVE YET ~ @ned
		// // The offset is adjusted and the suggestions for local and global symbols are
		// // disabled if a period/dot is detected and the character on the left is not a space.
		// if ctx.trigger_character == '.' && (cfg.offset - 1 >= 0 && src[cfg.offset - 1] != ` `) {
		// 	cfg.show_global = false
		// 	cfg.show_local = false
		// 	cfg.offset -= 2
		// }
		if src[cfg.offset - 1] == ` ` {
			cfg.offset--
		}

		// Once the offset has been finalized it will then search for the AST node and
		// extract it's data using the corresponding methods depending on the node type.
		node := find_ast_by_pos(file.stmts.map(ast.Node(it)), cfg.offset) or { ast.empty_node() }
		match node {
			ast.Stmt {
				completion_items << cfg.completion_items_from_stmt(node)
			}
			ast.Expr {
				completion_items << cfg.completion_items_from_expr(node)
			}
			ast.StructInitField {
				completion_items << cfg.completion_items_from_struct_init_field(node)
			}
			else {}
		}
	} else if ctx.trigger_kind == .invoked && (file.stmts.len == 0 || src.len <= 3) {
		// When a V file is empty, a list of `module $name` suggsestions will be displayed.
		completion_items << cfg.suggest_mod_names()
	} else {
		// Display only the project's functions if none are satisfied
		cfg.show_only_global_fn = true
	}

	// Local results. Module names and the scope-based symbols.
	if cfg.show_local {
		// Imported modules. They will be shown to the user if there is no given
		// type for filtering the results. Invalid imports are excluded.
		for imp in file.imports {
			if imp.syms.len == 0 && (cfg.filter_type == ast.Type(0)
				|| imp.mod !in ls.invalid_imports[file_uri.str()]) {
				completion_items << lsp.CompletionItem{
					label: imp.alias
					kind: .module_
					insert_text: imp.alias
				}
			}
		}

		// Scope-based symbols that includes the variables inside
		// the functions and the constants of the file.
		inner_scope := file.scope.innermost(cfg.offset)
		for scope in [file.scope, inner_scope] {
			for _, obj in scope.objects {
				mut name := ''
				match obj {
					ast.ConstField, ast.Var {
						if cfg.filter_type != ast.Type(0) && obj.typ != cfg.filter_type {
							continue
						}
						name = obj.name
					}
					else {
						continue
					}
				}
				mut kind := lsp.CompletionItemKind.variable
				if obj is ast.ConstField {
					name = name.all_after('${obj.mod}.')
					kind = .constant
				}
				completion_items << lsp.CompletionItem{
					label: name
					kind: kind
					insert_text: name
				}
			}
		}
	}
	// Global results. This includes all the symbols within the module such as
	// the structs, typedefs, enums, and the functions.
	if cfg.show_global {
		mut import_symbols := []string{}
		for imp in cfg.file.imports {
			if imp.syms.len == 0 {
				continue
			}
			for sym in imp.syms {
				import_symbols << imp.mod + '.' + sym.name
			}
			completion_items << cfg.completion_items_from_table(imp.mod, ...imp.syms.map(it.name))
		}

		// In table, functions are separated from type symbols.
		completion_items << cfg.completion_items_from_table(file.mod.name)

		// This part will extract the functions from both the builtin module and
		// within the module (except the main() fn if present.)
		for _, fnn in cfg.table.fns {
			if fnn.mod == file.mod.name
				|| (fnn.mod == 'builtin' && fnn.name in ls.builtin_symbols)
				|| (fnn.mod in cfg.imports_list && fnn.name in import_symbols) {
				completion_items << cfg.completion_items_from_fn(fnn, false)
			}
		}
		unsafe { import_symbols.free() }
	}
	// After that, it will send the list to the client.
	ls.send(jsonrpc.Response<[]lsp.CompletionItem>{
		id: id
		result: completion_items
	})
	unsafe {
		completion_items.free()
		modules_aliases.free()
		imports_list.free()
	}
}

struct HoverConfig {
mut:
	file   ast.File
	offset int // position of the cursor. used for finding the AST node
	table  &ast.Table
}

// hover_from_stmt returns the hover data for a specific ast.Stmt.
fn (mut cfg HoverConfig) hover_from_stmt(node ast.Stmt) ?lsp.Hover {
	mut pos := node.pos
	match node {
		ast.Module {
			name := if node.short_name.len > 0 { node.short_name } else { node.name }
			return lsp.Hover{
				contents: lsp.v_marked_string('module $name')
				range: position_to_lsp_range(pos.extend(node.name_pos))
			}
		}
		ast.FnDecl {
			if node.return_type == ast.Type(0) {
				return none
			}
			name := node.name.all_after(cfg.file.mod.short_name + '.')
			return_type_name := cfg.table.type_to_str(node.return_type)
			mut signature := 'fn'
			if node.is_method {
				signature += ' ('
				receiver := node.params[0]
				mut receiver_type_name := cfg.table.type_to_str(receiver.typ)
				if receiver.is_mut {
					signature += 'mut '
					receiver_type_name = receiver_type_name.all_after('&')
				}
				signature += '$receiver.name $receiver_type_name'
				signature += ') '
			}
			signature += ' ${name}('
			for i := int(node.is_method); i < node.params.len; i++ {
				param := node.params[i]
				mut type_name := cfg.table.type_to_str(param.typ)
				if param.is_mut {
					signature += 'mut '
					type_name = type_name.all_after('&')
				}
				signature += '$param.name $type_name'
				if i != node.params.len - 1 {
					signature += ', '
				}
			}
			signature += ') $return_type_name'
			return lsp.Hover{
				contents: lsp.v_marked_string(signature)
				range: position_to_lsp_range(pos)
			}
		}
		ast.StructDecl {
			name := node.name.all_after(cfg.file.mod.short_name + '.')
			return lsp.Hover{
				contents: lsp.v_marked_string('struct $name')
				range: position_to_lsp_range(pos)
			}
		}
		ast.EnumDecl {
			name := node.name.all_after(cfg.file.mod.short_name + '.')
			return lsp.Hover{
				contents: lsp.v_marked_string('enum $name')
				range: position_to_lsp_range(pos)
			}
		}
		ast.TypeDecl {
			mut name := ''
			mut branches := ''

			match node {
				ast.AliasTypeDecl {
					if node.parent_type == ast.Type(0) {
						return none
					}
					name = node.name
					branches = cfg.table.type_to_str(node.parent_type)
				}
				ast.FnTypeDecl {
					if node.typ == ast.Type(0) {
						return none
					}
					name = node.name.all_after(cfg.file.mod.short_name + '.')
					branches = cfg.table.type_to_str(node.typ)
				}
				ast.SumTypeDecl {
					name = node.name
					for i, var in node.variants {
						if var.typ == ast.Type(0) {
							return none
						}
						branches += cfg.table.type_to_str(var.typ)
						if i != node.variants.len - 1 {
							branches += ' | '
						}
					}
				}
			}

			return lsp.Hover{
				contents: lsp.v_marked_string('type $name = $branches')
				range: position_to_lsp_range(pos)
			}
		}
		ast.Return {
			// return and trigger null result for now
			return none
		}
		ast.NodeError {
			return none
		}
		ast.AssignStmt {
			// transfer this code to v.ast module
			mut left_pos := node.left[0].position()
			for i, p in node.left {
				if i == 0 {
					continue
				}
				left_pos = left_pos.extend(p.position())
			}
			pos = left_pos.extend(pos)
		}
		else {}
	}
	return lsp.Hover{
		contents: lsp.v_marked_string(node.str())
		range: position_to_lsp_range(pos)
	}
}

// hover_from_stmt returns the hover data for a specific ast.Expr.
fn (mut cfg HoverConfig) hover_from_expr(node ast.Expr) ?lsp.Hover {
	match node {
		ast.Ident {
			obj := cfg.file.scope.innermost(cfg.offset)
			obj_node := obj.find_var(node.name) ?
			if obj_node.typ == ast.Type(0) {
				return none
			}
			range := position_to_lsp_range(node.pos)
			// TODO: create a wrapper function that will auto-format type
			// based on the VLS style.
			typ_name := cfg.table.type_to_str(obj_node.typ).all_after('main.')
			prefix := if obj_node.is_mut { 'mut ' } else { '' }
			return lsp.Hover{
				contents: lsp.v_marked_string('$prefix$obj_node.name $typ_name')
				range: range
			}
		}
		ast.CallExpr {
			mut signature := ''
			if node.is_method || node.is_field {
				if node.left_type == ast.Type(0) {
					return none
				}
				parent_type_name := cfg.table.type_to_str(node.left_type).all_after('main.')
				signature += parent_type_name + '.'
			}

			name := node.name.all_after('main.')
			signature += '${name}()'
			if node.return_type.is_full() {
				return_type := cfg.table.type_to_str(node.return_type).all_after('main.')
				signature += ' $return_type'
			}
			range := position_to_lsp_range(node.pos)

			return lsp.Hover{
				contents: lsp.v_marked_string(signature)
				range: range
			}
		}
		ast.SelectorExpr {
			if node.expr is ast.Ident || is_within_pos(cfg.offset, node.pos) {
				if node.typ == ast.Type(0) {
					return none
				}
				range := position_to_lsp_range(node.pos)
				typ_name := cfg.table.type_to_str(node.typ).all_after('main.')
				parent_name := if node.expr_type != ast.Type(0) {
					cfg.table.type_to_str(node.expr_type).all_after('main.') + '.'
				} else {
					''
				}
				field_name := '$parent_name$node.field_name'
				prefix := if node.is_mut { 'mut ' } else { '' }
				return lsp.Hover{
					contents: lsp.v_marked_string('$prefix$field_name $typ_name')
					range: range
				}
			}
			return cfg.hover_from_expr(node.expr)
		}
		ast.NodeError {
			return none
		}
		else {
			return lsp.Hover{
				contents: lsp.v_marked_string(node.str())
				range: position_to_lsp_range(node.position())
			}
		}
	}
}

fn (mut ls Vls) hover(id int, params string) {
	hover_params := json.decode(lsp.HoverParams, params) or { 
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}

	uri := hover_params.text_document.uri
	pos := hover_params.position

	mut cfg := HoverConfig{
		file: ls.files[uri.str()]
		table: ls.tables[uri.dir()]
		offset: compute_offset(ls.sources[uri.str()], pos.line, pos.character)
	}

	// an AST walker will find a node based on the offset
	node := find_ast_by_pos(cfg.file.stmts.map(ast.Node(it)), cfg.offset) or {
		ls.send_null(id)
		return
	}

	mut hover_data := lsp.Hover{}

	// the contents of the node will be extracted and be injected
	// into the hover_data variable
	// TODO: simplify == tablt.Type(0) checking in the future
	match node {
		ast.Stmt {
			hover_data = cfg.hover_from_stmt(node) or {
				ls.send_null(id)
				return
			}
		}
		ast.Expr {
			hover_data = cfg.hover_from_expr(node) or {
				ls.send_null(id)
				return
			}
		}
		ast.StructField {
			if node.typ == ast.Type(0) {
				ls.send_null(id)
				return
			}
			range := position_to_lsp_range(node.pos.extend(node.type_pos))
			typ_name := cfg.table.type_to_str(node.typ).all_after('main.')
			hover_data = lsp.Hover{
				contents: lsp.v_marked_string('$node.name $typ_name')
				range: range
			}
		}
		ast.StructInitField {
			if node.expected_type == ast.Type(0) {
				ls.send_null(id)
				return
			}
			range := position_to_lsp_range(node.pos)
			typ_name := cfg.table.type_to_str(node.expected_type).all_after('main.')
			hover_data = lsp.Hover{
				contents: lsp.v_marked_string('$node.name $typ_name')
				range: range
			}
		}
		ast.Param {
			if node.typ == ast.Type(0) {
				ls.send_null(id)
				return
			}
			range := position_to_lsp_range(node.pos.extend(node.type_pos))
			mut type_name := cfg.table.type_to_str(node.typ).all_after('main.')
			if node.is_mut {
				type_name = type_name[1..]
			}
			prefix := if node.is_mut { 'mut ' } else { '' }
			hover_data = lsp.Hover{
				contents: lsp.v_marked_string('$prefix$node.name $type_name')
				range: range
			}
		}
		else {
			// returns a null result for unsupported nodes
			ls.send_null(id)
			return
		}
	}
	ls.send(jsonrpc.Response<lsp.Hover>{
		id: id
		result: hover_data
	})
}

[manualfree]
fn (mut ls Vls) folding_range(id int, params string) {
	folding_range_params := json.decode(lsp.FoldingRangeParams, params) or { 
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}
	uri := folding_range_params.text_document.uri
	file := ls.files[uri.str()] or {
		ls.send_null(id)
		return
	}
	mut folding_ranges := []lsp.FoldingRange{}

	// TODO: enable parsing with .toplevel_comments included
	for stmt in file.stmts {
		match stmt {
			ast.ExprStmt {
				if stmt.expr is ast.Comment {
					range := position_to_lsp_range(stmt.expr.pos)
					folding_ranges << lsp.FoldingRange{
						start_line: range.start.line
						start_character: range.start.character
						end_line: range.end.line
						end_character: range.end.character
						kind: lsp.folding_range_kind_comment
					}
				}
			}
			ast.StructDecl, ast.EnumDecl, ast.FnDecl, ast.InterfaceDecl {
				range := position_to_lsp_range(stmt.pos)
				folding_ranges << lsp.FoldingRange{
					start_line: range.start.line
					start_character: range.start.character
					end_line: range.end.line
					end_character: range.end.character
					kind: lsp.folding_range_kind_region
				}
			}
			else {}
		}
	}

	if folding_ranges.len == 0 {
		ls.send_null(id)
	} else {
		ls.send(jsonrpc.Response<[]lsp.FoldingRange>{
			id: id
			result: folding_ranges
		})
	}
	unsafe {
		folding_ranges.free()
	}
}

struct DefinitionConfig {
	uri                      lsp.DocumentUri
	builtin_symbol_locations map[string]lsp.Location
	symbol_locations         map[string]lsp.Location
	table                    &ast.Table
	mod                      string
}

fn (cfg DefinitionConfig) get_symbol_location(pos token.Position, entry_name string) ?lsp.LocationLink {
	loc := cfg.builtin_symbol_locations[entry_name] or { cfg.symbol_locations[entry_name] ? }

	// NB: Compiling VLS without gc returns a symbol location data
	// with an empty URI. This is triggered just to make sure.
	if loc.uri.len == 0 {
		return error('empty URI')
	}

	return lsp.LocationLink{
		origin_selection_range: position_to_lsp_range(pos)
		target_uri: loc.uri
		target_range: loc.range
		target_selection_range: loc.range
	}
}

fn (cfg DefinitionConfig) definition_from_scope_obj(node ast.Expr, obj ast.ScopeObject) ?lsp.LocationLink {
	match obj {
		ast.Var, ast.ConstField {
			target_range := position_to_lsp_range(obj.pos)
			return lsp.LocationLink{
				origin_selection_range: position_to_lsp_range(node.position())
				target_uri: cfg.uri
				target_range: target_range
				target_selection_range: target_range
			}
		}
		else {
			return none
		}
	}
}

fn (cfg DefinitionConfig) definition_from_expr(node ast.Expr) ?lsp.LocationLink {
	match node {
		ast.Ident {
			return cfg.definition_from_scope_obj(node, node.obj)
		}
		ast.CallExpr {
			name := if node.name in cfg.builtin_symbol_locations {
				node.name
			} else {
				'${cfg.mod}.$node.name'
			}
			return cfg.get_symbol_location(node.name_pos, name)
		}
		ast.SelectorExpr {
			if node.expr_type == ast.Type(0) {
				return none
			}

			struct_type_name := cfg.table.type_to_str(node.expr_type)
			return cfg.get_symbol_location(node.pos, '${struct_type_name}.$node.field_name')
		}
		ast.StructInit {
			if node.typ == ast.Type(0) {
				return none
			}

			return cfg.get_symbol_location(node.name_pos, cfg.table.type_to_str(node.typ))
		}
		ast.EnumVal {
			if node.typ == ast.Type(0) {
				return none
			}

			enum_type_name := cfg.table.type_to_str(node.typ)
			return cfg.get_symbol_location(node.pos, '${enum_type_name}.$node.val')
		}
		else {
			return none
		}
	}
}

fn (mut ls Vls) definition(id int, params string) {
	goto_definition_params := json.decode(lsp.TextDocumentPositionParams, params) or {
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}
	uri := goto_definition_params.text_document.uri
	pos := goto_definition_params.position
	source := ls.sources[uri.str()]
	file := ls.files[uri.str()]
	offset := compute_offset(source, pos.line, pos.character)

	mut cfg := DefinitionConfig{
		uri: uri
		mod: file.mod.short_name
		builtin_symbol_locations: ls.builtin_symbol_locations
		symbol_locations: ls.symbol_locations[uri.dir()]
		table: ls.tables[uri.dir()]
	}
	mut res := lsp.LocationLink{}

	// an AST walker will find a node based on the offset
	mut node := find_ast_by_pos(ast.Node(file).children(), offset) or {
		ls.send_null(id)
		return
	}

	// for CallExpr and SelectorExpr nodes, both of which
	// have a special code inside the AST walker, will need to
	// have another check if the position is within their children
	// before doing another AST traversal
	mut should_find_child := false
	if mut node is ast.Expr {
		should_find_child = if mut node is ast.CallExpr {
			!is_within_pos(offset, node.name_pos)
		} else if mut node is ast.SelectorExpr {
			!is_within_pos(offset, node.pos)
		} else {
			false
		}
	}

	if should_find_child {
		// falls back to the parent node if there's no child node found
		node = find_ast_by_pos(node.children(), offset) or { node }
	}

	match mut node {
		ast.Stmt {
			if mut node is ast.FnDecl {
				if !is_within_pos(offset, node.return_type_pos) {
					ls.send_null(id)
					return
				}

				type_name := cfg.table.type_to_str(node.return_type)
				res = cfg.get_symbol_location(node.return_type_pos, type_name) or {
					ls.send_null(id)
					return
				}
			}
		}
		ast.Expr {
			res = cfg.definition_from_expr(node) or {
				ls.log_message(err.msg, .info)
				ls.send_null(id)
				return
			}
		}
		ast.CallArg {
			res = cfg.definition_from_expr(node.expr) or {
				ls.send_null(id)
				return
			}
		}
		ast.StructInitField {
			if !is_within_pos(offset, node.name_pos) || node.parent_type == ast.Type(0) {
				ls.send_null(id)
				return
			}

			struct_type_name := cfg.table.type_to_str(node.parent_type)
			res = cfg.get_symbol_location(node.name_pos, '${struct_type_name}.$node.name') or {
				ls.send_null(id)
				return
			}
		}
		ast.Param, ast.StructField {
			if !is_within_pos(offset, node.type_pos) {
				ls.send_null(id)
				return
			}

			type_name := cfg.table.type_to_str(node.typ)
			res = cfg.get_symbol_location(node.type_pos, type_name) or {
				ls.send_null(id)
				return
			}
		}
		else {
			// for unsupported nodes, the server will return null.
			ls.send_null(id)
			return
		}
	}

	ls.send(jsonrpc.Response<lsp.LocationLink>{
		id: id
		result: res
	})
}
