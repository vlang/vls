module analyzer

import strconv
import errors
import tree_sitter
import tree_sitter_v as v
import ast
import os

struct SemanticAnalyzerError {
	code    int
	typ     string
	content string
}

fn (err &SemanticAnalyzerError) code() int {
	return 0
}

fn (err &SemanticAnalyzerError) msg() string {
	return err.content
}

fn error_is(err IError, err_code string) bool {
	if err is SemanticAnalyzerError {
		if err.typ == err_code {
			return true
		}
	}
	return false
}

pub struct SemanticAnalyzer {
pub mut:
	src_text   tree_sitter.SourceText = Runes([]rune{len: 0})
	store      &Store     [required]
	parent_sym &Symbol = analyzer.void_sym
	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import bool
}

fn (an &SemanticAnalyzer) in_function() bool {
	return !isnil(an) && an.parent_sym.kind == .function
}

fn (an &SemanticAnalyzer) with_symbol(sym &Symbol) &SemanticAnalyzer {
	return &SemanticAnalyzer{
		src_text: an.src_text
		store: an.store
		parent_sym: sym
		is_import: an.is_import
	}
}

struct SemanticAnalyzerContext {
	params []ReportData
}

fn (mut an SemanticAnalyzer) report(node ast.Node, code_or_msg string, data ...ReportData) IError {
	mut is_msg_code := false
	if code_or_msg in errors.message_templates {
		is_msg_code = true
	}

	return SemanticAnalyzerError{
		typ: if is_msg_code { code_or_msg } else { 'custom_error' }
		content: an.format_report(
			kind: .error
			message: if is_msg_code { errors.message_templates[code_or_msg] } else { code_or_msg }
			range: node.range()
			file_path: an.store.cur_file_path
			code: if is_msg_code { code_or_msg } else { '' }
			data: SemanticAnalyzerContext{data}
		)
	}
}

fn (an &SemanticAnalyzer) format_report_data(d ReportData) string {
	if d is string {
		return *d
	} else if d is Symbol {
		return d.gen_str(with_access: false, with_kind: false, with_contents: false).replace_each(['int_literal', 'int literal', 'float_literal', 'float literal'])
	} else if d is []string {
		return d.join(', ')
	} else {
		// final_params << d.str()
		return 'unknown'
	}
}

fn (mut an SemanticAnalyzer) format_report(report Report) string {
	if report.data is SemanticAnalyzerContext {
		if report.data.params.len != 0 {
			mut final_params := []string{cap: report.data.params.len}
			mut final_msg := report.message
			for d in report.data.params {
				// maps are used for accepting named parameters in error messages
				// e.g. "cannot selectively import {{var}} from {{mod}}. use {{mod}}.{{var}} instead"
				if d is map[string]ReportData {
					for var_name, val in d {
						final_msg = final_msg.replace('{{$var_name}}', an.format_report_data(val))
					}
				} else if d is map[string]string {
					for var_name, val in d {
						final_msg = final_msg.replace('{{$var_name}}', an.format_report_data(unsafe { val }))
					}
				} else {
					final_params << an.format_report_data(d)
				}
			}

			ptrs := unsafe { final_params.pointers() }
			final_report := Report{
				...report
				message: strconv.v_sprintf(final_msg, ...ptrs)
				data: 0
			}

			an.store.report(final_report)
			return final_report.message
		}
	}

	an.store.report(report)
	return report.message
}

fn (mut an SemanticAnalyzer) import_decl(node ast.Node) ? {
	// Most of the checking is already done in `import_modules_from_trees`
	// Check only the symbols if they are available
	symbols := node.child_by_field_name('symbols') ?
	module_name_node := node.child_by_field_name('path') ?
	module_name := module_name_node.text(an.src_text)
	// defer { unsafe { module_name.free() } }

	module_path := an.store.get_module_path_opt(module_name) or {
		// `import_modules_from_trees` already reported it
		return
	}

	list := symbols.named_child(0) ?
	symbols_count := list.named_child_count()
	for i := u32(0); i < symbols_count; i++ {
		sym_node := list.named_child(i) or { continue }
		symbol_name := sym_node.text(an.src_text)
		got_sym := an.store.symbols[module_path].get(symbol_name) or {
			an.report(sym_node, 'Symbol `$symbol_name` in module `$module_name` not found')
			continue
		}

		if int(got_sym.access) < int(SymbolAccess.public) {
			an.report(sym_node, 'Symbol `$symbol_name` in module `$module_name` not public')
		} else if got_sym.kind == .variable && got_sym.is_const {
			an.report(sym_node, errors.selective_const_import_error, {
				'module': module_name
				'var': sym_node.text(an.src_text),
			})
		}
	}
}

fn (mut an SemanticAnalyzer) const_decl(node ast.Node) {
}

fn (mut an SemanticAnalyzer) struct_decl(node ast.Node) {
}

fn (mut an SemanticAnalyzer) interface_decl(node ast.Node) {
}

const max_int_value = '2147483647'

fn (mut an SemanticAnalyzer) enum_decl(node ast.Node) ? {
	name_node := node.child_by_field_name('name')?
	decl_list_node := node.last_node_by_type(v.NodeType.enum_member_declaration_list)?
	member_count := decl_list_node.named_child_count()
	if member_count == 0 {
		return an.report(name_node, errors.empty_enum_error)
	} else {
		mut value_overflowed := false
		mut member_names := []string{cap: int(member_count)}
		mut member_values := []string{len: int(member_count)}

		for i in 0 .. member_count {
			member_node := decl_list_node.named_child(i) or {
				continue
			}

			member_name_node := member_node.child_by_field_name('name') or {
				continue
			}

			member_name := member_name_node.text(an.src_text)
			if member_name in member_names {
				an.report(member_name_node, errors.enum_duplicate_member_error, member_name)
			} else {
				member_names << member_name
			}

			if member_value_node := member_node.child_by_field_name('value') {
				val_sym := an.expression(member_value_node, as_value: true) or { analyzer.void_sym }
				if val_sym.name != 'int' {
					an.report(member_value_node, errors.enum_default_value_error)
				} else if member_value_node.type_name == .int_literal && member_value_node.text(an.src_text) == max_int_value {
					value_overflowed = true
				}

				member_value_lit := member_value_node.text(an.src_text)
				if member_value_lit in member_values {
					an.report(member_value_node, errors.enum_duplicate_value_error, member_value_lit)
				} else {
					member_values[i] = member_value_lit
				}
			} else if value_overflowed {
				an.report(member_name_node, errors.enum_value_overflow_error)
			}
		}
	}
}

fn (mut an SemanticAnalyzer) fn_decl(node ast.Node) {
	body_node := node.child_by_field_name('body') or { return }
	if name_node := node.child_by_field_name('name') {
		fn_name := name_node.text(an.src_text)
		if sym := an.store.find_symbol('', fn_name) {
			mut inst := an.with_symbol(sym)
			inst.block(body_node)
			return
		}
	}
	an.block(body_node)
}

fn (mut an SemanticAnalyzer) type_decl(node ast.Node) ? {
	types_node := node.child_by_field_name('types')?
	types_count := types_node.named_child_count()

	for i in u32(0) .. types_count {
		type_node := types_node.named_child(i) or { continue }
		got_sym := an.store.find_symbol_by_type_node(type_node, an.src_text) or {
			analyzer.void_sym
		}

		if got_sym.is_void() || got_sym.kind == .placeholder {
			an.report(type_node, errors.unknown_type_error, type_node.text(an.src_text))
		}
	}
}

pub fn (mut an SemanticAnalyzer) top_level_statement(current_node ast.Node) {
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
			an.enum_decl(current_node) or {}
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

pub fn (mut an SemanticAnalyzer) assignment_statement(node ast.Node) ? {
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
			mut is_imaginary := false
			if left_child.text(an.src_text) == '_' {
				// ignore _ variables in invalid assignment errors
				is_imaginary = true
			}

			right_child := right_node.named_child(i) or { continue }

			left_sym := an.expression(left_child, as_value: true) or {
				if error_is(err, errors.constant_mutation_error) {
					continue
				}
				analyzer.void_sym
			}
			mut right_sym := an.expression(right_child, as_value: true) or { analyzer.void_sym }

			if is_imaginary && op != '=' {
				an.report(left_child, errors.imaginary_mutation_error)
			} else if is_multiplicative || is_additive {
				if left_sym.name in analyzer.numeric_types_with_any_type || right_sym.name in analyzer.numeric_types_with_any_type {
					an.report(node, errors.mismatched_type_error, left_sym, right_sym)
				} else {
					an.report(op_node, errors.undefined_operation_error, left_sym, op, right_sym)
				}
			} else if !is_imaginary {
				if left_sym.is_void() && op == '=' {
					an.report(left_child, errors.undefined_ident_assignment_error, left_child.text(an.src_text))
				} else if right_child.type_name == .unary_expression && left_sym != right_sym {
					unary_op_node := right_child.child_by_field_name('operator') or { continue }
					if right_sym.kind == .chan_ {
						right_sym = right_sym.parent_sym
					}

					an.report(unary_op_node, errors.invalid_assignment_error, left_child.text(an.src_text), left_sym, right_sym)
				} else if left_sym != right_sym {
					an.report(node, errors.invalid_assignment_error, left_child.text(an.src_text), left_sym, right_sym)
				}
			}
		}
	}
}

pub fn (mut an SemanticAnalyzer) block(node ast.Node) {
	mut cursor := new_tree_cursor(node)
	mut return_pos_byte := u32(0)
	mut has_return := false

	for got_node in cursor {
		if got_node.type_name == .return_statement {
			return_pos_byte = got_node.start_byte()
			has_return = true
		}

		if an.in_function() && has_return && got_node.start_byte() > return_pos_byte {
			an.report(got_node, errors.unreachable_code_error)
			break
		} else {
			an.statement(got_node)
		}
	}
}

pub fn (mut an SemanticAnalyzer) short_var_declaration(node ast.Node) ? {
	right := node.child_by_field_name('right')?
	right_count := right.named_child_count()
	for i in u32(0) .. right_count {
		right_child := right.named_child(i) or { continue }
		an.expression(right_child, as_value: true) or { continue }
	}
}

pub fn (mut an SemanticAnalyzer) assert_statement(node ast.Node) ? {
	expr_node := node.named_child(0)?
	expr_typ_sym := an.expression(expr_node, as_value: true) or { analyzer.void_sym }
	if expr_typ_sym.name != 'bool' {
		an.report(expr_node, errors.invalid_assert_type_error, expr_typ_sym)
	}
}

pub fn (mut an SemanticAnalyzer) send_statement(node ast.Node) ? {
	chan_node := node.child_by_field_name('channel')?
	val_node := node.child_by_field_name('value')?
	chan_typ_sym := an.expression(chan_node) or { analyzer.void_sym }
	val_typ_sym := an.expression(val_node) or { analyzer.void_sym }
	if chan_typ_sym.kind != .chan_ {
		an.report(chan_node, errors.send_channel_invalid_chan_type_error, chan_typ_sym)
	} else if val_typ_sym != chan_typ_sym.parent_sym {
		an.report(val_node, errors.send_channel_invalid_value_type_error, val_typ_sym, chan_typ_sym)
	}
}

pub fn (mut an SemanticAnalyzer) for_statement(node ast.Node) {
	body_node := node.child_by_field_name('body') or { return }
	an.block(body_node)
}

pub fn (mut an SemanticAnalyzer) break_statement(node ast.Node) {
	mut in_loop := false
	mut in_defer := false
	if parent := parent_by_depth(node, 2) {
		if parent.type_name == .defer_statement {
			in_defer = true
			if defer_parent := parent_by_depth(parent, 2) {
				if defer_parent.type_name == .for_statement {
					in_loop = true
				}
			}
		} else if parent.type_name == .for_statement {
			in_loop = true
		}
	}

	if in_defer {
		an.report(node, errors.defer_break_error)
	} if !in_loop {
		an.report(node, errors.nonloop_break_error)
	}
}

fn parent_by_depth(node ast.Node, depth int) ?ast.Node {
	mut cur_node := node
	for _ in 0 .. depth {
		cur_node = cur_node.parent() or {
			if cur_node == node {
				return err
			}
			return cur_node
		}
	}
	return cur_node
}

pub fn (mut an SemanticAnalyzer) statement(node ast.Node) {
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
		.break_statement {
			an.break_statement(node)
		}
		.for_statement {
			an.for_statement(node)
		}
		.defer_statement {
			an.statement(node.named_child(0) or { return })
		}
		.return_statement {
			an.expression(node.child(0) or { return }) or {}
		}
		.block {
			an.block(node)
		}
		else {
			if _ := an.expression(node) {
				if an.in_function() && node.type_name == .identifier {
					an.report(node, errors.unused_expression_error, node.text(an.src_text))
				}
			}
		}
	}
}

const multiplicative_operators = ["*", "/", "%", "<<", ">>", "&", "&^"]
const additive_operators = ["+", "-", "|", "^"]
const comparative_operators = ["==", "!=", "<", "<=", ">", ">="]
const and_operators = ["&&"]
const or_operators = ["||"]

fn (an &SemanticAnalyzer) convert_to_lit_type(node ast.Node) ?&Symbol {
	node_type := node.type_name
	if node_type == .float_literal || (node_type == .int_literal && node.text(an.src_text).int() < 17) {
		return an.store.find_symbol('', node.raw_node.type_name())
	}
	return none
}

pub fn (mut an SemanticAnalyzer) binary_expression(node ast.Node, cfg SemanticExpressionAnalyzeConfig) ?&Symbol {
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
		} else if op == '%' && ((left_sym.name == 'f32' && right_sym.name == 'f32') || (left_sym.name == 'f64' && right_sym.name == 'f64')) {
			an.report(left_node, errors.float_modulo_error)
		}
	} else if is_comparative && left_sym != right_sym {
		if (left_sym.kind == .optional && left_sym.parent_sym == right_sym) || (right_sym.kind == .optional && right_sym.parent_sym == left_sym) {
			if left_sym.kind == .optional {
				return an.report(left_node, errors.unwrapped_option_binary_expr_error)
			} else if right_sym.kind == .optional {
				return an.report(right_node, errors.unwrapped_option_binary_expr_error)
			}
		}

		return an.report(node, errors.mismatched_type_error, left_sym, right_sym)
	} else if left_sym.name != 'bool' || right_sym.name != 'bool' {
		// check if left and right are both numeric types
		return an.report(node, errors.mismatched_type_error, left_sym, right_sym)
	}
	return left_sym
}

fn (an &SemanticAnalyzer) check_if_type_field_exists(node ast.Node, name string) bool {
	if node.type_name != .literal_value {
		return false
	}

	mut cursor := new_tree_cursor(node)
	for child_node in cursor {
		if child_node.type_name == .keyed_element {
			key_node := child_node.child_by_field_name('name') or { continue }
			if key_node.text(an.src_text) == name {
				return true
			}
		}
	}

	return false
}

pub fn (mut an SemanticAnalyzer) type_initializer(node ast.Node) ?&Symbol {
	type_node := node.child_by_field_name('type')?
	sym_kind, module_name, symbol_name := symbol_name_from_node(type_node, an.src_text)

	match sym_kind {
		.array_, .variadic {
			el_node := type_node.child_by_field_name('element')?
			el_sym := an.store.find_symbol_by_type_node(el_node, an.src_text) or { analyzer.void_sym }
			if el_sym.is_void() || el_sym.kind == .placeholder {
				return an.report(el_node, errors.unknown_type_error, el_node.text(an.src_text))
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
				an.report(key_node, errors.unknown_type_error, key_node.text(an.src_text))
			}

			val_node := type_node.child_by_field_name('value')?
			val_sym := an.store.find_symbol_by_type_node(val_node, an.src_text) or {
				analyzer.void_sym
			}

			if val_sym.is_void() || val_sym.kind == .placeholder {
				an.report(val_node, errors.unknown_type_error, val_node.text(an.src_text))
			}
		}
		.chan_, .ref, .optional {
			el_node := type_node.named_child(0)?
			el_sym := an.store.find_symbol_by_type_node(el_node, an.src_text) or {
				analyzer.void_sym
			}

			if el_sym.is_void() || el_sym.kind == .placeholder {
				an.report(el_node, errors.unknown_type_error, el_node.text(an.src_text))
			}
		}
		.placeholder {
			typ_sym := an.store.find_symbol_by_type_node(type_node, an.src_text)?
			if typ_sym.kind == .typedef && typ_sym.parent_sym.kind == .map_ {
				return an.report(node, errors.typedef_map_init_error, {
					'type_name': typ_sym.gen_str(with_kind: false, with_contents: false, with_access: false)
					'map_type': typ_sym.parent_sym.gen_str()
				})
			}
		}
		else {}
	}

	return an.store.find_symbol(module_name, symbol_name)
}

pub fn (mut an SemanticAnalyzer) selector_expression(node ast.Node) ?&Symbol {
	operand := node.child_by_field_name('operand')?
	mut root_sym := an.expression(operand, as_value: true) or {
		an.store.infer_symbol_from_node(operand, an.src_text) or { analyzer.void_sym }
	}

	if !root_sym.is_void() {
		if root_sym.is_returnable() {
			root_sym = root_sym.return_sym
		}

		field_node := node.child_by_field_name('field')?
		if root_sym.kind == .optional {
			return an.report(field_node, errors.unhandled_optional_selector_error)
		}

		child_name := field_node.text(an.src_text)
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
		mut method_or_field_sym := unsafe { analyzer.void_sym }
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

		if got_child_sym.is_void() && method_or_field_sym.is_void() {
			mut in_call_expr := false
			if parent_node := node.parent() {
				if parent_node.type_name == .call_expression {
					in_call_expr = true
				}
			}

			err_code := if in_call_expr { errors.unknown_method_or_field_error } else { errors.unknown_field_error }
			return an.report(node, err_code, root_sym.gen_str(with_kind: false, with_access: false, with_contents: false), field_node.text(an.src_text))
		}

		return if method_or_field_sym.is_void() {
			got_child_sym
		} else {
			method_or_field_sym
		}
	}

	return root_sym
}

pub fn (mut an SemanticAnalyzer) array(node ast.Node) ?&Symbol {
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

pub fn (mut an SemanticAnalyzer) call_expression(node ast.Node) ?&Symbol {
	fn_node := node.child_by_field_name('function')?
	arguments_node := node.child_by_field_name('arguments')?
	fn_sym := an.expression(fn_node) or { analyzer.void_sym }
	if fn_sym.is_void() {
		if fn_node.type_name == .selector_expression {
			return none
		}

		return an.report(node, errors.unknown_function_error, fn_node.text(an.src_text))
	}

	arguments_count := arguments_node.named_child_count()
	expected_arg_count := fn_sym.children_syms.len
	if arguments_count != expected_arg_count {
		err_code := if expected_arg_count == 1 {
			errors.unexpected_argument_error_single
		} else {
			errors.unexpected_argument_error_plural
		}
		return an.report(node, err_code, expected_arg_count.str(), arguments_count.str())
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

	// NOTE: this opt check is madness but whatever
	if opt_propagator := node.last_node_by_type(v.NodeType.option_propagator) {
		if child_opt_node := opt_propagator.child(0) {
			mut should_unwrap := true
			if child_opt_node.raw_node.type_name() == '?' {
				if an.in_function() && an.parent_sym.name != 'main' && an.parent_sym.return_sym.kind != .optional {
					an.report(child_opt_node, errors.wrong_error_propagation_error, an.parent_sym.name)
					should_unwrap = false
				} else if fn_sym.return_sym.kind != .optional {
					an.report(child_opt_node, errors.invalid_option_propagate_call_error, fn_node.text(an.src_text))
					should_unwrap = false
				}
			}

			if should_unwrap {
				return fn_sym.return_sym.parent_sym
			}
		}
	} else if fn_sym.return_sym.kind == .optional {
		// let parent node handle the error
		mut should_report := true
		if parent := node.parent() {
			if parent.type_name.group() == .expression {
				should_report = false
			}
		}

		if should_report {
			return an.report(node, errors.unhandled_optional_fn_call_error, fn_node.text(an.src_text))
		}
	}

	if fn_sym.is_returnable() {
		return fn_sym.return_sym
	} else {
		return fn_sym
	}
}

pub fn (mut an SemanticAnalyzer) if_expression(node ast.Node, cfg SemanticExpressionAnalyzeConfig) ?&Symbol {
	conseq_node := node.child_by_field_name('consequence')?
	if cond_node := node.child_by_field_name('condition') {
		if cond_node.type_name == .parenthesized_expression {
			an.report(cond_node, errors.unnecessary_if_parenthesis_error)
		}

		cond_sym := an.expression(cond_node, as_value: true) or { analyzer.void_sym }
		if cond_sym.name != 'bool' {
			return an.report(cond_node, errors.if_expr_non_bool_cond_error, cond_sym)
		}

		if cfg.as_value {
			if expected_sym := an.block_expression(conseq_node) {
				else_node := node.child_by_field_name('alternative') or {
					return an.report(node, errors.if_expr_no_else_error)
				}

				if else_sym := an.block_expression(else_node) {
					if else_sym != expected_sym {
						return an.report(node, errors.mismatched_type_error, expected_sym, else_sym)
					}
				}
			} else {
				if err.msg() == 'got_return_statement' || err.msg() == 'empty_expression' {
					return an.report(node, errors.if_no_expression_value_error)
				}
			}
		} else {
			an.block(conseq_node)
		}
	} else if _ := node.child_by_field_name('initializer') {
		// TODO: opt if expr check
		an.block(conseq_node)
	}

	return none
}

pub fn (mut an SemanticAnalyzer) type_cast_expression(node ast.Node) ?&Symbol {
	type_node := node.child_by_field_name('type')?
	operand_node := node.child_by_field_name('operand')?

	type_sym := an.store.find_symbol_by_type_node(type_node, an.src_text) or { analyzer.void_sym }
	operand_sym := an.expression(operand_node, as_value: true) or { analyzer.void_sym }

	if operand_sym.name == 'bool' && type_sym.name == 'string' {
		return an.report(node, errors.bool_string_cast_error, operand_node.text(an.src_text))
	} else if operand_sym.is_void() || operand_sym.kind == .placeholder {
		return an.report(operand_node, errors.void_symbol_casting_error)
	} else if type_sym.kind == .enum_ && operand_node.type_name == .int_literal {
		return an.report(operand_node, errors.invalid_enum_casting_error, operand_node.text(an.src_text).int().str(), type_sym.name)
	}

	return type_sym
}

pub fn (mut an SemanticAnalyzer) spread_operator(node ast.Node) ?&Symbol {
	expr_node := node.named_child(0)?
	expr_sym := an.expression(expr_node, as_value: true)?
	if expr_sym.kind != .array_ {
		return an.report(expr_node, errors.decomposition_error)
	}
	return expr_sym.parent_sym
}

pub fn (mut an SemanticAnalyzer) block_expression(node ast.Node, cfg SemanticExpressionAnalyzeConfig) ?&Symbol {
	child_count := node.named_child_count()
	if child_count == 0 {
		return error('empty_expression')
	}

	last_child := node.named_child(child_count - 1)?

	if cfg.as_value {
		if last_child.type_name.group() != .expression {
			// TODO: this error is for if expression only
			return error('got_return_statement')
		} else {
			return an.expression(last_child, cfg)
		}
	} 

	// TODO:
	return analyzer.void_sym
}

// TODO: tests for match sumtypes is missing
pub fn (mut an SemanticAnalyzer) match_expression(node ast.Node, cfg SemanticExpressionAnalyzeConfig) ?&Symbol {
	cond_node := node.child_by_field_name('condition')?
	cond_sym := an.expression(cond_node)?
	case_count := node.named_child_count()
	mut expected_value_sym := unsafe { analyzer.void_sym }
	mut mismatch_count := 0
	mut expecting_types := false
	mut existing_case_values := []string{cap: int(case_count)}
	mut has_default_case := false

	if cond_sym.kind == .sumtype {
		expecting_types = true
	}

	for i in u32(1) .. case_count {
		case_node := node.named_child(i) or { continue }
		if case_node.type_name !in [.expression_case, .default_case] {
			// TODO:
			break
		} else if case_node.type_name == .expression_case {
			value_list := case_node.child_by_field_name('value') or {
				continue
			}

			case_list_len := value_list.named_child_count()

			for case_value_i in u32(0) .. case_list_len {
				case_value_node := value_list.named_child(case_value_i) or {
					continue
				}

				value_text := case_value_node.text(an.src_text)
				if value_text in existing_case_values {
					an.report(case_value_node, errors.match_duplicate_branch_error, value_text)
				}

				if case_value_node.type_name.group() == .type_ {
					if !cond_sym.children_syms.exists(value_text) {
						an.report(case_value_node, errors.match_invalid_sumtype_variant_error, cond_sym, value_text)
					} else {
						existing_case_values << value_text
					}
				} else if case_value_node.type_name == .range {
					start_node := case_value_node.child_by_field_name('start') or { continue }
					end_node := case_value_node.child_by_field_name('end') or { continue }
					start_sym := an.expression(start_node) or { analyzer.void_sym }
					end_sym := an.expression(end_node) or { analyzer.void_sym }

					if start_sym != cond_sym {
						an.report(start_node, errors.match_range_value_type_mismatch)
					} else if end_sym != end_sym {
						an.report(end_node, errors.match_range_value_type_mismatch)
					} else {
						existing_case_values << value_text 
					}
				} else {
					case_sym := an.expression(case_value_node) or {
						analyzer.void_sym
					}

					if cond_sym != case_sym {
						an.report(case_value_node, errors.match_invalid_case_value_error, cond_sym, case_sym)
					} else {
						existing_case_values << value_text 
					}
				}
			}
		} else if case_node.type_name == .default_case {
			has_default_case = true
		}

		conseq_node := case_node.child_by_field_name('consequence') or {
			continue
		}

		if cfg.as_value {
			if block_sym := an.block_expression(conseq_node, cfg) {
				if i == 1 {
					expected_value_sym = block_sym
				} else if block_sym != expected_value_sym {
					an.report(case_node, errors.match_expr_value_type_mismatch, expected_value_sym)
					mismatch_count++
				}
			} else {
				if err.msg() == 'got_return_statement' || err.msg() == 'empty_expression' {
					an.report(case_node, errors.match_expr_no_expression_value_error)
				}
			}
		} else {
			an.block(conseq_node)
		}
	}

	// check match's exhaustiveness if no default case found
	if expecting_types && !has_default_case {
		missing_types := cond_sym.children_syms.filter(it.name !in existing_case_values).map('`${it.name}`')
		if missing_types.len != 0 {
			return an.report(node, errors.match_sumtype_not_exhaustive_error, missing_types)
		}
	}

	if mismatch_count != 0 {
		return none
	}

	return expected_value_sym
}

[params]
pub struct SemanticExpressionAnalyzeConfig {
	as_value bool
}

pub fn (mut an SemanticAnalyzer) expression(node ast.Node, cfg SemanticExpressionAnalyzeConfig) ?&Symbol {
	match node.type_name {
		.true_, .false_ {
			return an.store.infer_value_type_from_node(node, an.src_text)
		}
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
		.unary_expression {
			// TODO: temporary fix
			return an.store.infer_value_type_from_node(node, an.src_text)
		}
		.int_literal, .float_literal {
			return an.store.infer_value_type_from_node(node, an.src_text)
		}
		.parenthesized_expression {
			return an.expression(node.named_child(0)?, cfg)
		}
		.mutable_expression {
			expr_node := node.named_child(0)?
			got_sym := an.expression(expr_node, cfg)?
			if got_sym.kind == .variable && !got_sym.is_mutable() {
				return an.report(expr_node, errors.immutable_variable_error, got_sym.name)
			} else if got_sym.return_sym.kind == .ref {
				return got_sym.return_sym.parent_sym
			}
			return got_sym.return_sym
		}
		.match_expression {
			return an.match_expression(node, cfg)
		}
		.if_expression {
			return an.if_expression(node, cfg)
		}
		.type_cast_expression {
			return an.type_cast_expression(node)
		}
		.spread_operator {
			return an.spread_operator(node)
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
				if parent := node.parent() {
					// expression_list
					if grandparent := parent.parent() {
						if grandparent.type_name == .assignment_statement && sym.is_const {
							return an.report(node, errors.constant_mutation_error, sym.name)
						}
					}
				}
				return sym.return_sym
			} else {
				return sym
			}

			// return an.report(node, errors.unknown_node_type_error, node.raw_node.type_name())
		}
	}
}

pub fn (mut an SemanticAnalyzer) analyze(node ast.Node) {
	match node.type_name.group() {
		.top_level_declaration {
			an.top_level_statement(node)
		}
		.statement, .simple_statement {
			an.statement(node)
		}
		.expression, .expression_with_blocks {
			an.expression(node) or {}
		}
		else {}
	}
}

pub fn (mut an SemanticAnalyzer) analyze_from_cursor(mut cursor TreeCursor) {
	defer { cursor.reset() }
	for got_node in cursor {
		an.analyze(got_node)
	}
}

// analyze analyzes the given tree
pub fn (mut store Store) analyze(tree &ast.Tree, src_text tree_sitter.SourceText, cfg NewTreeCursorConfig) {
	mut an := SemanticAnalyzer{
		store: unsafe { store }
		src_text: src_text
	}

	mut cursor := new_tree_cursor(tree.root_node(), cfg)
	an.analyze_from_cursor(mut cursor)
}
