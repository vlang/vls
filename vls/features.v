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
			if uri in ls.trees || uri.dir() == ls.root_uri {
				sym_info := symbol_to_symbol_info(uri, sym) or { continue }
				workspace_symbols << sym_info
				for child_sym in sym.children {
					child_sym_info := symbol_to_symbol_info(uri, child_sym) or { continue }
					workspace_symbols << child_sym_info
				}
			} else {
				unsafe { uri.free() }
			}
		}
	}

	ls.send(jsonrpc.Response<[]lsp.SymbolInformation>{
		id: id
		result: workspace_symbols
	})

	unsafe{ workspace_symbols.free() }
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
				kind = if sym.kind == .function && !sym.parent.is_void() {
					lsp.SymbolKind.method
				} else {
					lsp.SymbolKind.function
				}
			}
			.struct_ { kind = .struct_ }
			.enum_ { kind = .enum_ }
			.typedef { kind = .type_parameter }
			.interface_ { kind = .interface_ }
			.variable { kind = .constant }
		else { return none }
	}	
	prefix := if sym.kind == .function && !sym.parent.is_void() { sym.parent.name + '.' } else { '' }
	return lsp.SymbolInformation{
		name: prefix + sym.name
		kind: kind
		location: lsp.Location{
			uri: uri
			range: tsrange_to_lsp_range(sym.range)
		}
	}
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
		sym_info := symbol_to_symbol_info(uri, sym) or { continue }
		document_symbols << sym_info
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
	uri := signature_params.text_document.uri
	pos := signature_params.position
	ctx := signature_params.context
	file := ls.sources[uri]
	source := file.source
	tree := ls.trees[uri] or { 
		ls.send_null(id)
		return
	}
	off := compute_offset(source, pos.line, pos.character)
	mut node := traverse_node(tree.root_node(), u32(off))
	mut parent_node := node
	if node.get_type() == 'argument_list' {
		parent_node = node.parent()
		node = node.prev_named_sibling()
	}

	// signature help supports function calls for now
	// hence checking the node if it's a call_expression node.
	if node.is_null() || parent_node.get_type() != 'call_expression' {
		ls.send_null(id)
		return
	}

	ls.store.set_active_file_path(uri.path(), file.version)

	sym := ls.store.infer_symbol_from_node(node, source) or {
		ls.send_null(id)
		return
	}

	args_node := parent_node.child_by_field_name('arguments')
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

struct CompletionBuilder {
mut:
	store 							&analyzer.Store
	src 								[]byte
	offset              int
	parent_node         C.TSNode
	show_global         bool // for displaying global (project) symbols
	show_local          bool // for displaying local variables
	filter_return_type  &analyzer.Symbol = &analyzer.Symbol(0) // filters results by type
	fields_only         bool     // for displaying only the struct/enum fields
	show_mut_only       bool     // filters results based on the object's mutability state.
	ctx 								lsp.CompletionContext
	completion_items    []lsp.CompletionItem = []lsp.CompletionItem{cap: 100}
}

fn (mut builder CompletionBuilder) add(item lsp.CompletionItem) {
	builder.completion_items << item
}

fn (mut builder CompletionBuilder) is_triggered(node C.TSNode, chr string) bool {
	return node.next_sibling().get_text(builder.src) == chr || builder.ctx.trigger_character == chr
}

fn (mut builder CompletionBuilder) is_selector(node C.TSNode) bool {
	return builder.is_triggered(node, '.')
}

fn (mut builder CompletionBuilder) build_suggestions(node C.TSNode, offset int) {
	builder.offset = offset
	builder.build_suggestions_from_node(node)
	if builder.show_local {
		builder.build_local_suggestions()
	}
	if builder.show_global {
		builder.build_global_suggestions()
	}
}

fn (mut builder CompletionBuilder) build_suggestions_from_node(node C.TSNode) {
	node_type := node.get_type()
	if node_type in vls.list_node_types {
		builder.build_suggestions_from_list(node)
	} else if node_type == 'module_clause' {
		builder.build_module_suggestions()
	} else {
		builder.build_suggestions_from_stmt(node)
	}
}

// suggestions_from_stmt returns a list of results from the extracted Stmt node info.
fn (mut builder CompletionBuilder) build_suggestions_from_stmt(node C.TSNode) {
	match node.get_type() {
		'short_var_declaration' {}
		'assignment_statement' {
			right_node := node.child_by_field_name('right')
			left_node := node.child_by_field_name('left')
			expr_list_count := right_node.named_child_count()
			left_count := left_node.named_child_count()
			if expr_list_count == left_count {
				last_left_node := left_node.named_child(left_count - 1)
				builder.filter_return_type = builder.store.infer_value_type_from_node(last_left_node, builder.src)
				builder.show_local = true
			}
		}
		else {
			builder.build_suggestions_from_expr(node)
		}
	}
}

// suggestions_from_list returns a list of results extracted from the list nodes.
fn (mut builder CompletionBuilder) build_suggestions_from_list(node C.TSNode) {
	match node.get_type() {
		'identifier_list' {}
		'expression_list' {
			// expr_list_count := node.named_child_count()
			parent := closest_symbol_node_parent(node)
			parent_type := parent.get_type()
			match parent_type {
				'assignment_statement' {
					builder.build_suggestions_from_stmt(parent)
				}
				else {
					closest_node := closest_named_child(node, u32(builder.offset))
					eprintln(closest_node.get_type())
				}
			}
		}
		'argument_list' {
			call_expr_arg_cur_idx := node.named_child_count()
			returned_sym := builder.store.infer_symbol_from_node(node.parent(), builder.src) or { builder.filter_return_type }
			if call_expr_arg_cur_idx < u32(returned_sym.children.len) {
				builder.filter_return_type = returned_sym.children[int(call_expr_arg_cur_idx)].return_type
				builder.show_local = true
			}
		}
		'import_symbols_list' {
			import_node := closest_symbol_node_parent(node)
			import_path_node := import_node.child_by_field_name('path')
			import_path := import_path_node.get_text(builder.src)
			builder.build_suggestions_from_module(import_path)
		}
		else {}
	}
}

// suggestions_from_expr returns a list of results extracted from the Expr node info.
fn (mut builder CompletionBuilder) build_suggestions_from_expr(node C.TSNode) {
	node_type := node.get_type()
	match node_type {
		'identifier', 'selector_expression', 'call_expression', 'index_expression' {
			builder.show_global = false
			builder.show_local = false

			text := node.get_text(builder.src)
			defer { unsafe { text.free() } }

			if builder.is_selector(node) {	
				if got_sym := builder.store.infer_symbol_from_node(node, builder.src) {
					builder.show_mut_only = builder.parent_node.get_type() == 'block' && got_sym.is_mutable()
					builder.build_suggestions_from_sym(got_sym.return_type, true)
				} else if builder.store.is_module(text) {
					builder.build_suggestions_from_module(text)
				}
			}
		}
		'literal_value' {
			closest_element_node := closest_named_child(node, u32(builder.offset))
			if closest_element_node.get_type() == 'keyed_element' {
				builder.build_suggestions_from_expr(closest_element_node)
			} else if returned_sym := builder.store.infer_symbol_from_node(node.parent(), builder.src) {
				builder.build_suggestions_from_sym(returned_sym, false)
			}
		}
		'keyed_element' {
			if returned_sym := builder.store.infer_symbol_from_node(node, builder.src) { 
				// if returned_sym.is_returnable() {
				// builder.filter_return_type = returned_sym.return_type
				// }
				// TODO: just duplicating code in order to pass tests. refactors should be done later
				for child_sym in returned_sym.return_type.children {
					if returned_sym.kind in [.enum_, .struct_] && child_sym.kind != .field {
						continue
					}
					builder.add(symbol_to_completion_item(child_sym, '') or {
						continue
					})
				}
			}
		}
		else {
			// found_sym := builder.store.infer_symbol_from_node(node, builder.src) or { analyzer.void_type }
			// builder.filter_return_type = if found_sym.is_returnable() { found_sym.return_type } else { found_sym }
		}
	}
}

fn (mut builder CompletionBuilder) build_suggestions_from_sym(sym &analyzer.Symbol, is_selector bool) {
	if isnil(sym) || sym.is_void() {
		return
	}
	
	for child_sym in sym.children {
		if is_selector {
			if sym.kind in [.enum_, .struct_] && child_sym.kind !in [.field, .function] {
				continue
			}

			if child_sym.kind != .function && builder.show_mut_only && !child_sym.is_mutable() {
				continue
			} else if child_sym.kind == .function && !builder.show_mut_only && child_sym.is_mutable() {
				continue
			}
			
			if existing_completion_item := symbol_to_completion_item(child_sym, '') {
				builder.add(lsp.CompletionItem{
					...existing_completion_item
					label: child_sym.name
					insert_text: child_sym.name
				})
			}
		} else if child_sym.kind == .field {
			builder.add(lsp.CompletionItem{
				label: '${child_sym.name}:'
				kind: .field
				insert_text: '${child_sym.name}: \$0'
				insert_text_format: .snippet
				detail: child_sym.gen_str()
			})
		}
	}
}

fn (mut builder CompletionBuilder) build_suggestions_from_module(name string) {
	imported_path_dir := builder.store.get_module_path(name)
	imported_syms := builder.store.symbols[imported_path_dir]
	for imp_sym in imported_syms {
		if int(imp_sym.access) >= int(analyzer.SymbolAccess.public) {
			builder.add(symbol_to_completion_item(imp_sym, '') or {
				continue
			})
		}
	}
}

fn (mut builder CompletionBuilder) build_module_suggestions() {
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

	// Scope-based symbols that includes the variables inside
	// the functions and the constants of the file.
	if file_scope := builder.store.opened_scopes[builder.store.cur_file_path] {
		mut scope := file_scope.innermost(u32(builder.offset), u32(builder.offset))
		for !isnil(scope) {
			// constants
			for scope_sym in scope.get_all_symbols() {
				if !isnil(builder.filter_return_type) && scope_sym.return_type != builder.filter_return_type {
					continue
				}

				kind := if isnil(scope.parent) { 
					lsp.CompletionItemKind.constant 
				} else {
					lsp.CompletionItemKind.variable
				}

				builder.add(lsp.CompletionItem{
					label: scope_sym.name
					kind: kind
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
	local_syms := builder.store.get_symbols_by_file_path(builder.store.cur_file_path)
	for local_sym in local_syms {
		if local_sym.is_void() || local_sym.kind in [.placeholder, .variable] {
			continue
		}
		if local_sym.kind == .function && local_sym.name == 'main' {
			continue
		}
		builder.add(symbol_to_completion_item(local_sym, '') or {
			continue
		})
	}

	for imp in builder.store.imports[builder.store.cur_dir] {
		if builder.store.cur_file_name in imp.symbols && imp.symbols[builder.store.cur_file_name].len != 0 {
			for imp_sym_name in imp.symbols[builder.store.cur_file_path] {
				imp_sym := builder.store.symbols[imp.path].get(imp_sym_name) or {
					continue
				}
				if int(imp_sym.access) > int(analyzer.SymbolAccess.private_mutable) {
					builder.add(symbol_to_completion_item(imp_sym, '') or {
						continue
					})
				}
			}
		} else {
			// TODO:
			continue
		}
	}
}

fn symbol_to_completion_item(sym &analyzer.Symbol, prefix string) ?lsp.CompletionItem {
	mut kind := lsp.CompletionItemKind.text
	mut name := if prefix.len == 0 { sym.name } else { prefix + '.' + sym.name }
	mut insert_text := name
	match sym.kind {
		.variable { kind = .variable }
		.function {
			// if function has parent, use method
			if !sym.parent.is_void() {
				kind = .method
			} else {
				kind = .function 
			}
		}
		.struct_ { kind = .struct_ }
		.field {
			match sym.parent.kind {
				.enum_ { 
					kind = .enum_member 
					insert_text = '.${sym.name}'
					name = insert_text
				}
				.struct_ { kind = .property }
				else { return none }
			}
		}
		.interface_ { kind = .interface_ }
		.typedef { kind = .type_parameter }
		else { return none }
	}

	// TODO:
	return lsp.CompletionItem{
		label: name
		kind: kind
		insert_text: insert_text
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
	file := ls.sources[uri]
	src := file.source
	tree := ls.trees[uri]
	root_node := tree.root_node()
	pos := completion_params.position
	// file_path := uri.path()
	mut offset := compute_offset(src, pos.line, pos.character)

	ls.store.set_active_file_path(uri.path(), file.version)

	// The context is used for if and when to trigger autocompletion.
	// See comments `cfg` for reason.
	mut ctx := completion_params.context

	// The config is used by all methods for determining the results to be sent
	// to the client. See the field comments in CompletionBuilder for their
	// purposes.
	mut builder := CompletionBuilder{
		store: &ls.store
		src: src
	}

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
				trigger_character: src[prev_idx].ascii_str()
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
			builder.show_global = false
			builder.show_local = false

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
		mut node := traverse_node2(root_node, u32(offset))
		parent_node := traverse_node(root_node, u32(offset))

		if root_node.is_error() && root_node.get_type() == 'ERROR' {
			// point to the identifier for assignment statement
			node = traverse_node(node, node.start_byte())
		} else if node.get_type() == 'block' {
			node = traverse_node2(root_node, u32(offset))
		} else if node.is_error() && node.get_type() == 'ERROR' {
			node = node.prev_named_sibling()
		}

		builder.ctx = ctx
		builder.parent_node = parent_node
		builder.build_suggestions(node, offset)
	} else if ctx.trigger_kind == .invoked && (root_node.named_child_count() == 0 || src.len <= 3) {
		// When a V file is empty, a list of `module $name` suggsestions will be displayed.
		builder.build_module_suggestions()
	} else {
		// Display only the project's functions if none are satisfied
		builder.offset = offset
		builder.build_local_suggestions()
	}

	// After that, it will send the list to the client.
	ls.send(jsonrpc.Response<[]lsp.CompletionItem>{
		id: id
		result: builder.completion_items
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
	tree := ls.trees[uri] or { 
		ls.send_null(id)
		return
	}
	file := ls.sources[uri]
	source := file.source
	offset := compute_offset(source, pos.line, pos.character)
	node := traverse_node(tree.root_node(), u32(offset))

	ls.store.set_active_file_path(uri.path(), file.version)
	hover_data := get_hover_data(mut ls.store, node, uri, source, u32(offset)) or {
		ls.send_null(id)
		return
	}
	
	ls.send(jsonrpc.Response<lsp.Hover>{
		id: id
		result: hover_data
	})
}

fn get_hover_data(mut store analyzer.Store, node C.TSNode, uri lsp.DocumentUri, source []byte, offset u32) ?lsp.Hover {
	node_type := node.get_type()
	if node.is_null() || node_type == 'comment' {
		return none
	}

	mut original_range := node.range()
	// eprintln('$node_type | ${node.get_text(source)}')
	if node_type == 'module_clause' {
		return lsp.Hover{
			contents: lsp.v_marked_string(node.get_text(source))
			range: tsrange_to_lsp_range(node.range())
		}
	} else if node_type == 'import_path' {
		found_imp := store.find_import_by_position(node.range()) ?
		return lsp.Hover{
			contents: lsp.v_marked_string('import ${found_imp.module_name} as ' + found_imp.aliases[uri.path()] or { found_imp.module_name })
			range: tsrange_to_lsp_range(found_imp.ranges[uri.path()])
		}	
	} else if node.parent().is_error() || node.parent().is_missing() {
		return none
	}

	if node_type != 'type_selector_expression' && node.named_child_count() != 0 {
		original_range = node.first_named_child_for_byte(u32(offset)).range()
	}

	mut sym := store.infer_symbol_from_node(node, source) or { analyzer.void_type }
	if isnil(sym) || sym.is_void() {
		closest_parent := closest_symbol_node_parent(node)
		sym = store.infer_symbol_from_node(closest_parent, source) ?
	}

	// eprintln('$node_type | ${node.get_text(source)} | $sym')

	// Send null if range has zero-start and end points
	if sym.range.start_point.row == 0 && sym.range.start_point.column == 0 && sym.range.start_point.eq(sym.range.end_point) {
		return none
	}

	return lsp.Hover{
		contents: lsp.v_marked_string(sym.gen_str())
		range: tsrange_to_lsp_range(original_range)
	}	
}

[manualfree]
fn (mut ls Vls) folding_range(id int, params string) {
	folding_range_params := json.decode(lsp.FoldingRangeParams, params) or {
		ls.panic(err.msg)
		ls.send_null(id)

		return
	}
	uri := folding_range_params.text_document.uri
	tree := ls.trees[uri] or { 
		ls.send_null(id)
		return
	}

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
	file := ls.sources[uri]
	source := file.source
	tree := ls.trees[uri] or { 
		ls.send_null(id)
		return
	}
	offset := compute_offset(source, pos.line, pos.character)
	mut node := traverse_node(tree.root_node(), u32(offset))
	mut original_range := node.range()
	node_type := node.get_type()
	if node.is_null() || (node.parent().is_error() || node.parent().is_missing()) {
		ls.send_null(id)
		return
	}

	ls.store.set_active_file_path(uri.path(), file.version)
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
