module vls

import lsp
import json
import jsonrpc
import os
import analyzer

const temp_formatting_file_path = os.join_path(os.temp_dir(), 'vls_temp_formatting.v')

[manualfree]
fn (mut ls Vls) formatting(id int, params string) {
	formatting_params := json.decode(lsp.DocumentFormattingParams, params) or {
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}

	uri := formatting_params.text_document.uri
	source := ls.sources[uri].source
	tree_range := ls.trees[uri].root_node().range()
	if source.len == 0 {
		ls.send_null(id)
		return
	}

	// We don't integrate v.fmt and it's dependencies anymore to lessen
	// cleanups everytime launching an instance.
	//
	// To simplify this, we will make a temporary file and feed it into
	// the v fmt CLI program since there is no cross-platform way to pipe
	// raw strings directly into v fmt.
	mut temp_file := os.open_file(vls.temp_formatting_file_path, 'w') or {
		ls.send_null(id)
		return
	}

	temp_file.write(source) or {
		ls.send_null(id)
		return
	}

	temp_file.close()
	fmt_res := os.execute('v fmt $vls.temp_formatting_file_path')
	if fmt_res.exit_code > 0 {
		ls.show_message(fmt_res.output, .info)
		ls.send_null(id)
		return
	}

	resp := jsonrpc.Response<[]lsp.TextEdit>{
		id: id
		result: [lsp.TextEdit{
			range: tsrange_to_lsp_range(tree_range)
			new_text: fmt_res.output
		}]
	}

	ls.send(resp)
	os.rm(vls.temp_formatting_file_path) or {}
	unsafe {
		fmt_res.output.free()
	}
}

fn (mut ls Vls) workspace_symbol(id int, _ string) {
	mut workspace_symbols := []lsp.SymbolInformation{}

	for _, sym_arr in ls.store.symbols {
		for sym in sym_arr {
			uri := lsp.document_uri_from_path(sym.file_path)
			if uri !in ls.trees {
				unsafe { uri.free() }
				continue
			}

			sym_info := symbol_to_symbol_info(uri, sym, '') or { continue }
			workspace_symbols << sym_info
			workspace_symbols << methods_to_symbol_infos(uri, sym)
		}
	}

	ls.send(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: id
		result: workspace_symbols
	})
}

fn symbol_to_symbol_info(uri lsp.DocumentUri, sym &analyzer.Symbol, prefix string) ?lsp.SymbolInformation {
	mut kind := lsp.SymbolKind.null
	match sym.kind {
			.function { kind = .function }
			.struct_ { kind = .struct_ }
			.enum_ { kind = .enum_ }
			.typedef { kind = .type_parameter }
			.interface_ { kind = .interface_ }
			.field { kind = .field }
			.variable { kind = .constant }
		else { return none }
	}

	return lsp.SymbolInformation{
		name: prefix + sym.name
		kind: kind
		location: lsp.Location{
			uri: uri
			range: tsrange_to_lsp_range(sym.range)
		}
	}
}

fn methods_to_symbol_infos(uri lsp.DocumentUri, sym &analyzer.Symbol) []lsp.SymbolInformation {
	mut symbol_infos := []lsp.SymbolInformation{cap: sym.children.len}
	for child_sym in sym.children {
		if child_sym.kind != .function {
			continue
		}

		method_sym_info := symbol_to_symbol_info(uri, child_sym, '${sym.name}.') or {
			continue
		}

		symbol_infos << lsp.SymbolInformation{
			...method_sym_info,
			kind: .method
		}
	}
	return symbol_infos
}

fn (mut ls Vls) document_symbol(id int, params string) {
	document_symbol_params := json.decode(lsp.DocumentSymbolParams, params) or {
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}

	uri := document_symbol_params.text_document.uri
	retrieved_symbols := ls.store.get_symbols_by_file_path(uri.path())
	mut document_symbols := []lsp.SymbolInformation{}
	for sym in retrieved_symbols {
		sym_info := symbol_to_symbol_info(uri, sym, '') or { continue }
		document_symbols << sym_info
		document_symbols << methods_to_symbol_infos(uri, sym)
	}

	ls.send(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: id
		result: document_symbols
	})
}

fn (mut ls Vls) signature_help(id int, params string) {
	// Initial checks.
	signature_params := json.decode(lsp.SignatureHelpParams, params) or {
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}

	if Feature.signature_help !in ls.enabled_features {
		ls.send_null(id)
		return
	}

	// Fetch the node requested for completion.
	uri := signature_params.text_document.uri.str()
	pos := signature_params.position
	ctx := signature_params.context
	source := ls.sources[uri].source
	tree := ls.trees[uri]
	off := compute_offset(source, pos.line, pos.character)
	mut node := traverse_node(tree.root_node(), u32(off))
	if node.get_type() == 'argument_list' {
		node = node.parent()
	}

	// signature help supports function calls for now
	// hence checking the node if it's a call_expression node.
	if node.is_null() || node.get_type() != 'call_expression' {
		ls.send_null(id)
		return
	}

	sym := ls.store.infer_symbol_from_node(node, source) or {
		ls.send_null(id)
		return
	}

	args_node := node.child_by_field_name('arguments')
	// for retrigger, it utilizes the current signature help data
	if ctx.is_retrigger {
		mut active_sighelp := ctx.active_signature_help

		if ctx.trigger_kind == .content_change {
			// change the current active param value to the length of the current args.
			active_sighelp.active_parameter = int(args_node.named_child_count()) - 1
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
	
	mut param_infos := []lsp.ParameterInformation{}
	for child_sym in sym.children {
		if child_sym.kind != .variable {
			continue
		}
		
		param_infos << lsp.ParameterInformation{
			label: child_sym.gen_str()
		}
	}

	ls.send(jsonrpc.Response<lsp.SignatureHelp>{
		id: id
		result: lsp.SignatureHelp{
			signatures: [lsp.SignatureInformation{
				label: sym.gen_str()
				// documentation: lsp.MarkupContent{}
				parameters: param_infos
			}]
		}
	})
}

struct CompletionItemConfig {
mut:
	// table               &ast.Table
	show_global         bool = true // for displaying global (project) symbols
	show_only_global_fn bool     // for displaying only the functions of the project
	show_local          bool     = true // for displaying local variables
	// filter_type         ast.Type = ast.Type(0) // filters results by type
	fields_only         bool     // for displaying only the struct/enum fields
	is_mut              bool     // filters results based on the object's mutability state.
}

// // completion_items_from_stmt returns a list of results from the extracted Stmt node info.
// fn (mut cfg CompletionItemConfig) completion_items_from_stmt(stmt ast.Stmt) []lsp.CompletionItem {
// 	mut completion_items := []lsp.CompletionItem{}
// 	match stmt {
// 		ast.ExprStmt {
// 			completion_items << cfg.completion_items_from_expr(stmt.expr)
// 		}
// 		ast.AssignStmt {
// 			if stmt.op != .decl_assign {
// 				// When reassigning a new value, the server must display
// 				// the list of available symbols that have the same type
// 				// as the variable on the left.
// 				cfg.show_global = false
// 				cfg.show_only_global_fn = false
// 				cfg.filter_type = stmt.left_types[stmt.left_types.len - 1]
// 			}
// 		}
// 		ast.Import {
// 			cfg.show_global = false
// 			cfg.show_local = false
// 			dir := os.dir(cfg.file.path)
// 			dir_contents := os.ls(dir) or { []string{} }

// 			// Checks the offset if it is within the import symbol section
// 			// a.k.a import <module_name> { <import symbols> }
// 			if is_within_pos(cfg.offset, stmt.syms_pos) {
// 				already_imported := stmt.syms.map(it.name)

// 				for _, idx in cfg.table.type_idxs {
// 					type_sym := unsafe { &cfg.table.type_symbols[idx] }
// 					name := type_sym.name.all_after(type_sym.mod + '.')
// 					if type_sym.mod != stmt.mod || name in already_imported {
// 						continue
// 					}
// 					match type_sym.kind {
// 						.struct_ {
// 							completion_items << lsp.CompletionItem{
// 								label: name
// 								kind: .struct_
// 								insert_text: name
// 							}
// 						}
// 						.enum_ {
// 							completion_items << lsp.CompletionItem{
// 								label: name
// 								kind: .enum_
// 								insert_text: name
// 							}
// 						}
// 						.interface_ {
// 							completion_items << lsp.CompletionItem{
// 								label: name
// 								kind: .interface_
// 								insert_text: name
// 							}
// 						}
// 						.sum_type, .alias {
// 							completion_items << lsp.CompletionItem{
// 								label: name
// 								kind: .type_parameter
// 								insert_text: name
// 							}
// 						}
// 						else {
// 							continue
// 						}
// 					}
// 				}

// 				for _, fnn in cfg.table.fns {
// 					name := fnn.name.all_after(fnn.mod + '.')

// 					if fnn.mod == stmt.mod && name !in already_imported && fnn.is_pub {
// 						completion_items << lsp.CompletionItem{
// 							label: name
// 							kind: .function
// 							insert_text: name
// 						}
// 					}
// 				}
// 			} else {
// 				// list all folders
// 				completion_items << cfg.completion_items_from_dir(dir, dir_contents, '')
// 				// list all vlib
// 				// TODO: vlib must be computed at once only
// 			}
// 		}
// 		ast.Module {
// 			completion_items << cfg.suggest_mod_names()
// 		}
// 		else {}
// 	}
// 	return completion_items
// }

// // completion_items_from_table returns a list of results extracted from the type symbols of the ast.
// fn (mut cfg CompletionItemConfig) completion_items_from_table(mod_name string, symbols ...string) []lsp.CompletionItem {
// 	// NB: symbols of the said module does not show the full list
// 	// unless by pressing cmd/ctrl+space or by pressing escape key
// 	// + deleting the dot + typing again the dot
// 	mut completion_items := []lsp.CompletionItem{}

// 	// Do not proceed if the functions the only ones required
// 	// to be displayed to the client
// 	if cfg.show_global && cfg.show_only_global_fn {
// 		return completion_items
// 	}

// 	for sym_name, idx in cfg.table.type_idxs {
// 		// Just to make sure, negative type indexes or greater than the type table
// 		// length are not allowed. Symbols names that does not start with a given
// 		// module name are also not allowed.
// 		valid_type := idx >= 0 || idx < cfg.table.type_symbols.len
// 		sym_part_of_module := mod_name.len > 0 && sym_name.starts_with('${mod_name}.')
// 		name := sym_name.all_after('${mod_name}.')
// 		if valid_type || sym_part_of_module || (symbols.len > 0 && name in symbols) {
// 			type_sym := unsafe { &cfg.table.type_symbols[idx] }
// 			if type_sym.mod != mod_name {
// 				continue
// 			}
// 			completion_items << cfg.completion_items_from_type_sym(name, type_sym, false)
// 		}
// 	}
// 	return completion_items
// }

// completion_items_from_expr returns a list of results extracted from the Expr node info.
// fn (mut cfg CompletionItemConfig) completion_items_from_expr(expr ast.Expr) []lsp.CompletionItem {
// 	mut completion_items := []lsp.CompletionItem{}

// 	match expr {
// 		ast.SelectorExpr {
// 			cfg.show_global = false
// 			cfg.show_local = false

// 			// If the expr_type is zero and the ident is a
// 			// module, then it should include a list of public
// 			// symbols of that module.
// 			if expr.expr_type == 0 && expr.expr is ast.Ident {
// 				if expr.expr.name !in cfg.modules_aliases {
// 					return completion_items
// 				}
// 				completion_items << cfg.completion_items_from_table(expr.expr.name)
// 				for _, fnn in cfg.table.fns {
// 					if fnn.mod == expr.expr.name && fnn.is_pub {
// 						completion_items << cfg.completion_items_from_fn(fnn, false)
// 					}
// 				}
// 			} else if expr.expr_type != 0 || expr.typ != 0 {
// 				selected_typ := if expr.typ != 0 { expr.typ } else { expr.expr_type }
// 				type_sym := cfg.table.get_type_symbol(selected_typ)
// 				if root := expr.root_ident() {
// 					if root.obj is ast.Var {
// 						cfg.is_mut = root.obj.is_mut
// 					}
// 				}

// 				// Include the list of available struct fields based on the type info
// 				completion_items << cfg.completion_items_from_type_sym('', type_sym, true)

// 				// If the selected type is an array or map type, it should
// 				// include the fields and methods of map/array type.
// 				if type_sym.kind == .array || type_sym.kind == .map {
// 					base_symbol_name := if type_sym.kind == .array { 'array' } else { 'map' }
// 					if base_type_sym := cfg.table.find_type(base_symbol_name) {
// 						completion_items << cfg.completion_items_from_type_sym('', base_type_sym,
// 							true)
// 					}
// 				}
// 				// Include all the type methods
// 				for m in type_sym.methods {
// 					// If SelectorExpr is immutable and the method is mutable,
// 					// it should be excluded.
// 					if !cfg.is_mut && m.params[0].is_mut {
// 						continue
// 					}
// 					completion_items << cfg.completion_items_from_fn(m, true)
// 				}
// 			}
// 			return completion_items
// 		}
// 		ast.CallExpr {
// 			// Filter the list of local symbols based on
// 			// the current arg's type.
// 			if expr.args.len < expr.expected_arg_types.len {
// 				cfg.show_local = true
// 				cfg.filter_type = expr.expected_arg_types[expr.args.len]
// 			} else {
// 				cfg.show_local = false
// 			}
// 			cfg.show_global = false
// 			return completion_items
// 		}
// 		ast.StructInit {
// 			cfg.show_global = false
// 			cfg.show_local = false
// 			field_node := find_ast_by_pos(expr.fields.map(ast.Node(it)), cfg.offset - 1) or {
// 				ast.empty_node()
// 			}
// 			if field_node is ast.StructInitField {
// 				completion_items << cfg.completion_items_from_struct_init_field(field_node)
// 			} else {
// 				// if structinit is empty or not within the field position,
// 				// it must include the list of missing fields instead
// 				defined_fields := expr.fields.map(it.name)
// 				struct_type_sym := cfg.table.get_type_symbol(expr.typ)
// 				struct_type_info := struct_type_sym.info as ast.Struct
// 				for field in struct_type_info.fields {
// 					if field.name in defined_fields {
// 						continue
// 					}
// 					completion_items << lsp.CompletionItem{
// 						label: '$field.name:'
// 						kind: .field
// 						insert_text: '$field.name: \$0'
// 						insert_text_format: .snippet
// 					}
// 				}
// 			}
// 		}
// 		else {}
// 	}
// 	return completion_items
// }

// // completion_items_from_struct_init_field returns the list of items extracted from the ast.StructInitField information
// // TODO: move it to a single method once other nodes are supported.
// fn (mut cfg CompletionItemConfig) completion_items_from_struct_init_field(field ast.StructInitField) []lsp.CompletionItem {
// 	mut completion_items := []lsp.CompletionItem{}

// 	// NB: enable local results only if the node is a field
// 	cfg.show_local = true
// 	cfg.show_global = false
// 	field_type_sym := cfg.table.get_type_symbol(field.expected_type)
// 	completion_items << cfg.completion_items_from_type_sym('', field_type_sym, field_type_sym.info is ast.Enum)
// 	cfg.filter_type = field.expected_type

// 	return completion_items
// }

// // completion_items_from_fn returns the list of items extracted from the table.Fn information
// fn (mut _ CompletionItemConfig) completion_items_from_fn(fnn ast.Fn, is_method bool) []lsp.CompletionItem {
// 	mut completion_items := []lsp.CompletionItem{}

// 	if fnn.is_main {
// 		return completion_items
// 	}

// 	fn_name := fnn.name.all_after(fnn.mod + '.')
// 	// This will create a snippet that will automatically
// 	// create a call expression based on the information of the function
// 	mut insert_text := fn_name
// 	mut i := 0

// 	kind := if is_method { lsp.CompletionItemKind.method } else { lsp.CompletionItemKind.function }
// 	if fnn.generic_names.len > 0 {
// 		insert_text += '<'
// 		for gi, gn in fnn.generic_names {
// 			if gi != 0 {
// 				insert_text += ', '
// 			}
// 			insert_text += '\${$i:$gn}'
// 			i++
// 		}
// 		insert_text += '>'
// 	}
// 	insert_text += '('
// 	for j, param in fnn.params {
// 		if is_method && j == 0 {
// 			continue
// 		}
// 		i++
// 		insert_text += '\${$i:$param.name}'
// 		if j < fnn.params.len - 1 {
// 			insert_text += ', '
// 		}
// 	}
// 	insert_text += ')'
// 	if fnn.return_type.has_flag(.optional) {
// 		insert_text += ' or { panic(err.msg) }'
// 	}
// 	completion_items << lsp.CompletionItem{
// 		label: fn_name
// 		kind: kind
// 		insert_text_format: .snippet
// 		insert_text: insert_text
// 	}
// 	return completion_items
// }

// // completion_items_from_type_sym returns the list of items extracted from the type symbol.
// fn (mut cfg CompletionItemConfig) completion_items_from_type_sym(name string, type_sym ast.TypeSymbol, fields_only bool) []lsp.CompletionItem {
// 	type_info := type_sym.info
// 	mut completion_items := []lsp.CompletionItem{}
// 	match type_info {
// 		ast.Struct {
// 			if fields_only {
// 				for field in type_info.fields {
// 					if !field.is_pub && cfg.file.mod.name != type_sym.mod {
// 						continue
// 					}
// 					completion_items << lsp.CompletionItem{
// 						label: field.name
// 						kind: .field
// 						insert_text: field.name
// 					}
// 				}
// 			} else {
// 				mut insert_text := '$name{\n'
// 				mut i := type_info.fields.len - 1
// 				for field in type_info.fields {
// 					if (!field.is_pub && cfg.file.mod.name != type_sym.mod)
// 						|| field.has_default_expr {
// 						continue
// 					}
// 					insert_text += '\t$field.name: \$$i\n'
// 					i--
// 				}
// 				insert_text += '}'
// 				completion_items << lsp.CompletionItem{
// 					label: '$name{}'
// 					kind: .struct_
// 					insert_text: insert_text
// 					insert_text_format: .snippet
// 				}
// 			}
// 		}
// 		ast.Enum {
// 			for val in type_info.vals {
// 				// Use short enum syntax when reassigning, within
// 				// struct fields, and etc.
// 				label := if fields_only { '.$val' } else { '${name}.$val' }
// 				completion_items << lsp.CompletionItem{
// 					label: label
// 					kind: .enum_member
// 					insert_text: label
// 				}
// 			}
// 		}
// 		ast.Alias, ast.SumType, ast.FnType, ast.Interface {
// 			completion_items << lsp.CompletionItem{
// 				label: name
// 				kind: .type_parameter
// 				insert_text: name
// 			}
// 		}
// 		else {}
// 	}
// 	return completion_items
// }

// // completion_items_from_dir returns the list of import-able folders for autocompletion.
// fn (cfg CompletionItemConfig) completion_items_from_dir(dir string, dir_contents []string, prefix string) []lsp.CompletionItem {
// 	mut completion_items := []lsp.CompletionItem{}
// 	for name in dir_contents {
// 		full_path := os.join_path(dir, name)
// 		if !os.is_dir(full_path) || name in cfg.imports_list || name.starts_with('.') {
// 			continue
// 		}
// 		subdir_contents := os.ls(full_path) or { []string{} }
// 		mod_name := if prefix.len > 0 { '${prefix}.$name' } else { name }
// 		if name == 'modules' {
// 			completion_items << cfg.completion_items_from_dir(full_path, subdir_contents,
// 				mod_name)
// 			continue
// 		}
// 		completion_items << lsp.CompletionItem{
// 			label: mod_name
// 			kind: .folder
// 			insert_text: mod_name
// 		}
// 		completion_items << cfg.completion_items_from_dir(full_path, subdir_contents,
// 			mod_name)
// 	}
// 	return completion_items
// }

// fn (mut cfg CompletionItemConfig) suggest_mod_names() []lsp.CompletionItem {
// 	mut completion_items := []lsp.CompletionItem{}
// 	// Explicitly disabling the global and local completion
// 	// should never happen but just to make sure.
// 	cfg.show_global = false
// 	cfg.show_local = false
// 	folder_name := os.base(os.dir(cfg.file.path)).replace(' ', '_')
// 	module_name_suggestions := ['module main', 'module $folder_name']
// 	for sg in module_name_suggestions {
// 		completion_items << lsp.CompletionItem{
// 			label: sg
// 			insert_text: sg
// 			kind: .variable
// 		}
// 	}
// 	return completion_items
// }

fn symbol_to_completion_item(sym &analyzer.Symbol, prefix string) ?lsp.CompletionItem {
	mut kind := lsp.CompletionItemKind.text
	match sym.kind {
		.variable { 
			kind = .variable 
		}
		.function {
			// if function has parent, use method
			if !sym.parent.is_void() {
				kind = .method
			} else {
				kind = .function 
			}
		}
		.struct_ { 
			kind = .struct_ 
		}
		.field {
			match sym.parent.kind {
				.enum_ {
					kind = .enum_member
				}
				.struct_ {
					kind = .property
				}
				else {
					return none
				}
			}
		}
		.interface_ {
			kind = .interface_
		}
		.typedef {
			kind = .type_parameter
		}
		else {
			return none
		}
	}

	name := if prefix.len == 0 { sym.name } else { prefix + '.' + sym.name }
	// TODO:
	return lsp.CompletionItem{
		label: name
		kind: kind
		insert_text: name
		detail: sym.gen_str()
	}
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

	uri := completion_params.text_document.uri
	src := ls.sources[uri].source
	tree := ls.trees[uri]
	root_node := tree.root_node()
	pos := completion_params.position
	file_path := uri.path()
	file_dir := uri.dir_path()
	file_name := os.base(file_path)
	mut offset := compute_offset(src, pos.line, pos.character)

	// The context is used for if and when to trigger autocompletion.
	// See comments `cfg` for reason.
	mut ctx := completion_params.context

	// This is where the items will be pushed and sent to the client.
	mut completion_items := []lsp.CompletionItem{}
	defer { unsafe { completion_items.free() } }

	// The config is used by all methods for determining the results to be sent
	// to the client. See the field comments in CompletionItemConfig for their
	// purposes.
	//
	// Other parsers use line character-based position for determining the AST node.
	// The V parser on the other hand, uses a byte offset (line number is supplied
	// but for certain cases) hence the need to convert the said positions to byte
	// offsets.
	//
	mut cfg := CompletionItemConfig{}

	// There are some instances that the user would invoke the autocompletion
	// through a combination of shortcuts (like Ctrl/Cmd+Space) and the results
	// wouldn't appear even though one of the trigger characters is on the left
	// or near the cursor. In that case, the context data would be modified in
	// order to satisfy those specific cases.
	if ctx.trigger_kind == .invoked && offset - 1 >= 0 && root_node.named_child_count() > 0 && src.len > 3 {
		mut prev_idx := offset
		mut ctx_changed := false
		if src[offset - 1] in [`.`, `:`, `=`, `{`, `,`, `(`] {
			prev_idx--
			ctx_changed = true
		} else if src[offset - 1] == ` ` && offset - 2 >= 0 && src[offset - 2] !in [src[offset - 1], `.`] {
			prev_idx -= 2
			offset -= 2
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
		// The offset is adjusted and the suggestions for local and global symbols are
		// disabled if a period/dot is detected and the character on the left is not a space.
		if ctx.trigger_character == '.' && (offset - 1 >= 0 && src[offset - 1] != ` `) {
			cfg.show_global = false
			cfg.show_local = false

			offset--
			if src[offset - 1] !in [`)`, `]`] {
				offset--
			}
		}

		for src[offset] == ` ` {
			offset--
		}

		// Once the offset has been finalized it will then search for the AST node and
		// extract it's data using the corresponding methods depending on the node type.
		mut node := root_node.descendant_for_byte_range(u32(offset), u32(offset))
		match node.get_type() {
			'=' {
				node = node.prev_named_sibling()
				if node.get_type() == 'expression_list' {
					node = node.named_child(node.named_child_count() - 1)
				}
			}
			else {
				for !node.is_named() {
					node = node.parent()
				}
			}
		}
		
		// return_type_sym := ls.store.infer_symbol_from_node(node, src) or { analyzer.void_type }
		// for child_sym in return_type_sym.children {
		// 	completion_items << symbol_to_completion_item(child_sym, '') or {
		// 		continue
		// 	}
		// }

	// } else if ctx.trigger_kind == .invoked && (file.stmts.len == 0 || src.len <= 3) {
		// When a V file is empty, a list of `module $name` suggsestions will be displayed.
		// completion_items << cfg.suggest_mod_names()
	} else {
		// Display only the project's functions if none are satisfied
		cfg.show_only_global_fn = true
	}

	// Local results. Module names and the scope-based symbols.
	if cfg.show_local {
		// Imported modules. They will be shown to the user if there is no given
		// type for filtering the results. Invalid imports are excluded.
		for imp in ls.store.imports[file_dir] {
			if file_path in imp.ranges && (file_name !in imp.symbols || imp.symbols[file_name].len == 0) {
				imp_name := if file_name in imp.aliases { imp.aliases[file_name] } else { imp.module_name }
				completion_items << lsp.CompletionItem{
					label: imp_name
					kind: .module_
					insert_text: imp_name
				}
			}
		}

		// Scope-based symbols that includes the variables inside
		// the functions and the constants of the file.
		if file_scope := ls.store.opened_scopes[file_path] {
			inner_scope := file_scope.innermost(u32(offset), u32(offset))

			// constants
			for scope_sym in file_scope.get_all_symbols() {
				// 	ast.ConstField, ast.Var {
					// 		if cfg.filter_type != ast.Type(0) && obj.typ != cfg.filter_type {
					// 			continue
					// 		}
				completion_items << lsp.CompletionItem{
					label: scope_sym.name
					kind: .constant
					insert_text: scope_sym.name
				}
			}

			// variable
			for scope_sym in inner_scope.get_all_symbols() {
				completion_items << lsp.CompletionItem{
					label: scope_sym.name
					kind: .variable
					insert_text: scope_sym.name
				}
			}
		}
	}
	// Global results. This includes all the symbols within the module such as
	// the structs, typedefs, enums, and the functions.
	if cfg.show_global {
		local_syms := ls.store.get_symbols_by_file_path(file_path)
		for local_sym in local_syms {
			if local_sym.is_void() || local_sym.kind in [.placeholder, .variable] {
				continue
			}
			if local_sym.kind == .function && local_sym.name == 'main' {
				continue
			}
			completion_items << symbol_to_completion_item(local_sym, '') or {
				continue
			}
		}

		for imp in ls.store.imports[file_dir] {
			if file_name in imp.symbols && imp.symbols[file_name].len != 0 {
				for imp_sym_name in imp.symbols[file_path] {
					imp_sym := ls.store.symbols[imp.path].get(imp_sym_name) or {
						continue
					}

					if int(imp_sym.access) > int(analyzer.SymbolAccess.private_mutable) {
						completion_items << symbol_to_completion_item(imp_sym, '') or {
							continue
						}
					}
				}
			} else {
				// TODO:
				continue
			}
		}
	}

	// After that, it will send the list to the client.
	ls.send(jsonrpc.Response<[]lsp.CompletionItem>{
		id: id
		result: completion_items
	})
}

fn (mut ls Vls) hover(id int, params string) {
	hover_params := json.decode(lsp.HoverParams, params) or {
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}

	uri := hover_params.text_document.uri
	pos := hover_params.position

	tree := ls.trees[uri]
	source := ls.sources[uri].source
	offset := compute_offset(source, pos.line, pos.character)
	mut node := traverse_node(tree.root_node(), u32(offset))
	mut original_range := node.range()
	node_type := node.get_type()

	if node.is_null() {
		ls.send_null(id)
		return
	}

	if node_type == 'module_clause' {
		ls.send(jsonrpc.Response<lsp.Hover>{
			id: id
			result: lsp.Hover {
				contents: lsp.v_marked_string(node.get_text(source))
				range: tsrange_to_lsp_range(node.range())
			}	
		})
		return
	} else if node_type == 'import_path' {
		found_imp := ls.store.find_import_by_position(node.range()) or {
			ls.send_null(id)
			return
		}

		ls.send(jsonrpc.Response<lsp.Hover>{
			id: id
			result: lsp.Hover {
				contents: lsp.v_marked_string('import ${found_imp.module_name} as ' + found_imp.aliases[uri.path()] or { found_imp.module_name })
				range: tsrange_to_lsp_range(found_imp.ranges[uri.path()])
			}	
		})
		return
	} else if node.parent().is_error() || node.parent().is_missing() {
		ls.send_null(id)
		return
	}

	if node_type != 'type_selector_expression' && node.named_child_count() != 0 {
		original_range = node.first_named_child_for_byte(u32(offset)).range()
	}

	sym := ls.store.infer_symbol_from_node(node, source) or {
		eprintln(err)
		analyzer.void_type
	}

	if isnil(sym) || sym.is_void() {
		ls.send_null(id)
		return
	}

	// Send null if range has zero-start and end points
	if sym.range.start_point.row == 0 && sym.range.start_point.column == 0 && sym.range.start_point.eq(sym.range.end_point) {
		ls.send_null(id)
		return
	}

	ls.send(jsonrpc.Response<lsp.Hover>{
		id: id
		result: lsp.Hover {
			contents: lsp.v_marked_string(sym.gen_str())
			range: tsrange_to_lsp_range(original_range)
		}	
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
	tree := ls.trees[uri]

	root_node := tree.root_node()

	// get the number of named child nodes
	// named child nodes examples: struct_declaration, enum_declaration, etc.
	named_children_len := root_node.named_child_count()

	mut folding_ranges := []lsp.FoldingRange{}

	// loop
	for i := u32(0); i < named_children_len; i++ {
		named_child := root_node.named_child(i)
		folding_ranges << lsp.FoldingRange{
			start_line: tsrange_to_lsp_range(named_child.range()).start.character
			start_character: tsrange_to_lsp_range(named_child.range()).start.line
			end_line: tsrange_to_lsp_range(named_child.range()).end.line
			end_character: tsrange_to_lsp_range(named_child.range()).end.character
			kind: 'region'
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

fn (mut ls Vls) definition(id int, params string) {
	goto_definition_params := json.decode(lsp.TextDocumentPositionParams, params) or {
		ls.panic(err.msg)
		ls.send_null(id)
		return
	}

	if Feature.definition !in ls.enabled_features {
		ls.send_null(id)
		return
	}

	uri := goto_definition_params.text_document.uri
	pos := goto_definition_params.position
	source := ls.sources[uri].source
	tree := ls.trees[uri]
	offset := compute_offset(source, pos.line, pos.character)
	mut node := traverse_node(tree.root_node(), u32(offset))
	mut original_range := node.range()
	node_type := node.get_type()

	if node.is_null() || (node.parent().is_error() || node.parent().is_missing()) {
		ls.send_null(id)
		return
	}

	sym := ls.store.infer_symbol_from_node(node, source) or { analyzer.void_type }
	if isnil(sym) || sym.is_void() {
		ls.send_null(id)
		return
	}

	if node_type != 'type_selector_expression' && node.named_child_count() != 0 {
		original_range = node.first_named_child_for_byte(u32(offset)).range()
	}

	// Send null if range has zero-start and end points
	if sym.range.start_point.row == 0 && sym.range.start_point.column == 0 && sym.range.start_point.eq(sym.range.end_point) {
		ls.send_null(id)
		return
	}

	loc_uri := lsp.document_uri_from_path(sym.file_path)
	ls.send(jsonrpc.Response<lsp.LocationLink>{
		id: id
		result: lsp.LocationLink{
			target_uri: loc_uri
			target_range: tsrange_to_lsp_range(sym.range)
			target_selection_range: tsrange_to_lsp_range(sym.range)
			origin_selection_range: tsrange_to_lsp_range(original_range)
		}
	})
}
