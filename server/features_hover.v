module server

import lsp
import os
import analyzer
import ast
import tree_sitter

pub fn (mut ls Vls) hover(params lsp.HoverParams, mut wr ResponseWriter) ?lsp.Hover {
	uri := params.text_document.uri.normalize()
	pos := params.position
	file := ls.files[uri] or { return none }
	offset := file.get_offset(pos.line, pos.character)
	node := traverse_node(file.tree.root_node(), u32(offset))
	return get_hover_data(mut ls.store, node, uri, file.source, u32(offset))
}

fn get_hover_data(mut store analyzer.Store, node ast.Node, uri lsp.DocumentUri, source tree_sitter.SourceText, offset u32) ?lsp.Hover {
	node_type_name := node.type_name
	parent_node := node.parent() or { node }
	file_path := uri.path()

	if node.is_null() || node_type_name == .comment || parent_node.is_error()
		|| parent_node.is_missing() {
		return none
	}

	sym := get_hovered_symbol_from_node(mut store, node, file_path, source)?
	mut range := node.range()
	mut hover_range := get_hovered_range_from_node(node, offset)
	mut contents := lsp.HoverResponseContent('')
	mut fmt := store.with(file_path: file_path).symbol_formatter(false)

	contents, hover_range = match sym.kind {
		.void {
			match node.type_name {
				.module_clause {
					result := lsp.hover_v_marked_string(node.text(source))
					result, hover_range
				}
				.import_path {
					get_module_detail(mut store, file_path, range)?
				}
				else {
					return none
				}
			}
		}
		.variable {
			detail := get_type_detail(sym.return_sym, mut fmt)?
			result := lsp.hover_markdown_string(detail)
			result, hover_range
		}
		else {
			result := if sym.docstrings.len == 0 {
				lsp.hover_v_marked_string(fmt.format(sym))
			} else {
				lsp.hover_markdown_string(get_signature_with_docstring(sym, mut fmt))
			}
			result, hover_range
		}
	}

	return lsp.Hover{
		contents: contents
		range: hover_range
	}
}

fn get_hovered_symbol_from_node(mut store analyzer.Store, node ast.Node, file_path string, source tree_sitter.SourceText) ?&analyzer.Symbol {
	if node.type_name in [.module_clause, .import_path] {
		// don't need symbol for hover doc info.
		return analyzer.void_sym
	}

	// TODO: make sure infer_symbol_from_node doesn't return nil reference.
	mut sym := store.infer_symbol_from_node(file_path, node, source) or {
		closest_parent := closest_symbol_node_parent(node)
		store.infer_symbol_from_node(file_path, closest_parent, source) or { analyzer.void_sym }
	}

	if sym.is_void() {
		return none
	}
	if sym.range.end_point.row == 0 && sym.range.end_point.column == 0 {
		return none
	}

	return sym
}

fn get_hovered_range_from_node(node ast.Node, offset u32) lsp.Range {
	mut range := node.range()
	mut hover_range := if node.type_name == .type_selector_expression
		|| node.named_child_count() == 0 {
		range
	} else if child := node.first_named_child_for_byte(offset) {
		new_range := child.range()
		if new_range.end_byte != 0 {
			new_range
		} else {
			range
		}
	} else {
		range
	}

	return tsrange_to_lsp_range(hover_range)
}

fn get_module_detail(mut store analyzer.Store, file_path string, node_range C.TSRange) ?(lsp.HoverResponseContent, lsp.Range) {
	file_name := os.base(file_path)
	found_imp := store.imports.find_by_position(file_path, node_range)?

	mut buffer := []string{}

	mut import_text := 'import ${found_imp.absolute_module_name}'
	if alias := found_imp.aliases[file_name] {
		import_text += ' as ${alias}'
	}

	buffer << '```v'
	buffer << import_text
	buffer << '```'
	buffer << '\n---\n'
	buffer << 'Found at ${found_imp.path}'

	result := lsp.hover_markdown_string(buffer.join('\n'))
	hover_range := tsrange_to_lsp_range(found_imp.ranges[file_path])
	return result, hover_range
}

fn get_type_detail(sym &analyzer.Symbol, mut fmt analyzer.SymbolFormatter) ?string {
	if isnil(sym) || sym.is_void() {
		return none
	}

	mut buffer := []string{}

	if sym.is_reference() {
		buffer << '```v'
		buffer << fmt.format_type_definition(sym)
		buffer << '```'
		buffer << '\n---\n'
	}

	target := sym.deref_all() or { sym }

	buffer << '```v'
	buffer << fmt.format_type_definition(target)
	buffer << '```'

	$if trace ? {
		if method_str := fmt.format_methods(target) {
			buffer << '\n---\n'
			buffer << '## Methods\n'
			buffer << '```v'
			buffer << method_str
			buffer << '```'
		}
	}

	return buffer.join('\n')
}

fn get_signature_with_docstring(sym &analyzer.Symbol, mut fmt analyzer.SymbolFormatter) string {
	mut buffer := [
		'```v',
		fmt.format(sym),
		'```',
	]
	if sym.docstrings.len > 0 {
		buffer << '\n---\n'
		buffer << fmt.format_docstrings(sym)
	}
	return buffer.join('\n')
}
