module analyzer

import strconv
import errors
import tree_sitter as ts
import tree_sitter_v as v
import os

pub struct SemanticAnalyzer {
pub mut:
	cursor   TreeCursor
	src_text []rune
	store    &Store     [required]
	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import bool
}

struct SemanticAnalyzerContext {
	params []ReportData
}

fn (mut an SemanticAnalyzer) report(node ts.Node<v.NodeType>, code_or_msg string, data ...ReportData) IError {
	mut is_msg_code := false
	if code_or_msg in errors.message_templates {
		is_msg_code = true
	}

	return error(an.format_report(
		kind: .error
		message: if is_msg_code { errors.message_templates[code_or_msg] } else { code_or_msg }
		range: node.range()
		file_path: an.store.cur_file_path
		code: if is_msg_code { code_or_msg } else { '' }
		data: SemanticAnalyzerContext{data}
	))
}

fn (mut an SemanticAnalyzer) format_report(report Report) string {
	if report.data is SemanticAnalyzerContext {
		if report.data.params.len != 0 {
			mut final_params := []string{cap: report.data.params.len}
			for d in report.data.params {
				if d is string {
					final_params << d
				} else if d is Symbol {
					final_params << d.gen_str(with_access: false, with_kind: false).replace_each(['int_literal', 'int', 'float_literal', 'float'])
				} else {
					// final_params << d.str()
					final_params << 'unknown'
				}
			}

			ptrs := unsafe { final_params.pointers() }
			final_report := Report{
				...report
				message: strconv.v_sprintf(report.message, ...ptrs)
				data: 0
			}

			an.store.report(final_report)
			return final_report.message
		}
	}

	an.store.report(report)
	return report.message
}

fn (mut an SemanticAnalyzer) import_decl(node ts.Node<v.NodeType>) ? {
	// Most of the checking is already done in `import_modules_from_trees`
	// Check only the symbols if they are available
	symbols := node.child_by_field_name('symbols') ?
	module_name_node := node.child_by_field_name('path') ?
	module_name := module_name_node.code(an.src_text)
	// defer { unsafe { module_name.free() } }

	module_path := an.store.get_module_path_opt(module_name) or {
		// `import_modules_from_trees` already reported it
		return
	}

	list := symbols.named_child(0) ?
	symbols_count := list.named_child_count()
	for i := u32(0); i < symbols_count; i++ {
		sym_node := list.named_child(i) or { continue }
		symbol_name := sym_node.code(an.src_text)
		got_sym := an.store.symbols[module_path].get(symbol_name) or {
			an.report(sym_node, 'Symbol `$symbol_name` in module `$module_name` not found')
			continue
		}

		if int(got_sym.access) < int(SymbolAccess.public) {
			an.report(sym_node, 'Symbol `$symbol_name` in module `$module_name` not public')
			continue
		}
	}
}

fn (mut an SemanticAnalyzer) const_decl(node ts.Node<v.NodeType>) {
}

fn (mut an SemanticAnalyzer) struct_decl(node ts.Node<v.NodeType>) {
}

fn (mut an SemanticAnalyzer) interface_decl(node ts.Node<v.NodeType>) {
}

fn (mut an SemanticAnalyzer) enum_decl(node ts.Node<v.NodeType>) {
}

fn (mut an SemanticAnalyzer) fn_decl(node ts.Node<v.NodeType>) {
	// TODO: set cur_fn_name
	body_node := node.child_by_field_name('body') or { return }
	an.block(body_node)
}

fn (mut an SemanticAnalyzer) type_decl(node ts.Node<v.NodeType>) ? {
	types_node := node.child_by_field_name('types')?
	types_count := types_node.named_child_count()
	
	for i in u32(0) .. types_count {
		type_node := types_node.named_child(i) or { continue }
		got_sym := an.store.find_symbol_by_type_node(type_node, an.src_text) or {
			continue
		}

		if got_sym.is_void() || got_sym.kind == .placeholder {
			an.report(type_node, errors.unknown_type_error, type_node.code(an.src_text))
		}
	}
}

pub fn (mut an SemanticAnalyzer) top_level_statement(current_node ts.Node<v.NodeType>) {
	match current_node.type_name {
		.import_declaration {
			an.import_decl(current_node) or {
				// an.messages.report(err)
			}
		}
		.const_declaration {
			an.const_decl(current_node)
		}
		.struct_declaration {
			an.struct_decl(current_node)
		}
		.interface_declaration {
			an.interface_decl(current_node)
		}
		.enum_declaration {
			an.enum_decl(current_node)
		}
		.function_declaration {
			an.fn_decl(current_node)
		}
		.type_declaration {
			an.type_decl(current_node) or {}
		}
		else {
			an.statement(current_node)
		}
	}
}

pub fn (mut an SemanticAnalyzer) assignment_statement(node ts.Node<v.NodeType>) ? {
	op_node := node.child_by_field_name('operator')?
	op := op_node.raw_node.type_name()[0].ascii_str()
	is_multiplicative := op in multiplicative_operators
	is_additive := op in additive_operators

	left_node := node.child_by_field_name('left')?
	right_node := node.child_by_field_name('right')?
	left_sym_count := left_node.named_child_count()
	right_sym_count := right_node.named_child_count()

	if left_sym_count == right_sym_count {
		for i in u32(0) .. u32(left_sym_count) {
			left_child := left_node.named_child(i) or { continue }
			right_child := right_node.named_child(i) or { continue }

			left_sym := an.expression(left_child, as_value: true) or { analyzer.void_sym }
			mut right_sym := an.expression(right_child, as_value: true) or { analyzer.void_sym }

			if is_multiplicative || is_additive {
				if left_sym.name in analyzer.numeric_types_with_any_type || right_sym.name in analyzer.numeric_types_with_any_type {
					an.report(node, errors.mismatched_type_error, left_sym, right_sym)
				} else {
					an.report(node, errors.undefined_operation_error, left_sym, op, right_sym)
				}
			} else if right_child.type_name == .unary_expression && left_sym != right_sym {
				unary_op_node := right_child.child_by_field_name('operator') or { continue }
				if right_sym.kind == .chan_ {
					right_sym = right_sym.parent_sym
				}

				an.report(unary_op_node, errors.invalid_assignment_error, left_child.code(an.src_text), left_sym, right_sym)
			} else if left_sym != right_sym {
				an.report(node, errors.invalid_assignment_error, left_child.code(an.src_text), left_sym, right_sym)
			}
		}
	}
}

pub fn (mut an SemanticAnalyzer) block(node ts.Node<v.NodeType>) {
	mut cursor := new_tree_cursor(node)
	for got_node in cursor {
		an.statement(got_node)
	}
}

pub fn (mut an SemanticAnalyzer) short_var_declaration(node ts.Node<v.NodeType>) ? {
	right := node.child_by_field_name('right')?
	right_count := right.named_child_count()
	for i in u32(0) .. right_count {
		right_child := right.named_child(i) or { continue }
		an.expression(right_child, as_value: true) or { continue }
	}
}

pub fn (mut an SemanticAnalyzer) assert_statement(node ts.Node<v.NodeType>) ? {
	expr_node := node.named_child(0)?
	expr_typ_sym := an.expression(expr_node, as_value: true) or { analyzer.void_sym }
	if expr_typ_sym.name != 'bool' {
		an.report(expr_node, errors.invalid_assert_type_error, expr_typ_sym)
	}
}

pub fn (mut an SemanticAnalyzer) send_statement(node ts.Node<v.NodeType>) ? {
	chan_node := node.child_by_field_name('channel')?
	val_node := node.child_by_field_name('value')?
	chan_typ_sym := an.expression(chan_node) or { analyzer.void_sym }
	val_typ_sym := an.expression(val_node) or { analyzer.void_sym }
	if chan_typ_sym.kind != .chan_ {
		an.report(chan_node, errors.send_channel_invalid_chan_type_error, chan_typ_sym)
	} else if val_typ_sym != chan_typ_sym.parent_sym {
		an.report(chan_node, errors.send_channel_invalid_value_type_error, val_typ_sym, chan_typ_sym)
	}
}

pub fn (mut an SemanticAnalyzer) statement(node ts.Node<v.NodeType>) {
	match node.type_name {
		.assignment_statement {
			an.assignment_statement(node) or {}
		}
		.assert_statement {
			an.assert_statement(node) or {}
		}
		.send_statement {
			an.send_statement(node) or {}
		}
		.short_var_declaration {
			an.short_var_declaration(node) or {}
		}
		.block {
			an.block(node)
		}
		else {
			an.expression(node) or {}
		}
	}
}

const multiplicative_operators = ["*", "/", "%", "<<", ">>", "&", "&^"]
const additive_operators = ["+", "-", "|", "^"]
const comparative_operators = ["==", "!=", "<", "<=", ">", ">="]
const and_operators = ["&&"]
const or_operators = ["||"]

fn (an &SemanticAnalyzer) convert_to_lit_type(node ts.Node<v.NodeType>) ?&Symbol {
	node_type := node.type_name
	if node_type == .float_literal || (node_type == .int_literal && node.code(an.src_text).int() < 17) {
		return an.store.find_symbol('', node.raw_node.type_name())
	}
	return none
}

pub fn (mut an SemanticAnalyzer) binary_expression(node ts.Node<v.NodeType>, cfg SemanticExpressionAnalyzeConfig) ?&Symbol {
	left_node := node.child_by_field_name('left')?
	right_node := node.child_by_field_name('right')?
	op_node := node.child_by_field_name('operator')?
	op := op_node.raw_node.type_name()
	is_multiplicative := op in multiplicative_operators
	is_additive := op in additive_operators
	is_comparative := op in comparative_operators
	// is_and := op in and_operators
	// is_or := op in or_operators
	left_sym := an.convert_to_lit_type(left_node) or { an.expression(left_node) or { analyzer.void_sym } }
	right_sym := an.convert_to_lit_type(right_node) or { an.expression(right_node) or { analyzer.void_sym } }

	if op == '<<' {
		if cfg.as_value {
			return an.report(op_node, errors.array_append_expr_error)
		} else if left_sym.kind == .array_ && left_sym.children_syms[0] != right_sym {
			return an.report(right_node, errors.append_type_mismatch_error, right_sym, left_sym)
		} else {
			return an.report(node, errors.undefined_operation_error, left_sym, op, right_sym)
		}
	} else if is_multiplicative || is_additive {
		// check if left and right are both numeric types
		if left_sym.name !in analyzer.numeric_types_with_any_type || right_sym.name !in analyzer.numeric_types_with_any_type {
			if left_sym.name in analyzer.numeric_types_with_any_type || right_sym.name in analyzer.numeric_types_with_any_type {
				an.report(node, errors.mismatched_type_error, left_sym, right_sym)
			} else {
				an.report(node, errors.undefined_operation_error, left_sym, op, right_sym)
			}
			return analyzer.void_sym
		}
	} else if is_comparative && left_sym != right_sym {
		return an.report(node, errors.mismatched_type_error, left_sym, right_sym)
	} else if left_sym.name != 'bool' || right_sym.name != 'bool' {
		// check if left and right are both numeric types
		return an.report(node, errors.mismatched_type_error, left_sym, right_sym)
	}
	return left_sym
}

fn (an &SemanticAnalyzer) check_if_type_field_exists(node ts.Node<v.NodeType>, name string) bool {
	if node.type_name != .literal_value {
		return false
	}

	mut cursor := new_tree_cursor(node)
	for child_node in cursor {
		if child_node.type_name == .keyed_element {
			key_node := child_node.child_by_field_name('name') or { continue }
			if key_node.code(an.src_text) == name {
				return true
			}
		}
	}

	return false
}

pub fn (mut an SemanticAnalyzer) type_initializer(node ts.Node<v.NodeType>) ?&Symbol {
	type_node := node.child_by_field_name('type')?
	sym_kind, module_name, symbol_name := symbol_name_from_node(type_node, an.src_text)

	match sym_kind {
		.array_, .variadic {
			el_node := type_node.child_by_field_name('element')?
			el_sym := an.store.find_symbol_by_type_node(el_node, an.src_text) or { analyzer.void_sym }
			if el_sym.is_void() || el_sym.kind == .placeholder {
				return an.report(el_node, errors.unknown_type_error, el_node.code(an.src_text))
			} else if el_sym.kind == .sumtype {
				if type_node.type_name == .fixed_array_type {
					return an.report(node, errors.invalid_sumtype_array_init_error)
				} else if body_node := node.child_by_field_name('body') {
					// trigger error only if len field exists since setting the len
					// field will allocate and insert default values into the array
					// which the sumtype array cannot since the value is ambiguous and
					// null is not allowed
					if an.check_if_type_field_exists(body_node, 'len') {
						return an.report(type_node, errors.invalid_sumtype_array_init_error)
					}
				}
			}
		}
		.map_ {
			key_node := type_node.child_by_field_name('key')?
			key_sym := an.store.find_symbol_by_type_node(key_node, an.src_text) or {
				analyzer.void_sym
			}

			if key_sym.is_void() || key_sym.kind == .placeholder {
				an.report(key_node, errors.unknown_type_error, key_node.code(an.src_text))
			}

			val_node := type_node.child_by_field_name('value')?
			val_sym := an.store.find_symbol_by_type_node(val_node, an.src_text) or {
				analyzer.void_sym
			}

			if val_sym.is_void() || val_sym.kind == .placeholder {
				an.report(val_node, errors.unknown_type_error, val_node.code(an.src_text))
			}
		}
		.chan_, .ref, .optional {
			el_node := type_node.named_child(0)?
			el_sym := an.store.find_symbol_by_type_node(el_node, an.src_text) or {
				analyzer.void_sym
			}

			if el_sym.is_void() || el_sym.kind == .placeholder {
				an.report(el_node, errors.unknown_type_error, el_node.code(an.src_text))
			}
		}
		else {}
	}

	return an.store.find_symbol(module_name, symbol_name)
}

pub fn (mut an SemanticAnalyzer) selector_expression(node ts.Node<v.NodeType>) ?&Symbol {
	operand := node.child_by_field_name('operand')?
	mut root_sym := an.expression(operand) or {
		an.store.infer_symbol_from_node(operand, an.src_text) or { analyzer.void_sym }
	}

	if !root_sym.is_void() {
		if root_sym.is_returnable() {
			root_sym = root_sym.return_sym
		}

		field_node := node.child_by_field_name('field')?
		child_name := field_node.code(an.src_text)
		got_child_sym := root_sym.children_syms.get(child_name) or {
			mut base_root_sym := root_sym
			if root_sym.kind in [.ref, .chan_, .optional] {
				base_root_sym = root_sym.parent_sym
			} else if root_sym.kind == .array_ {
				base_root_sym = an.store.find_symbol('', 'array') or { analyzer.void_sym }
			} else if root_sym.kind == .map_ {
				base_root_sym = an.store.find_symbol('', 'map') or { analyzer.void_sym }
			}
			base_root_sym.children_syms.get(child_name) or { void_sym }
		}

		// NOTE: transfer this to `store.infer_symbol_from_node` if possible
		mut got_sym_kind_from_embed := SymbolKind.void
		mut method_or_field_sym := analyzer.void_sym
		mut method_or_field_typ_idx := -1

		for child_sym_idx, child_sym in root_sym.children_syms {
			if child_sym.kind != .embedded_field {
				continue
			}

			returned_sym := child_sym.return_sym.children_syms.get(child_name) or {
				continue
			}

			if method_or_field_typ_idx == -1 {
				method_or_field_sym = returned_sym
				method_or_field_typ_idx = child_sym_idx
				got_sym_kind_from_embed = returned_sym.kind
			} else {
				err_code := if got_sym_kind_from_embed == .function {
					errors.ambiguous_method_error
				} else {
					errors.ambiguous_field_error
				}

				mut in_parent := false
				if parent := node.parent() {
					if parent.type_name == .call_expression {
						in_parent = true
						an.report(parent, err_code, child_name)
					}
				}

				if !in_parent {
					an.report(field_node, err_code, child_name)
				}
			}
		}	

		return if method_or_field_sym.is_void() {
			got_child_sym
		} else {
			method_or_field_sym
		}
	}

	return root_sym
}

pub fn (mut an SemanticAnalyzer) array(node ts.Node<v.NodeType>) ?&Symbol {
	items_len := node.named_child_count()
	if items_len == 0 {
		return an.report(node, errors.untyped_empty_array_error)
	}

	first_item_node := node.named_child(0)?
	mut expected_sym := an.expression(first_item_node) or { analyzer.void_sym }
	if expected_sym.is_void() {
		return expected_sym
	} else if items_len > 1 {
		for i in u32(1) .. items_len {
			item_child_node := node.named_child(i) or { continue }
			returned_item_sym := an.expression(item_child_node) or { analyzer.void_sym }
			if returned_item_sym != expected_sym {
				an.report(item_child_node, errors.invalid_array_element_type_error, expected_sym, returned_item_sym)
				continue
			}
		}
	}

	symbol_name := '[]' + expected_sym.gen_str(with_kind: false, with_access: false, with_contents: false)
	return an.store.find_symbol('', symbol_name) or {
		mut new_sym := Symbol{
			name: symbol_name.clone()
			is_top_level: true
			file_path: os.join_path(an.store.cur_dir, 'placeholder.vv')
			file_version: 0
			kind: .array_
		}

		new_sym.add_child(mut expected_sym, false) or {}
		an.store.register_symbol(mut new_sym) or { analyzer.void_sym }
	}
}

pub fn (mut an SemanticAnalyzer) call_expression(node ts.Node<v.NodeType>) ?&Symbol {
	fn_node := node.child_by_field_name('function')?
	arguments_node := node.child_by_field_name('arguments')?
	fn_sym := an.expression(fn_node) or { analyzer.void_sym }
	if fn_sym.is_void() {
		return an.report(node, errors.unknown_function_error, fn_node.code(an.src_text))
	}

	// check arguments
	for i, _ in fn_sym.children_syms {
		arg_node := arguments_node.named_child(u32(i)) or { continue }
		// TODO:
		// mut returned_sym := an.expression(arg_node)
		// if returned_sym.is_returnable() {
		// 	returned_sym = arg_sym.return_sym
		// }

		// if returned_sym != arg_sym.return_sym {
		// 	an.custom_report(
		// 		analyzer.invalid_argument_error, 
		// 		arg_node, 
		// 		[returned_sym, arg_sym.return_sym],
		// 		{2: i.str(), 3: fn_sym.name}
		// 	)
		// }
		an.expression(arg_node) or {}
	}

	// TODO: or block checking

	if fn_sym.is_returnable() {
		return fn_sym.return_sym
	} else {
		return fn_sym
	}
}

[params]
pub struct SemanticExpressionAnalyzeConfig {
	as_value bool
}

pub fn (mut an SemanticAnalyzer) expression(node ts.Node<v.NodeType>, cfg SemanticExpressionAnalyzeConfig) ?&Symbol {
	match node.type_name {
		.call_expression {
			return an.call_expression(node)
		}
		.array {
			return an.array(node)
		}
		.selector_expression {
			return an.selector_expression(node)
		}
		.type_initializer {
			return an.type_initializer(node)
		}
		.binary_expression {
			return an.binary_expression(node, cfg)
		}
		.int_literal, .float_literal {
			return an.store.infer_value_type_from_node(node, an.src_text)
		}
		.parenthesized_expression {
			return an.expression(node.named_child(0)?, cfg)
		}
		else {
			sym := an.store.infer_symbol_from_node(node, an.src_text) or { void_sym }
			if sym.kind == .variable || sym.kind == .field {
				// if sym.name == an.cur_fn_name && sym.kind == .variable {
				// 	parent := node.parent()?
				// 	if parent.type_name == .call_expression {
				// 		an.report(parent, errors.ambiguous_call_error,
				// 			'', // an.cur_fn_name
				// 			'', // an.cur_fn_name
				// 			'', // an.cur_fn_name
				// 		)
				// 	}
				// 	return void_sym
				// }

				return sym.return_sym
			} else {
				return sym
			}

			// return an.report(node, errors.unknown_node_type_error, node.raw_node.type_name())
		}
	}
}

pub fn (mut an SemanticAnalyzer) analyze() {
	for got_node in an.cursor {
		an.top_level_statement(got_node)
	}
}

// analyze analyzes the given tree
pub fn (mut store Store) analyze(tree &ts.Tree<v.NodeType>, src_text []rune) {
	mut an := SemanticAnalyzer{
		store: unsafe { store }
		src_text: src_text
		cursor: new_tree_cursor(tree.root_node())
	}
	an.analyze()
}
