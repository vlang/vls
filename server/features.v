module server

import lsp
import os
import analyzer
import strings
import math
import ast
import tree_sitter

const temp_formatting_file_path = os.join_path(os.temp_dir(), 'vls_temp_formatting.v')

[manualfree]
pub fn (mut ls Vls) formatting(params lsp.DocumentFormattingParams, mut wr ResponseWriter) ?[]lsp.TextEdit {
	uri := params.text_document.uri
	source := ls.files[uri].source
	tree_range := ls.files[uri].tree.root_node().range()
	if source.len() == 0 {
		return none
	}

	// We don't integrate v.fmt and it's dependencies anymore to lessen
	// cleanups everytime launching an instance.
	//
	// To simplify this, we will make a temporary file and feed it into
	// the v fmt CLI program since there is no cross-platform way to pipe
	// raw strings directly into v fmt.
	mut temp_file := os.open_file(server.temp_formatting_file_path, 'w') ?
	temp_file.write_string(source.string()) ?
	temp_file.close()
	defer {
		os.rm(server.temp_formatting_file_path) or {}
	}

	mut p := ls.launch_v_tool('fmt', server.temp_formatting_file_path)
	defer {
		p.close()
	}
	p.wait()

	if p.code > 0 {
		errors := p.stderr_slurp().trim_space()
		wr.show_message(errors, .info)
		return none
	}

	mut output := p.stdout_slurp()
	$if windows {
		output = output.replace('\r\r', '\r')
	}

	return [
		lsp.TextEdit{
			range: tsrange_to_lsp_range(tree_range)
			new_text: output
		},
	]
}

pub fn (mut ls Vls) workspace_symbol(params lsp.WorkspaceSymbolParams, mut wr ResponseWriter) []lsp.SymbolInformation {
	mut workspace_symbols := []lsp.SymbolInformation{}

	for _, sym_arr in ls.store.symbols {
		for sym in sym_arr {
			uri := lsp.document_uri_from_path(sym.file_path)
			if uri in ls.files || uri.dir() == ls.root_uri {
				sym_info := symbol_to_symbol_info(uri, sym) or { continue }
				workspace_symbols << sym_info
				for child_sym in sym.children_syms {
					child_sym_info := symbol_to_symbol_info(uri, child_sym) or { continue }
					workspace_symbols << child_sym_info
				}
			} else {
				// unsafe { uri.free() }
			}
		}
	}

	return workspace_symbols
}

fn symbol_to_symbol_info(uri lsp.DocumentUri, sym &analyzer.Symbol) ?lsp.SymbolInformation {
	if !sym.is_top_level {
		return none
	}
	$if !test ? {
		if uri.ends_with('.vv') && sym.kind != .function {
			return none
		}
	}
	mut kind := lsp.SymbolKind.null
	match sym.kind {
		.function {
			kind = if sym.kind == .function && !sym.parent_sym.is_void() {
				lsp.SymbolKind.method
			} else {
				lsp.SymbolKind.function
			}
		}
		.struct_ {
			kind = .struct_
		}
		.enum_ {
			kind = .enum_
		}
		.typedef {
			kind = .type_parameter
		}
		.interface_ {
			kind = .interface_
		}
		.variable {
			kind = .constant
		}
		else {
			return none
		}
	}
	prefix := if sym.kind == .function && !sym.parent_sym.is_void() {
		sym.parent_sym.name + '.'
	} else {
		''
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

fn (mut ls Vls) document_symbol(params lsp.DocumentSymbolParams, mut wr ResponseWriter) ?[]lsp.SymbolInformation {
	uri := params.text_document.uri
	retrieved_symbols := ls.store.get_symbols_by_file_path(uri.path())
	mut document_symbols := []lsp.SymbolInformation{}
	for sym in retrieved_symbols {
		sym_info := symbol_to_symbol_info(uri, sym) or { continue }
		document_symbols << sym_info
	}
	return document_symbols
}

fn (mut ls Vls) signature_help(params lsp.SignatureHelpParams, mut wr ResponseWriter) ?lsp.SignatureHelp {
	if Feature.signature_help !in ls.enabled_features {
		return none
	}

	uri := params.text_document.uri
	pos := params.position
	ctx := params.context
	file := ls.files[uri] or { return none }
	off := file.get_offset(pos.line, pos.character)
	mut node := traverse_node(file.tree.root_node(), u32(off))
	mut parent_node := node
	if node.type_name == .argument_list {
		parent_node = node.parent() or { node }
		node = node.prev_named_sibling() or { node }
	} else if parent_node.type_name != .call_expression {
		parent_node = closest_symbol_node_parent(node)
		node = parent_node
	}

	// signature help supports function calls for now
	// hence checking the node if it's a call_expression node.
	if parent_node.type_name != .call_expression {
		return none
	}

	ls.store.set_active_file_path(uri.path(), file.version)
	sym := ls.store.infer_symbol_from_node(node, file.source) or {
		return none
	}

	args_node := parent_node.child_by_field_name('arguments') or {
		return none
	}

	// get the nearest parameter based on the position of the cursor
	args_count := args_node.named_child_count()
	mut active_parameter_idx := -1
	for i in u32(0) .. args_count {
		current_arg_node := args_node.named_child(i) or { continue }
		if u32(off) >= current_arg_node.start_byte() && u32(off) <= current_arg_node.end_byte() {
			active_parameter_idx = int(i)
			break
		}
	}

	// go to the first parameter or the last parameter if not found
	if args_count == 0 {
		active_parameter_idx = 0
	} else if active_parameter_idx == -1 {
		active_parameter_idx = int(args_count) - 1
	}

	// for retrigger, it utilizes the current signature help data
	if ctx.is_retrigger {
		mut active_sighelp := ctx.active_signature_help
		active_sighelp.active_parameter = active_parameter_idx
		return active_sighelp
	}

	// create a signature help info based on the
	// call expr info
	mut param_infos := []lsp.ParameterInformation{}
	for child_sym in sym.children_syms {
		if child_sym.kind != .variable {
			continue
		}

		param_infos << lsp.ParameterInformation{
			label: child_sym.gen_str()
		}
	}

	return lsp.SignatureHelp{
		active_parameter: active_parameter_idx
		signatures: [
			lsp.SignatureInformation{
				label: sym.gen_str()
				// documentation: lsp.MarkupContent{}
				parameters: param_infos
			},
		]
	}
}

struct CompletionBuilder {
mut:
	store              &analyzer.Store
	src                tree_sitter.SourceText
	offset             int
	parent_node        ast.Node
	show_global        bool // for displaying global (project) symbols
	show_local         bool // for displaying local variables
	filter_return_type &analyzer.Symbol = &analyzer.Symbol(0) // filters results by type
	filter_sym_kinds   []analyzer.SymbolKind
	fields_only        bool             // for displaying only the struct/enum fields
	show_mut_only      bool // filters results based on the object's mutability state.
	ctx                lsp.CompletionContext
	completion_items   []lsp.CompletionItem = []lsp.CompletionItem{cap: 100}
}

fn (mut builder CompletionBuilder) add(item lsp.CompletionItem) {
	builder.completion_items << item
}

fn (builder CompletionBuilder) is_triggered(node ast.Node, chr string) bool {
	return node.next_sibling() or { return false }.text(builder.src) == chr
		|| builder.ctx.trigger_character == chr
}

fn (builder CompletionBuilder) is_selector(node ast.Node) bool {
	return builder.is_triggered(node, '.')
}

fn (builder CompletionBuilder) has_same_return_type(sym &analyzer.Symbol) bool {
	if sym.is_void() || isnil(builder.filter_return_type) {
		return true
	}
	return sym == builder.filter_return_type
}

fn (mut builder CompletionBuilder) build_suggestions(node ast.Node, offset int) {
	builder.offset = offset
	builder.build_suggestions_from_node(node)
	if builder.show_local {
		builder.build_local_suggestions()
	}
	if builder.show_global {
		builder.build_global_suggestions()
	}
}

fn (mut builder CompletionBuilder) build_suggestions_from_node(node ast.Node) {
	node_type_name := node.type_name
	if node_type_name in list_node_types {
		builder.build_suggestions_from_list(node)
	} else if node_type_name == .module_clause {
		builder.build_module_name_suggestions()
	} else {
		builder.build_suggestions_from_stmt(node)
	}
}

// suggestions_from_stmt returns a list of results from the extracted Stmt node info.
fn (mut builder CompletionBuilder) build_suggestions_from_stmt(node ast.Node) {
	match node.type_name {
		.short_var_declaration {
			builder.show_local = true
			builder.show_global = true
		}
		.assignment_statement {
			right_node := node.child_by_field_name('right') or { return }
			left_node := node.child_by_field_name('left') or { return }
			expr_list_count := right_node.named_child_count()
			left_count := left_node.named_child_count()
			if expr_list_count == left_count {
				last_left_node := left_node.named_child(left_count - 1) or { return }
				builder.filter_return_type = builder.store.infer_value_type_from_node(last_left_node,
					builder.src)
				builder.show_local = true
			}
		}
		else {
			builder.build_suggestions_from_expr(node)
		}
	}
}

// suggestions_from_list returns a list of results extracted from the list nodes.
fn (mut builder CompletionBuilder) build_suggestions_from_list(node ast.Node) {
	match node.type_name {
		.identifier_list {
			parent := closest_symbol_node_parent(node)
			builder.build_suggestions_from_node(parent)
		}
		.expression_list {
			// expr_list_count := node.named_child_count()
			parent := closest_symbol_node_parent(node)
			match parent.type_name {
				.assignment_statement {
					builder.build_suggestions_from_stmt(parent)
				}
				else {
					// closest_node := closest_named_child(node, u32(builder.offset))
					// eprintln(closest_node.type_name())
				}
			}
		}
		.argument_list {
			call_expr_arg_cur_idx := node.named_child_count()
			parent := node.parent() or { return }
			returned_sym := builder.store.infer_symbol_from_node(parent, builder.src) or {
				builder.filter_return_type
			}

			if isnil(returned_sym) {
				return
			}

			if call_expr_arg_cur_idx < u32(returned_sym.children_syms.len) {
				builder.filter_return_type = returned_sym.children_syms[int(call_expr_arg_cur_idx)].return_sym
				builder.show_local = true
				builder.show_global = true
			}
		}
		.import_symbols_list {
			import_node := closest_symbol_node_parent(node)
			import_path_node := import_node.child_by_field_name('path') or { return }
			import_path := import_path_node.text(builder.src)
			builder.build_suggestions_from_module(import_path)
		}
		.type_list {
			builder.show_local = false
			builder.show_global = true
			builder.filter_sym_kinds = [
				analyzer.SymbolKind.typedef,
				.struct_,
				.enum_,
				.interface_,
				.sumtype,
				.function_type,
			]
		}
		else {}
	}
}

// suggestions_from_expr returns a list of results extracted from the Expr node info.
fn (mut builder CompletionBuilder) build_suggestions_from_expr(node ast.Node) {
	node_type_name := node.type_name
	match node_type_name {
		.binded_identifier, .identifier, .selector_expression, .call_expression,
		.index_expression {
			builder.show_global = false
			builder.show_local = false

			text := node.text(builder.src)

			if builder.is_selector(node) {
				mut selected_node := node
				if node_type_name == .selector_expression {
					if operand_node := node.child_by_field_name('operand') {
						if operand_node.type_name == .call_expression {
							selected_node = node
						}
					}
				}
				if got_sym := builder.store.infer_symbol_from_node(selected_node, builder.src) {
					builder.show_mut_only = builder.parent_node.type_name == .block
						&& got_sym.is_mutable()
					builder.build_suggestions_from_sym(got_sym.return_sym, true)
				} else if builder.store.is_module(text) {
					builder.build_suggestions_from_module(text)
				} else if text == 'C.' || text == 'JS.' {
					lang := match text {
						'C.' { analyzer.SymbolLanguage.c }
						'JS.' { analyzer.SymbolLanguage.js }
						else { analyzer.SymbolLanguage.v }
					}

					if lang == .v {
						return
					}

					builder.build_suggestions_from_binded_symbols(lang, builder.ctx.trigger_character == '.')
				}
			}
		}
		.literal_value {
			closest_element_node := closest_named_child(node, u32(builder.offset))
			if closest_element_node.type_name == .keyed_element {
				builder.build_suggestions_from_expr(closest_element_node)
			} else if parent_node := node.parent() {
				if got_sym := builder.store.infer_symbol_from_node(parent_node, builder.src) {
					builder.build_suggestions_from_sym(got_sym, false)
				}
			}
		}
		.keyed_element {
			if got_sym := builder.store.infer_symbol_from_node(node, builder.src) {
				builder.show_local = true
				builder.filter_return_type = got_sym.return_sym

				if got_sym.return_sym.kind != .struct_ {
					builder.build_suggestions_from_sym(got_sym.return_sym, false)
				}
			}
		}
		.import_symbols {
			builder.build_suggestions_from_node(node.named_child(0) or { return })
		}
		else {
			// found_sym := builder.store.infer_symbol_from_node(node, builder.src) or { analyzer.void_sym }
			// builder.filter_return_type = if found_sym.is_returnable() { found_sym.return_sym } else { found_sym }
		}
	}
}

fn (mut builder CompletionBuilder) build_suggestions_from_sym(sym &analyzer.Symbol, is_selector bool) {
	if isnil(sym) || sym.is_void() {
		return
	}

	for child_sym in sym.children_syms {
		if is_selector {
			if (sym.kind in [.enum_, .struct_] || sym.kind in analyzer.container_symbol_kinds)
				&& child_sym.kind !in [.field, .function, .embedded_field] {
				continue
			} else if !child_sym.file_path.starts_with(builder.store.cur_dir)
				&& int(child_sym.access) < int(analyzer.SymbolAccess.public) {
				continue
			}

			if child_sym.kind != .function && builder.show_mut_only && !child_sym.is_mutable() {
				continue
			} else if child_sym.kind == .function && !builder.show_mut_only
				&& child_sym.is_mutable() {
				continue
			}

			if child_sym.kind == .embedded_field {
				builder.build_suggestions_from_sym(child_sym.return_sym, is_selector)
			}

			if existing_completion_item := symbol_to_completion_item(child_sym, true) {
				builder.add(existing_completion_item)
			}
		} else if child_sym.kind == .field && sym.kind == .struct_ {
			builder.add(lsp.CompletionItem{
				label: '$child_sym.name:'
				kind: .field
				insert_text: '$child_sym.name: \$0'
				insert_text_format: .snippet
				detail: child_sym.gen_str()
			})
		} else if child_sym.kind == .field && sym.kind == .enum_ {
			builder.add(symbol_to_completion_item(child_sym, true) or { continue })
		}
	}

	if sym.kind in analyzer.container_symbol_kinds {
		for base_sym_loc in builder.store.base_symbol_locations {
			if base_sym_loc.for_kind == sym.kind {
				base_sym := builder.store.find_symbol(base_sym_loc.module_name, base_sym_loc.symbol_name) or {
					continue
				}
				builder.build_suggestions_from_sym(base_sym, is_selector)
			}
		}
	}
}

fn (mut builder CompletionBuilder) build_suggestions_from_binded_symbols(lang analyzer.SymbolLanguage, with_snippet bool) {
	// just a cache in order to avoid repeated lookups
	// done by is_imported
	mut imported_paths := []string{cap: 10}

	// this is for slicing the string
	lang_len := match lang {
		.v, .c { 2 }
		.js { 3 }
	}

	for sym_loc_entry in builder.store.binded_symbol_locations {
		$if test {
			if sym_loc_entry.module_path == builder.store.auto_imports[''] {
				continue
			}
		}

		if sym_loc_entry.language != lang {
			continue
		}

		module_path := sym_loc_entry.module_path
		if module_path !in imported_paths {
			if module_path != builder.store.cur_dir && !builder.store.is_imported(module_path) {
				continue
			}

			imported_paths << module_path
		}

		sym_name := sym_loc_entry.for_sym_name
		sym := builder.store.symbols[module_path].get(sym_name) or { continue }

		if existing_completion_item := symbol_to_completion_item(sym, with_snippet) {
			builder.add(lsp.CompletionItem{
				...existing_completion_item
				insert_text: existing_completion_item.insert_text[lang_len..]
			})
		}
	}
}

fn (mut builder CompletionBuilder) build_suggestions_from_module(name string, included_list ...string) {
	imported_path_dir := builder.store.get_module_path_opt(name) or {
		builder.store.auto_imports[name] or { return }
	}

	imported_syms := builder.store.symbols[imported_path_dir]
	for imp_sym in imported_syms {
		if (included_list.len != 0 && imp_sym.name in included_list)
			|| !builder.has_same_return_type(imp_sym.return_sym)
			|| (builder.filter_sym_kinds.len != 0 && imp_sym.kind !in builder.filter_sym_kinds) {
			continue
		}
		if int(imp_sym.access) >= int(analyzer.SymbolAccess.public) {
			builder.add(symbol_to_completion_item(imp_sym, builder.ctx.trigger_character == '.') or {
				continue
			})
		}
	}
}

fn (mut builder CompletionBuilder) build_module_name_suggestions() {
	// Explicitly disabling the global and local completion
	// should never happen but just to make sure.
	builder.show_global = false
	builder.show_local = false

	folder_name := os.base(builder.store.cur_dir).replace(' ', '_')
	module_name_suggestions := ['main', folder_name]
	for module_name in module_name_suggestions {
		builder.add(lsp.CompletionItem{
			label: 'module ' + module_name
			insert_text: 'module ' + module_name
			kind: .variable
		})
	}
}

// Local results. Module names and the scope-based symbols.
fn (mut builder CompletionBuilder) build_local_suggestions() {
	file_name := builder.store.cur_file_name
	// Imported modules. They will be shown to the user if there is no given
	// type for filtering the results. Invalid imports are excluded.
	if isnil(builder.filter_return_type) {
		for imp in builder.store.imports[builder.store.cur_dir] {
			if builder.store.cur_file_path in imp.ranges
				&& (file_name !in imp.symbols || imp.symbols[file_name].len == 0) {
				imp_name := imp.aliases[file_name] or { imp.module_name }
				builder.add(lsp.CompletionItem{
					label: imp_name
					kind: .module_
					insert_text: imp_name
				})
			}
		}

		if builder.store.binded_symbol_locations.len != 0 {
			// add JS in the future
			builder.add(lsp.CompletionItem{
				label: 'C'
				kind: .module_
				detail: 'C symbol definitions'
				insert_text: 'C.'
			})
		}
	}

	// Scope-based symbols that includes the variables inside
	// the functions and the constants of the file.
	if file_scope_ := builder.store.opened_scopes[builder.store.cur_file_path] {
		mut file_scope := unsafe { file_scope_ }
		mut scope := file_scope.innermost(u32(builder.offset), u32(builder.offset))
		for !isnil(scope) && scope != file_scope {
			// constants
			for scope_sym in scope.get_all_symbols() {
				if !builder.has_same_return_type(scope_sym.return_sym)
					|| (builder.filter_sym_kinds.len != 0
					&& scope_sym.kind !in builder.filter_sym_kinds) {
					continue
				}

				builder.add(lsp.CompletionItem{
					label: scope_sym.name
					kind: .variable
					detail: scope_sym.gen_str()
					insert_text: scope_sym.name
				})
			}

			scope = scope.parent
		}
	}
}

// Global results. This includes all the symbols within the module such as
// the structs, typedefs, enums, and the functions.
fn (mut builder CompletionBuilder) build_global_suggestions() {
	global_syms := builder.store.symbols[builder.store.cur_dir]
	for sym in global_syms {
		if !sym.is_void() && sym.kind != .placeholder {
			if (sym.kind == .function && sym.name == 'main')
				|| !builder.has_same_return_type(sym.return_sym)
				|| (builder.filter_sym_kinds.len != 0 && sym.kind !in builder.filter_sym_kinds) {
				continue
			}

			// is_type_decl := false
			is_type_decl := builder.parent_node.type_name == .type_declaration
			builder.add(symbol_to_completion_item(sym, !is_type_decl) or { continue })
		}
	}

	file_name := builder.store.cur_file_name
	for imp in builder.store.imports[builder.store.cur_dir] {
		if builder.store.cur_file_name in imp.symbols && imp.symbols[file_name].len != 0 {
			builder.build_suggestions_from_module(imp.module_name, ...imp.symbols[file_name])
		}
	}

	$if !test {
		// inject builtin symbols
		builder.build_suggestions_from_module('')
	}
}

fn symbol_to_completion_item(sym &analyzer.Symbol, with_snippet bool) ?lsp.CompletionItem {
	mut kind := lsp.CompletionItemKind.text
	mut name := sym.name
	mut insert_text_format := lsp.InsertTextFormat.plain_text
	mut insert_text := strings.new_builder(name.len)
	defer {
		unsafe { insert_text.free() }
	}

	match sym.kind {
		.variable {
			kind = .variable
			insert_text.write_string(name)
		}
		.function {
			// if function has parent, use method
			kind = if !sym.parent_sym.is_void() {
				lsp.CompletionItemKind.method
			} else {
				lsp.CompletionItemKind.function
			}
			insert_text.write_string(name)
			if with_snippet {
				insert_text.write_byte(`(`)
				for i in 0 .. sym.children_syms.len {
					insert_text.write_byte(`$`)
					insert_text.write_string(i.str())
					if i < sym.children_syms.len - 1 {
						insert_text.write_string(', ')
					} else {
						insert_text_format = .snippet
					}
				}
				insert_text.write_byte(`)`)
			}
		}
		.struct_ {
			kind = .struct_
			insert_text.write_string(name)
			if with_snippet {
				insert_text.write_byte(`{`)
				mut insert_count := 1
				for i, child_sym in sym.children_syms {
					if child_sym.kind != .field || child_sym.name.len == 0 {
						continue
					} else if i != 0 && i < sym.children_syms.len {
						insert_text.write_string(', ')
					}
					insert_text.write_string(child_sym.name + ':\$' + insert_count.str())
					insert_text_format = .snippet
					insert_count++
				}
				insert_text.write_byte(`}`)
			}
		}
		.field {
			match sym.parent_sym.kind {
				.enum_ {
					kind = .enum_member
					insert_text.write_byte(`.`)
					insert_text.write_string(sym.name)
					name = insert_text.after(0)
				}
				.struct_ {
					kind = .property
					insert_text.write_string(name)
				}
				else {
					return none
				}
			}
		}
		.interface_ {
			kind = .interface_
			insert_text.write_string(name)
		}
		else {
			return none
		}
	}

	return lsp.CompletionItem{
		label: name
		kind: kind
		detail: sym.gen_str()
		insert_text: insert_text.str()
		insert_text_format: insert_text_format
	}
}

pub fn (mut ls Vls) completion(params lsp.CompletionParams, mut wr ResponseWriter) ?[]lsp.CompletionItem {
	if Feature.completion !in ls.enabled_features {
		return none
	}

	uri := params.text_document.uri
	file := ls.files[uri]
	root_node := file.tree.root_node()
	pos := params.position
	mut offset := file.get_offset(pos.line, pos.character)
	if offset == -1 {
		return none
	}

	ls.store.set_active_file_path(uri.path(), file.version)

	// The context is used for if and when to trigger autocompletion.
	// See comments `cfg` for reason.
	mut ctx := params.context

	// The config is used by all methods for determining the results to be sent
	// to the client. See the field comments in CompletionBuilder for their
	// purposes.
	mut builder := CompletionBuilder{
		store: &ls.store
		src: file.source
		parent_node: root_node
	}

	// There are some instances that the user would invoke the autocompletion
	// through a combination of shortcuts (like Ctrl/Cmd+Space) and the results
	// wouldn't appear even though one of the trigger characters is on the left
	// or near the cursor. In that case, the context data would be modified in
	// order to satisfy those specific cases.
	if ctx.trigger_kind == .invoked && offset - 1 >= 0 && root_node.named_child_count() > 0
		&& file.source.len() > 3 {
		mut prev_idx := offset
		mut ctx_changed := false
		if file.source.at(offset - 1) in [`.`, `:`, `=`, `{`, `,`, `(`] {
			prev_idx--
			ctx_changed = true
		} else if file.source.at(offset - 1) == ` ` && offset - 2 >= 0
			&& file.source.at(offset - 2) !in [file.source.at(offset - 1), `.`] {
			prev_idx -= 2
			offset -= 2
			ctx_changed = true
		}

		if ctx_changed {
			ctx = lsp.CompletionContext{
				trigger_kind: .trigger_character
				trigger_character: file.source.at(prev_idx).str()
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
		if ctx.trigger_character == '.' && (offset - 1 >= 0 && file.source.at(offset - 1) != ` `) {
			builder.show_global = false
			builder.show_local = false

			offset--
			if file.source.at(offset - 1) !in [`)`, `]`] {
				offset--
			}
		}

		for offset > file.source.len() || (offset < file.source.len() && file.source.at(offset) == ` `) {
			offset--
		}

		// Once the offset has been finalized it will then search for the AST node and
		// extract it's data using the corresponding methods depending on the node type.
		mut node := traverse_node2(root_node, u32(offset))
		mut parent_node := traverse_node(root_node, u32(offset))
		node_type_name := node.type_name

		if root_node.is_error() && root_node.type_name == .error {
			// point to the identifier for assignment statement
			node = traverse_node(node, node.start_byte())
		} else if node_type_name == .block {
			node = traverse_node2(root_node, u32(offset))
		} else if node.is_error() && node_type_name == .error {
			node = node.prev_named_sibling() or { node }
		} else if node.start_byte() > u32(offset) {
			node = closest_named_child(closest_symbol_node_parent(node), u32(offset))
		} else if node_type_name == .source_file {
			parent_node = closest_named_child(node, u32(offset))
			node = closest_named_child(parent_node, u32(offset))
		} else if parent_node.start_byte() > node.start_byte() {
			node = parent_node
		}

		builder.ctx = ctx
		builder.parent_node = parent_node
		builder.build_suggestions(node, offset)
	} else if ctx.trigger_kind == .invoked
		&& (root_node.named_child_count() == 0 || file.source.len() <= 3) {
		// When a V file is empty, a list of `module $name` suggsestions will be displayed.
		builder.build_module_name_suggestions()
	} else {
		// Display only the project's functions if none are satisfied
		builder.offset = offset
		builder.build_local_suggestions()

		$if !test {
			builder.build_global_suggestions()
		}
	}

	// After that, it will send the list to the client.
	return builder.completion_items
}

pub fn (mut ls Vls) hover(params lsp.HoverParams, mut wr ResponseWriter) ?lsp.Hover {
	uri := params.text_document.uri
	pos := params.position
	file := ls.files[uri] or { return none }
	offset := file.get_offset(pos.line, pos.character)
	node := traverse_node(file.tree.root_node(), u32(offset))
	ls.store.set_active_file_path(uri.path(), file.version)
	return get_hover_data(mut ls.store, node, uri, file.source, u32(offset))
}

fn get_hover_data(mut store analyzer.Store, node ast.Node, uri lsp.DocumentUri, source tree_sitter.SourceText, offset u32) ?lsp.Hover {
	node_type_name := node.type_name
	if node.is_null() || node_type_name == .comment {
		return none
	}

	mut original_range := node.range()
	parent_node := node.parent() or { node }

	// eprintln('$node_type_name | ${node.text(source)}')
	if node_type_name == .module_clause {
		return lsp.Hover{
			contents: lsp.v_marked_string(node.text(source))
			range: tsrange_to_lsp_range(node.range())
		}
	} else if node_type_name == .import_path {
		found_imp := store.imports.find_by_position(store.cur_file_path, node.range()) ?
		alias := found_imp.aliases[store.cur_file_name] or { '' }
		return lsp.Hover{
			contents: lsp.v_marked_string('import $found_imp.absolute_module_name' +
				if alias.len > 0 { ' as $alias' } else { '' })
			range: tsrange_to_lsp_range(found_imp.ranges[store.cur_file_path])
		}
	} else if parent_node.is_error() || parent_node.is_missing() {
		return none
	}

	if node_type_name != .type_selector_expression && node.named_child_count() != 0 {
		if got_node := node.first_named_child_for_byte(u32(offset)) {
			new_original_range := got_node.range()
			if new_original_range.start_byte != 0 && new_original_range.end_byte != 0 {
				original_range = new_original_range
			}
		}
	}

	mut sym := store.infer_symbol_from_node(node, source) or { analyzer.void_sym }
	if isnil(sym) || sym.is_void() {
		closest_parent := closest_symbol_node_parent(node)
		sym = store.infer_symbol_from_node(closest_parent, source) or { analyzer.void_sym }
	}

	// eprintln('$node_type_name | ${node.text(source)} | $sym')

	// Send null if range has zero-start and end points
	if sym.range.start_point.row == 0 && sym.range.start_point.column == 0
		&& sym.range.start_point.eq(sym.range.end_point) {
		return none
	}

	return lsp.Hover{
		contents: lsp.v_marked_string(sym.gen_str())
		range: tsrange_to_lsp_range(original_range)
	}
}

// [manualfree]
pub fn (mut ls Vls) folding_range(params lsp.FoldingRangeParams, mut wr ResponseWriter) ?[]lsp.FoldingRange {
	uri := params.text_document.uri
	file := ls.files[uri] or { return none }
	root_node := file.tree.root_node()

	mut folding_ranges := []lsp.FoldingRange{}
	mut imports_seen := false
	mut last_single_comment_range := C.TSRange{
		start_point: C.TSPoint{
			row: math.max_u32
		}
		end_point: C.TSPoint{
			// -1 to ensure that a source file that starts with a comment is handled correctly
			row: math.max_u32 - 1
		}
	}

	for node in analyzer.new_tree_walker(root_node) {
		if !node.is_named() {
			continue
		}

		match node.type_name {
			.import_declaration {
				if imports_seen {
					continue
				}

				mut last_import := node
				mut cnode := node.next_named_sibling() or { continue }
				for cnode.type_name in [.import_declaration, .comment] {
					if cnode.type_name == .import_declaration {
						last_import = cnode
					}
					cnode = cnode.next_named_sibling() or { break }
				}

				imports_range := C.TSRange{
					start_point: node.range().start_point
					end_point: last_import.range().end_point
				}

				folding_ranges << create_fold(imports_range, lsp.folding_range_kind_imports)
				imports_seen = true
			}
			.struct_field_declaration_list, .interface_spec_list, .enum_member_declaration_list {
				folding_ranges << create_fold(node.range(), lsp.folding_range_kind_region)
			}
			// 'function_declaration' {
			// 	body_node := node.child_by_field_name('body') or { continue }
			// 	folding_ranges << create_fold(body_node.range(), 'region')
			// }
			.block, .const_declaration {
				range := node.range()
				if range.start_point.row != range.end_point.row {
					folding_ranges << create_fold(range, lsp.folding_range_kind_region)
				}
			}
			.type_initializer {
				body_node := node.child_by_field_name('body') or { continue }
				folding_ranges << create_fold(body_node.range(), lsp.folding_range_kind_region)
			}
			.comment {
				range := node.range()
				if range.start_point.row != range.end_point.row {
					// multi line comment
					folding_ranges << create_fold(range, lsp.folding_range_kind_comment)
				} else {
					// single line comment
					if last_single_comment_range.end_point.row == range.end_point.row - 1
						&& last_single_comment_range.start_point.column == range.start_point.column {
						folding_ranges.pop()
						new_range := C.TSRange{
							start_point: last_single_comment_range.start_point
							end_point: range.end_point
						}
						last_single_comment_range = new_range
					} else {
						last_single_comment_range = range
					}
					folding_ranges << create_fold(last_single_comment_range, lsp.folding_range_kind_comment)
				}
			}
			else {}
		}
	}
	return folding_ranges
}

fn create_fold(tsrange C.TSRange, kind string) lsp.FoldingRange {
	range := tsrange_to_lsp_range(tsrange)
	return lsp.FoldingRange{
		start_line: range.start.line
		start_character: range.start.character
		end_line: range.end.line
		end_character: range.end.character
		kind: kind
	}
}

pub fn (mut ls Vls) definition(params lsp.TextDocumentPositionParams, mut wr ResponseWriter) ?[]lsp.LocationLink {
	if Feature.definition !in ls.enabled_features {
		return none
	}

	uri := params.text_document.uri
	pos := params.position
	file := ls.files[uri] or { return none }
	source := file.source
	offset := compute_offset(source, pos.line, pos.character)
	mut node := traverse_node(file.tree.root_node(), u32(offset))
	mut original_range := node.range()
	node_type_name := node.type_name
	if parent_node := node.parent() {
		if parent_node.is_error() || parent_node.is_missing() {
			return none
		}
	} else if node.is_null() {
		return none
	}

	ls.store.set_active_file_path(uri.path(), file.version)
	sym := ls.store.infer_symbol_from_node(node, source) or { analyzer.void_sym }
	if isnil(sym) || sym.is_void() {
		return none
	}

	if node_type_name != .type_selector_expression && node.named_child_count() != 0 {
		if got_node := node.first_named_child_for_byte(u32(offset)) {
			original_range = got_node.range()
		}
	}

	// Send null if range has zero-start and end points
	if sym.range.start_point.row == 0 && sym.range.start_point.column == 0
		&& sym.range.start_point.eq(sym.range.end_point) {
		return none
	}

	loc_uri := lsp.document_uri_from_path(sym.file_path)
	return [
		lsp.LocationLink{
			target_uri: loc_uri
			target_range: tsrange_to_lsp_range(sym.range)
			target_selection_range: tsrange_to_lsp_range(sym.range)
			origin_selection_range: tsrange_to_lsp_range(original_range)
		},
	]
}

fn get_implementation_locations_from_syms(symbols []&analyzer.Symbol, got_sym &analyzer.Symbol, original_range C.TSRange, mut locations []lsp.LocationLink) {
	for sym in symbols {
		mut interface_sym := unsafe { analyzer.void_sym }
		mut sym_to_check := unsafe { analyzer.void_sym }
		if got_sym.kind == .interface_ && sym.kind != .interface_ {
			interface_sym = got_sym
			sym_to_check = sym
		} else if sym.kind == .interface_ && got_sym.kind != .interface_ {
			interface_sym = sym
			sym_to_check = got_sym
		} else {
			continue
		}

		if analyzer.is_interface_satisfied(sym_to_check, interface_sym) {
			locations << lsp.LocationLink{
				target_uri: lsp.document_uri_from_path(sym.file_path)
				target_range: tsrange_to_lsp_range(sym.range)
				target_selection_range: tsrange_to_lsp_range(sym.range)
				origin_selection_range: tsrange_to_lsp_range(original_range)
			}
		}
	}
}

pub fn (mut ls Vls) implementation(params lsp.TextDocumentPositionParams, mut wr ResponseWriter) ?[]lsp.LocationLink {
	if Feature.definition !in ls.enabled_features {
		return none
	}

	uri := params.text_document.uri
	pos := params.position
	file := ls.files[uri] or { return none }
	source := file.source
	offset := file.get_offset(pos.line, pos.character)
	mut node := traverse_node(file.tree.root_node(), u32(offset))
	mut original_range := node.range()
	node_type_name := node.type_name
	if parent_node := node.parent() {
		if parent_node.is_error() || parent_node.is_missing() {
			return none
		}
	}

	if node.is_null() {
		return none
	}

	ls.store.set_active_file_path(uri.path(), file.version)

	mut got_sym := unsafe { analyzer.void_sym }
	if parent_node := node.parent() {
		if parent_node.type_name == .interface_declaration {
			got_sym = ls.store.symbols[ls.store.cur_dir].get(node.text(source)) or { got_sym }
		} else {
			got_sym = ls.store.infer_value_type_from_node(node, source)
		}
	}

	if isnil(got_sym) || got_sym.is_void() {
		return none
	}

	if node_type_name != .type_selector_expression && node.named_child_count() != 0 {
		if got_node := node.first_named_child_for_byte(u32(offset)) {
			original_range = got_node.range()
		}
	}

	mut locations := []lsp.LocationLink{cap: 20}

	// check first the possible interfaces implemented by the symbol
	// at the current directory...
	get_implementation_locations_from_syms(ls.store.symbols[ls.store.cur_dir], got_sym,
		original_range, mut locations)

	// ...afterwards to the imported modules
	for imp in ls.store.imports[ls.store.cur_dir] {
		if ls.store.cur_file_path !in imp.ranges {
			continue
		}

		get_implementation_locations_from_syms(ls.store.symbols[imp.path], got_sym, original_range, mut
			locations)
	}

	// ...and lastly from auto-imported modules such as "builtin"
	$if !test {
		for _, auto_import_path in ls.store.auto_imports {
			get_implementation_locations_from_syms(ls.store.symbols[auto_import_path],
				got_sym, original_range, mut locations)
		}
	}

	return locations
}
