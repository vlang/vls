module server

import lsp
import os
import analyzer
import math
import ast

const temp_formatting_file_path = os.join_path(os.temp_dir(), 'vls_temp_formatting.v')

[manualfree]
pub fn (mut ls Vls) formatting(params lsp.DocumentFormattingParams, mut wr ResponseWriter) ![]lsp.TextEdit {
	uri := params.text_document.uri.normalize()
	source := ls.files[uri].source
	tree_range := ls.files[uri].tree.root_node().range()
	if source.len() == 0 {
		return error('none')
	}

	// We don't integrate v.fmt and it's dependencies anymore to lessen
	// cleanups everytime launching an instance.
	//
	// To simplify this, we will make a temporary file and feed it into
	// the v fmt CLI program since there is no cross-platform way to pipe
	// raw strings directly into v fmt.
	mut temp_file := os.open_file(server.temp_formatting_file_path, 'w')!
	temp_file.write_string(source.string())!
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
		return error('none')
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

pub fn (mut ls Vls) document_symbol(params lsp.DocumentSymbolParams, mut wr ResponseWriter) ![]lsp.SymbolInformation {
	uri := params.text_document.uri.normalize()
	retrieved_symbols := ls.store.get_symbols_by_file_path(uri.path())
	mut document_symbols := []lsp.SymbolInformation{}
	for sym in retrieved_symbols {
		sym_info := symbol_to_symbol_info(uri, sym) or { continue }
		document_symbols << sym_info
	}
	return document_symbols
}

pub fn (mut ls Vls) signature_help(params lsp.SignatureHelpParams, mut wr ResponseWriter) ?lsp.SignatureHelp {
	if Feature.signature_help !in ls.enabled_features {
		return none
	}

	uri := params.text_document.uri.normalize()
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

	sym := ls.store.infer_symbol_from_node(uri.path(), node, file.source) or { return none }

	args_node := parent_node.child_by_field_name('arguments') or { return none }

	mut formatter := ls.store.with(file_path: uri.path()).symbol_formatter(false)

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
			label: formatter.format(child_sym, analyzer.params_format_cfg)
		}
	}

	return lsp.SignatureHelp{
		active_parameter: active_parameter_idx
		signatures: [
			lsp.SignatureInformation{
				label: formatter.format(sym)
				// documentation: lsp.MarkupContent{}
				parameters: param_infos
			},
		]
	}
}

// [manualfree]
pub fn (mut ls Vls) folding_range(params lsp.FoldingRangeParams, mut wr ResponseWriter) ?[]lsp.FoldingRange {
	uri := params.text_document.uri.normalize()
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

	for node in ast.new_tree_walker(root_node) {
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

	uri := params.text_document.uri.normalize()
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

	sym := ls.store.infer_symbol_from_node(uri.path(), node, source) or { analyzer.void_sym }
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

	uri := params.text_document.uri.normalize()
	file_path := uri.path()
	file_dir := uri.dir_path()
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

	mut got_sym := unsafe { analyzer.void_sym }
	if parent_node := node.parent() {
		if parent_node.type_name == .interface_declaration {
			got_sym = ls.store.symbols[file_dir].get(node.text(source)) or { got_sym }
		} else {
			got_sym = ls.store.infer_value_type_from_node(uri.path(), node, source)
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
	get_implementation_locations_from_syms(ls.store.symbols[file_dir], got_sym, original_range, mut
		locations)

	// ...afterwards to the imported modules
	for imp in ls.store.imports[file_dir] {
		if file_path !in imp.ranges {
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
