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

// formatting returns the formatted output of the specified file.
fn (ls Vls) formatting(id int, params string) {
	formatting_params := json.decode(lsp.DocumentFormattingParams, params) or { panic(err) }
	uri := formatting_params.text_document.uri.str()
	path := formatting_params.text_document.uri.path()
	source := ls.sources[uri].bytestr()
	mut prefs := pref.new_preferences()
	prefs.output_mode = .silent
	prefs.is_fmt = true
	table := table.new_table()
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

// workspace_symbol returns the list of symbols available in the specific workspace.
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

// document_symbol returns the list of symbols in the specific file.
fn (mut ls Vls) document_symbol(id int, params string) {
	document_symbol_params := json.decode(lsp.DocumentSymbolParams, params) or { panic(err) }
	uri := document_symbol_params.text_document.uri
	file := ls.files[uri.str()]
	symbols := ls.generate_symbols(file, uri)
	ls.send(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: id
		result: symbols
	})
}

// generate_symbols generates and returns an array of symbols from the given ast.File.
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
						name: field.name.all_after(file.mod.name + '.')
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

struct CompletionItemConfig {
mut:
	file                ast.File
	offset              int // position of the cursor. used for finding the AST node
	table               &table.Table
	show_global         bool = true // for displaying global (project) symbols
	show_only_global_fn bool       // for displaying only the functions of the project
	show_local          bool       = true // for displaying local variables
	filter_type         table.Type = table.Type(0) // filters results by type
	fields_only         bool       // for displaying only the struct/enum fields
	modules_aliases     []string   // for displaying module symbols or module list
	imports_list        []string   // for completion_items_from_dir and import symbols list
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
			dir := os.dir(cfg.file.path)
			dir_contents := os.ls(dir) or { []string{} }
			// list all folders
			completion_items << cfg.completion_items_from_dir(dir, dir_contents, '')
			// list all vlib
			// TODO: vlib must be computed at once only
		}
		ast.Module {
			completion_items << cfg.suggest_mod_names()
		}
		else {}
	}
	return completion_items
}

// completion_items_from_table returns a list of results extracted from the type symbols of the table.
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
		valid_type := idx >= 0 || idx < cfg.table.types.len
		sym_part_of_module := mod_name.len > 0 && sym_name.starts_with('${mod_name}.')
		name := sym_name.all_after('${mod_name}.')
		if valid_type || sym_part_of_module || (symbols.len > 0 && name in symbols) {
			type_sym := unsafe { &cfg.table.types[idx] }
			if type_sym.mod != mod_name {
				continue
			}
			completion_items << cfg.completion_items_from_type_info(name, type_sym.info,
				false)
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
			} else if expr.expr_type != 0 {
				type_sym := cfg.table.get_type_symbol(expr.expr_type)

				// Include the list of available struct fields based on the type info
				completion_items << cfg.completion_items_from_type_info('', type_sym.info,
					true)

				// If the expr_type is an array or map type, it should
				// include the fields and methods of map/array type.
				if type_sym.kind == .array || type_sym.kind == .map {
					base_symbol_name := if type_sym.kind == .array { 'array' } else { 'map' }
					if base_type_sym := cfg.table.find_type(base_symbol_name) {
						completion_items << cfg.completion_items_from_type_info('', base_type_sym.info,
							true)
					}
				}
				// Include all the type methods
				for m in type_sym.methods {
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
				ast.Node{}
			}
			if field_node is ast.StructInitField {
				// NB: enable local results only if the node is a field
				cfg.show_local = true
				field_type_sym := cfg.table.get_type_symbol(field_node.expected_type)
				completion_items << cfg.completion_items_from_type_info('', field_type_sym.info,
					field_type_sym.info is table.Enum)
				cfg.filter_type = field_node.expected_type
			} else {
				// if structinit is empty or not within the field position,
				// it must include the list of missing fields instead
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

// completion_items_from_fn returns the list of items extracted from the table.Fn information
fn (mut _ CompletionItemConfig) completion_items_from_fn(fnn table.Fn, is_method bool) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}

	fn_name := fnn.name.all_after(fnn.mod + '.')
	if fn_name == 'main' {
		return completion_items
	}
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
		insert_text += ' or { panic(err) }'
	}
	completion_items << lsp.CompletionItem{
		label: fn_name
		kind: kind
		insert_text_format: .snippet
		insert_text: insert_text
	}
	return completion_items
}

// completion_items_from_type_info returns the list of items extracted from the type information.
fn (mut _ CompletionItemConfig) completion_items_from_type_info(name string, type_info table.TypeInfo, fields_only bool) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	match type_info {
		table.Struct {
			if fields_only {
				for field in type_info.fields {
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
					if field.has_default_expr {
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
		table.Enum {
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

// suggest_mod_names returns a list of suggestions for module statement.
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

// completion generates and returns a list of symbol suggestions
// from the given position/scope of a specific file.
// 
// TODO: make params use lsp.CompletionParams in the future
fn (mut ls Vls) completion(id int, params string) {
	if Feature.completion !in ls.enabled_features {
		return
	}
	completion_params := json.decode(lsp.CompletionParams, params) or { panic(err) }
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
		table: ls.tables[os.dir(file_uri)]
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

		// Once the offset has been finalized it will then search for the AST node and
		// extract it's data using the corresponding methods depending on the node type.
		node := find_ast_by_pos(file.stmts.map(ast.Node(it)), cfg.offset) or { ast.Node{} }
		match node {
			ast.Stmt {
				completion_items << cfg.completion_items_from_stmt(node)
			}
			ast.Expr {
				completion_items << cfg.completion_items_from_expr(node)
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
			if imp.syms.len == 0 && (cfg.filter_type == table.Type(0)
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
						if cfg.filter_type != table.Type(0) && obj.typ != cfg.filter_type {
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
