module analyzer

import os
import tree_sitter as ts
import tree_sitter_v as v
import ast

const (
	mut_struct_keyword     = 'mut:'
	pub_struct_keyword     = 'pub:'
	pub_mut_struct_keyword = 'pub mut:'
	global_struct_keyword  = '__global:'
)

pub struct SymbolAnalyzer {
pub mut:
	context AnalyzerContext
mut:
	module_name string
	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import          bool
	is_script          bool
	is_test            bool
	first_var_decl_pos C.TSRange
}

fn (sr &SymbolAnalyzer) new_top_level_symbol(identifier_node ast.Node, access SymbolAccess, kind SymbolKind) !&Symbol {
	id_node_type_name := identifier_node.type_name
	if id_node_type_name == .qualified_type {
		return report_error('Invalid top-level node type `${id_node_type_name}`', identifier_node.range())
	}

	mut symbol := &Symbol{
		access: access
		kind: kind
		is_top_level: true
		file_path: sr.context.file_path
		file_version: sr.context.file_version
	}

	match id_node_type_name {
		.generic_type {
			type_node := identifier_node.named_child(0) or {
				return report_error('type identifier not found', identifier_node.range())
			}
			if type_node.type_name == .generic_type {
				return report_error('Invalid top-level node type `${id_node_type_name}`',
					identifier_node.range())
			}

			// unsafe { symbol.free() }
			symbol = sr.new_top_level_symbol(type_node, access, kind)!
			parameters_node := identifier_node.named_child(1) or {
				return report_error('type parameters not found', identifier_node.range())
			}
			symbol.generic_placeholder_len = int(parameters_node.named_child_count())
		}
		else {
			// type_identifier, binded_type
			symbol.name = identifier_node.text(sr.context.text)
			symbol.range = identifier_node.range()

			if id_node_type_name in [.binded_type, .binded_identifier] {
				language_node := identifier_node.child_by_field_name('language') or {
					return report_error('no language identifier found', identifier_node.range())
				}
				sym_language := language_node.text(sr.context.text)
				symbol.language = match sym_language {
					'C' { SymbolLanguage.c }
					'JS' { SymbolLanguage.js }
					else { symbol.language }
				}
			}

			next_sibling := identifier_node.next_named_sibling() or {
				return report_error('definition body not found', identifier_node.range())
			}
			if next_sibling.type_name == .type_parameters {
				// for function names with generic parameters
				symbol.generic_placeholder_len = int(next_sibling.named_child_count())
			}
		}
	}

	return symbol
}

[if trace ?]
pub fn (mut sr SymbolAnalyzer) trace_report(report Report) {
	r := Report{
		...report
		file_path: sr.context.file_path
	}
	sr.context.store.report(r)
}

[if trace ?]
pub fn (mut sr SymbolAnalyzer) trace_report_error(err IError) {
	sr.context.store.report_error_with_path(err, sr.context.file_path)
}

fn (mut sr SymbolAnalyzer) get_scope(node ast.Node) !&ScopeTree {
	if sr.is_import {
		return error('Cannot use scope in import or test mode')
	}

	return sr.context.store.get_scope_from_node(sr.context.file_path, node)
}

fn (mut sr SymbolAnalyzer) const_decl(const_node ast.Node) ![]&Symbol {
	mut access := SymbolAccess.private
	child := const_node.child(0) or {
		return report_error('empty const declaration node', const_node.range())
	}
	if child.raw_node.type_name() == 'pub' {
		access = .public
	}

	specs_len := const_node.named_child_count()
	mut consts := []&Symbol{cap: int(specs_len)}

	for i in 0 .. specs_len {
		spec_node := const_node.named_child(i) or { continue }
		// skip comments
		if spec_node.is_extra() {
			continue
		}

		mut return_sym := unsafe { void_sym }
		if value_node := spec_node.child_by_field_name('value') {
			return_syms := sr.expression(value_node)!
			return_sym = return_syms[0]
		}

		name_node := spec_node.child_by_field_name('name') or {
			return report_error('name node not found', spec_node.range())
		}
		consts << &Symbol{
			name: name_node.text(sr.context.text)
			kind: .variable
			access: access
			range: name_node.range()
			is_top_level: true
			is_const: true
			file_path: sr.context.file_path
			file_version: sr.context.file_version
			return_sym: return_sym
		}
	}

	return consts
}

fn (mut sr SymbolAnalyzer) struct_decl(struct_decl_node ast.Node) !&Symbol {
	mut access := SymbolAccess.private
	child_node := struct_decl_node.child(0) or {
		return report_error('empty struct declaration node', struct_decl_node.range())
	}
	if child_node.raw_node.type_name() == 'pub' {
		access = .public
	}

	mut attrs_idx := 1
	if _ := struct_decl_node.child_by_field_name('attributes') {
		attrs_idx = 2
	}

	name_node := struct_decl_node.child_by_field_name('name') or {
		return report_error('name node not found', struct_decl_node.range())
	}
	mut sym := sr.new_top_level_symbol(name_node, access, .struct_)!
	decl_list_node := struct_decl_node.named_child(u32(attrs_idx)) or {
		return report_error('field declaration not found', struct_decl_node.range())
	}
	fields_len := decl_list_node.named_child_count()

	mut field_access := SymbolAccess.private
	for i in 0 .. fields_len {
		field_node := decl_list_node.named_child(i) or {
			sr.trace_report(
				message: 'failed to get field ${i}'
				range: decl_list_node.range()
			)
			continue
		}
		match field_node.type_name {
			.struct_field_scope {
				scope_text := field_node.text(sr.context.text)
				field_access = match scope_text {
					analyzer.mut_struct_keyword { SymbolAccess.private_mutable }
					analyzer.pub_struct_keyword { SymbolAccess.public }
					analyzer.pub_mut_struct_keyword { SymbolAccess.public_mutable }
					analyzer.global_struct_keyword { SymbolAccess.global }
					else { field_access }
				}
				// unsafe { scope_text.free() }
				continue
			}
			.struct_field_declaration {
				mut field_sym := sr.struct_field_decl(field_access, field_node) or { continue }
				sym.add_child(mut field_sym) or { continue }
			}
			else {
				continue
			}
		}
	}

	return sym
}

fn (mut sr SymbolAnalyzer) struct_field_decl(field_access SymbolAccess, field_decl_node ast.Node) ?&Symbol {
	field_type_node := field_decl_node.child_by_field_name('type')?
	field_sym := sr.context.find_symbol_by_type_node(field_type_node) or { void_sym }
	field_name_node := field_decl_node.child_by_field_name('name') or {
		// struct embedding
		_, _, symbol_name := symbol_name_from_node(field_type_node, sr.context.text)
		// defer {
		// 	unsafe { module_name.free() }
		// }

		return &Symbol{
			name: symbol_name
			kind: .embedded_field
			range: field_type_node.range()
			access: field_access
			return_sym: field_sym
			is_top_level: true
			file_path: sr.context.file_path
			file_version: sr.context.file_version
		}
	}

	return &Symbol{
		name: field_name_node.text(sr.context.text)
		kind: .field
		range: field_name_node.range()
		access: field_access
		return_sym: field_sym
		is_top_level: true
		file_path: sr.context.file_path
		file_version: sr.context.file_version
	}
}

fn (mut sr SymbolAnalyzer) interface_decl(interface_decl_node ast.Node) !&Symbol {
	mut access := SymbolAccess.private
	child_node := interface_decl_node.child(0) or {
		return report_error('empty interface declaration node', interface_decl_node.range())
	}
	if child_node.raw_node.type_name() == 'pub' {
		access = SymbolAccess.public
	}

	decl_name_node := interface_decl_node.child_by_field_name('name') or {
		return report_error('name node not found', interface_decl_node.range())
	}
	mut sym := sr.new_top_level_symbol(decl_name_node, access, .interface_)!
	fields_list_node := interface_decl_node.named_child(1) or {
		return report_error('field declaration not found', interface_decl_node.range())
	}
	fields_len := interface_decl_node.named_child_count()

	for i in 0 .. fields_len {
		field_node := fields_list_node.named_child(i) or {
			sr.trace_report(
				message: 'failed to get field ${i}'
				range: fields_list_node.range()
			)
			continue
		}
		match field_node.type_name {
			.interface_field_scope {
				// TODO: add if mut: check
				access = .private_mutable
			}
			.interface_spec {
				param_node := field_node.child_by_field_name('parameters') or { continue }
				name_node := field_node.child_by_field_name('name') or { continue }
				result_node := field_node.child_by_field_name('result') or { continue }
				method_access := if access == .private_mutable {
					SymbolAccess.public_mutable
				} else {
					SymbolAccess.public
				}

				mut method_sym := Symbol{
					name: name_node.text(sr.context.text)
					kind: .function
					access: method_access
					range: name_node.range()
					return_sym: sr.context.find_symbol_by_type_node(result_node) or { void_sym }
					file_path: sr.context.file_path
					file_version: sr.context.file_version
					is_top_level: true
				}

				mut children := extract_parameter_list(mut sr.context, param_node)
				for j := 0; j < children.len; j++ {
					mut child := children[j]
					method_sym.add_child(mut child) or {
						// eprintln(err)
						continue
					}
				}
				// unsafe { children.free() }
				sym.add_child(mut method_sym) or {
					// eprintln(err)
					continue
				}
				sym.interface_children_len++
			}
			.struct_field_declaration {
				mut field_sym := sr.struct_field_decl(access, field_node) or { continue }
				sym.add_child(mut field_sym) or {
					// eprintln(err)
					continue
				}
				sym.interface_children_len++
			}
			else {
				continue
			}
		}
	}

	return sym
}

fn (mut sr SymbolAnalyzer) enum_decl(enum_decl_node ast.Node) !&Symbol {
	mut access := SymbolAccess.private
	child_node := enum_decl_node.child(0) or {
		return report_error('empty enum declaration node', enum_decl_node.range())
	}
	if child_node.raw_node.type_name() == 'pub' {
		access = SymbolAccess.public
	}

	mut attrs_idx := 1
	if _ := enum_decl_node.child_by_field_name('attributes') {
		attrs_idx = 2
	}

	name_node := enum_decl_node.child_by_field_name('name') or {
		return report_error('name node not found', enum_decl_node.range())
	}
	mut sym := sr.new_top_level_symbol(name_node, access, .enum_)!
	member_list_node := enum_decl_node.named_child(u32(attrs_idx)) or {
		return report_error('member declaration not found', enum_decl_node.range())
	}
	members_len := member_list_node.named_child_count()
	for i in 0 .. members_len {
		member_node := member_list_node.named_child(i) or {
			sr.trace_report(
				message: 'failed to get member ${i}'
				range: member_list_node.range()
			)
			continue
		}
		if member_node.type_name != .enum_member {
			continue
		}

		member_name_node := member_node.child_by_field_name('name') or {
			sr.trace_report(
				message: 'name not found in member ${i}'
				range: member_node.range()
			)
			continue
		}
		mut member_sym := &Symbol{
			name: member_name_node.text(sr.context.text)
			kind: .field
			range: member_node.range()
			access: access
			return_sym: sym
			is_top_level: true
			file_path: sr.context.file_path
			file_version: sr.context.file_version
		}

		sym.add_child(mut member_sym) or {
			// sr.context.store.report_error(AnalyzerError{
			// 	message: err.msg()
			// 	range: member_node.range()
			// })
			continue
		}
	}

	return sym
}

fn (mut sr SymbolAnalyzer) fn_decl(fn_node ast.Node) !&Symbol {
	mut access := SymbolAccess.private
	modifier_node := if attr_node := fn_node.child_by_field_name('attributes') {
		attr_node.next_sibling() or {
			return report_error('empty function declaration node', fn_node.range())
		}
	} else {
		fn_node.child(0) or {
			return report_error('empty function declaration node', fn_node.range())
		}
	}
	if modifier_node.raw_node.type_name() == 'pub' {
		access = SymbolAccess.public
	}

	name_node := fn_node.child_by_field_name('name') or {
		return report_error('name node not found', fn_node.range())
	}
	if sr.is_script && fn_node.start_byte() > sr.first_var_decl_pos.end_byte {
		return report_error('in script mode, functions should be declaraed before any other statements',
			name_node.range())
	}

	body_node := fn_node.child_by_field_name('body') or {
		return report_error('functoin body not found', fn_node.range())
	}
	params_list_node := fn_node.child_by_field_name('parameters') or {
		return report_error('parameter list not found', fn_node.range())
	}
	return_node := fn_node.child_by_field_name('result') or {
		unsafe {
			ts.unwrap_null_node[v.NodeType](v.type_factory, err) or { return error('') }
		}
	}

	mut fn_sym := sr.new_top_level_symbol(name_node, access, .function)!
	mut scope := sr.get_scope(body_node) or { &ScopeTree(0) }
	fn_sym.access = access
	fn_sym.return_sym = sr.context.find_symbol_by_type_node(return_node) or { void_sym }
	if receiver_node := fn_node.child_by_field_name('receiver') {
		mut receivers := extract_parameter_list(mut sr.context, receiver_node)
		if receivers.len != 0 {
			mut parent := receivers[0].return_sym
			if !isnil(parent) && !parent.is_void() {
				if parent.kind == .ref {
					parent = parent.parent_sym
				}
				parent.add_child(mut fn_sym) or {}
			}
			fn_sym.parent_sym = receivers[0]
			scope.register(receivers[0]) or {}
		}
		// unsafe { receivers.free() }
	}

	// scan params
	mut params := extract_parameter_list(mut sr.context, params_list_node)
	for i := 0; i < params.len; i++ {
		mut param := params[i]
		fn_sym.add_child(mut param) or { continue }
		scope.register(param) or { continue }
	}

	// extract function body
	if !body_node.is_null() && !sr.is_import {
		sr.extract_block(body_node, mut scope)!
	}

	fn_sym.scope = scope
	fn_sym.docstrings = sr.context.get_docstring(fn_node)
	return fn_sym
}

fn (mut sr SymbolAnalyzer) type_decl(type_decl_node ast.Node) !&Symbol {
	mut access := SymbolAccess.private
	child_node := type_decl_node.child(0) or {
		return report_error('empty type declaration node', type_decl_node.range())
	}
	if child_node.raw_node.type_name() == 'pub' {
		access = SymbolAccess.public
	}

	name_node := type_decl_node.child_by_field_name('name') or {
		return report_error('name node not found', type_decl_node.range())
	}
	mut sym := sr.new_top_level_symbol(name_node, access, .typedef)!
	types_node := type_decl_node.child_by_field_name('types') or {
		return report_error('type list not found on the right hand side', type_decl_node.range())
	}
	types_count := types_node.named_child_count()
	if types_count == 0 {
		return report_error('empty type list', types_node.range())
	} else if types_count == 1 {
		// alias type
		if selected_type_node := types_node.named_child(0) {
			found_sym := sr.context.find_symbol_by_type_node(selected_type_node) or { void_sym }

			sym.parent_sym = found_sym
		}
	} else {
		// sum type
		for i in 0 .. types_count {
			selected_type_node := types_node.named_child(i) or {
				sr.trace_report(
					message: 'failed to get type ${i}'
					range: types_node.range()
				)
				continue
			}
			mut found_sym := sr.context.find_symbol_by_type_node(selected_type_node) or {
				name := selected_type_node.text(sr.context.text)
				sr.trace_report(
					message: 'invalid type ${name}'
					range: selected_type_node.range()
				)
				continue
			}
			sym.add_child(mut found_sym, false) or { continue }
		}
		sym.kind = .sumtype
	}

	return sym
}

fn (mut sr SymbolAnalyzer) top_level_decl(current_node ast.Node) ![]&Symbol {
	mut global_scope := unsafe { sr.context.store.opened_scopes[sr.context.file_path] }
	node_type_name := current_node.type_name
	match node_type_name {
		// TODO: add module check
		// 'module_clause' {
		// 	module_name := os.base(ss.cur_dir)
		// 	defer { unsafe { module_name.free() } }
		// }
		.const_declaration {
			return sr.const_decl(current_node)
			// unsafe { const_syms.free() }
		}
		.enum_declaration {
			sym := sr.enum_decl(current_node)!
			return [sym]
		}
		.function_declaration {
			sym := sr.fn_decl(current_node)!
			return [sym]
		}
		.interface_declaration {
			sym := sr.interface_decl(current_node)!
			return [sym]
		}
		.struct_declaration {
			sym := sr.struct_decl(current_node)!
			return [sym]
		}
		.type_declaration {
			sym := sr.type_decl(current_node)!
			return [sym]
		}
		else {
			stmt_node := current_node
			if node_type_name == .short_var_declaration {
				sr.is_script = true
				sr.first_var_decl_pos = stmt_node.range()

				// Check if main function is present
				if main_fn_sym := sr.context.store.symbols[os.dir(sr.context.file_path)].get('main') {
					return report_error('function `main` is already defined', main_fn_sym.range)
				}
			}

			syms := sr.statement(stmt_node, mut global_scope)!
			if node_type_name == .short_var_declaration {
				return syms
			}

			return []
		}
	}
}

fn (mut sr SymbolAnalyzer) short_var_decl(var_decl ast.Node) ![]&Symbol {
	left_expr_lists := var_decl.child_by_field_name('left') or {
		return report_error('left hand side not found', var_decl.range())
	}
	right_expr_lists := var_decl.child_by_field_name('right') or {
		return report_error('right hand side not found', var_decl.range())
	}
	left_len := left_expr_lists.named_child_count()
	right_len := right_expr_lists.named_child_count()

	mut cur_left := 0
	mut vars := []&Symbol{cap: int(left_len)}

	for i in 0 .. right_len {
		right := right_expr_lists.named_child(i) or {
			return report_error('rhs[${i}] not found', right_expr_lists.range())
		}
		mut right_syms := sr.expression(right)!
		for mr_sym in right_syms {
			vars << sr.register_variable(mr_sym, left_expr_lists, u32(cur_left))!
			cur_left++
		}
	}
	return vars
}

fn (mut sr SymbolAnalyzer) register_variable(sym &Symbol, left_expr_lists ast.Node, left_idx u32) !&Symbol {
	mut var_access := SymbolAccess.private
	mut left := left_expr_lists.named_child(left_idx) or {
		return report_error('lhs[${left_idx}] not found', left_expr_lists.range())
	}
	if left.type_name == .mutable_expression {
		var_access = .private_mutable
		left = left.named_child(0) or {
			return report_error('identifier not found in lhs[${left_idx}]', left_expr_lists.range())
		}
	}

	name := left.text(sr.context.text)
	if sym.is_void() {
		return report_error('invalid type for identifier `${name}`', left_expr_lists.range())
	}

	return &Symbol{
		name: name
		kind: .variable
		access: var_access
		range: left.range()
		return_sym: sym
		is_top_level: false
		file_path: sr.context.file_path
		file_version: sr.context.file_version
	}
}

fn (mut sr SymbolAnalyzer) fn_literal(fn_node ast.Node) !&Symbol {
	body_node := fn_node.child_by_field_name('body') or {
		return report_error('functoin body not found', fn_node.range())
	}
	params_list_node := fn_node.child_by_field_name('parameters') or {
		return report_error('parameter list not found', fn_node.range())
	}

	mut scope := sr.get_scope(body_node) or { &ScopeTree(0) }
	mut params := extract_parameter_list(mut sr.context, params_list_node)
	mut return_sym := unsafe { void_sym }
	if result_node := fn_node.child_by_field_name('result') {
		return_sym = sr.context.find_symbol_by_type_node(result_node) or { void_sym }
	}

	for i := 0; i < params.len; i++ {
		mut param := params[i]
		scope.register(param) or { continue }
	}

	// extract function body
	sr.extract_block(body_node, mut scope)!

	// Do not use infer_symbol_from_node as this function literal may change
	// and we dont want to pollute non-permanent function types
	mut new_sym := &Symbol{
		name: anon_fn_prefix
		file_path: sr.context.file_path
		file_version: sr.context.file_version
		is_top_level: true
		kind: .function_type
		return_sym: return_sym
	}

	for mut param in params {
		new_sym.add_child(mut *param) or { continue }
	}

	return new_sym
}

fn (mut sr SymbolAnalyzer) match_expression(match_node ast.Node) ![]&Symbol {
	mut cond_node := match_node.child_by_field_name('condition') or {
		return report_error('condition node not found', match_node.range())
	}
	if cond_node.type_name == .mutable_expression {
		cond_node = cond_node.named_child(0) or {
			return report_error('empty mutable expression node', cond_node.range())
		}
	}

	cond_value_type := sr.context.infer_value_type_from_node(cond_node)
	if cond_value_type.is_void() {
		return void_sym_arr
	}

	mut expr_value_type := unsafe { void_sym_arr }
	named_child_count := match_node.named_child_count()
	for i in u32(1) .. named_child_count {
		case_node := match_node.named_child(i) or {
			sr.trace_report(
				message: 'failed to get case ${i}'
				range: match_node.range()
			)
			continue
		}
		if case_node.type_name == .expression_case {
			case_list_node := case_node.child_by_field_name('value') or { return void_sym_arr }

			case_list_count := case_list_node.named_child_count()
			for j in u32(0) .. case_list_count {
				value_node := case_list_node.named_child(j) or {
					sr.trace_report(
						message: 'failed to get value ${j} in case'
						range: case_list_node.range()
					)
					continue
				}
				if cond_value_type.kind == .enum_
					&& value_node.type_name == .type_selector_expression {
					field_node := value_node.child_by_field_name('field_name') or {
						sr.trace_report(
							message: 'failed to get enum field name in value ${j}'
							range: value_node.range()
						)
						continue
					}
					if !cond_value_type.children_syms.exists(field_node.text(sr.context.text)) {
						return void_sym_arr
					}
				} else {
					value_node_type := sr.context.store.infer_value_type_from_node(sr.context.file_path,
						value_node, sr.context.text)
					if value_node_type.is_void() || value_node_type != cond_value_type {
						// return void if no type matches
						return void_sym_arr
					}
				}
			}
		}

		conseq_block := case_node.child_by_field_name('consequence') or {
			sr.trace_report(
				message: 'case body not found for case ${i}'
				range: case_node.range()
			)
			continue
		}
		got_block_type := sr.extract_block(conseq_block, mut &ScopeTree(0)) or {
			return void_sym_arr
		}

		if i == 1 {
			expr_value_type = unsafe { got_block_type }
		} else if got_block_type != expr_value_type {
			return void_sym_arr
		}
	}

	return expr_value_type
}

fn (mut sr SymbolAnalyzer) if_expression(if_stmt_node ast.Node) ![]&Symbol {
	body_node := if_stmt_node.child_by_field_name('consequence') or {
		return report_error('expression body not found', if_stmt_node.range())
	}
	mut if_scope := sr.get_scope(body_node) or { &ScopeTree(0) }
	mut has_initializer := false

	if initializer_node := if_stmt_node.child_by_field_name('initializer') {
		mut vars := sr.short_var_decl(initializer_node) or { [] }
		if vars.len != 0 {
			has_initializer = true
		}

		for mut var in vars {
			if var.return_sym.kind == .optional {
				var.return_sym = var.return_sym.final_sym()
				if_scope.register(*var) or {}
			}
		}
	}

	block_return_sym := sr.extract_block(body_node, mut if_scope)!
	mut alt_block_return_sym := unsafe { void_sym_arr }

	if alternative_node := if_stmt_node.child_by_field_name('alternative') {
		if alternative_node.type_name == .block {
			mut else_scope := sr.get_scope(alternative_node) or { &ScopeTree(0) }
			alt_block_return_sym = sr.extract_block(alternative_node, mut else_scope)!
		} else if alternative_node.type_name == .if_expression {
			alt_block_return_sym = sr.if_expression(alternative_node)!
		}

		if !has_initializer && block_return_sym == alt_block_return_sym {
			return block_return_sym
		}
	}

	return void_sym_arr
}

fn (mut sr SymbolAnalyzer) for_statement(for_stmt_node ast.Node) ! {
	named_child_count := for_stmt_node.named_child_count()
	body_node := for_stmt_node.child_by_field_name('body') or {
		return report_error('loop body not found', for_stmt_node.range())
	}
	mut scope := sr.get_scope(body_node) or { &ScopeTree(0) }

	if named_child_count == 2 {
		cond_node := for_stmt_node.named_child(0) or {
			return report_error('empty loop condition node', for_stmt_node.range())
		}
		cond_node_type := cond_node.type_name

		if cond_node_type == .for_in_operator {
			left_node := cond_node.child_by_field_name('left') or {
				return report_error('identifier is missing', cond_node.range())
			}
			right_node := cond_node.child_by_field_name('right') or {
				return report_error('iterator is missing', cond_node.range())
			}
			right_sym := sr.context.infer_symbol_from_node(right_node) or { void_sym }

			if !right_sym.is_void() {
				right_return_sym := if right_sym.is_returnable() {
					right_sym.return_sym
				} else {
					right_sym.value_sym()
				}

				left_count := left_node.named_child_count()
				mut has_idx_variable := false
				if left_count >= 2 {
					has_idx_variable = true
				}

				last_idx := if has_idx_variable { u32(1) } else { u32(0) }

				if right_return_sym.kind == .array_ || right_return_sym.kind == .map_
					|| right_return_sym.name == 'string' {
					if has_idx_variable {
						mut key_sym := sr.context.find_symbol('', 'int') or { void_sym }
						if right_return_sym.kind == .map_ {
							key_sym = right_return_sym.children_syms[0] or {
								sr.context.find_symbol('', 'string') or { void_sym }
							}
						}

						idx_node := left_node.named_child(last_idx - 1) or {
							return report_error('index/key identifier not found', left_node.range())
						}
						mut idx_sym := Symbol{
							name: idx_node.text(sr.context.text)
							kind: .variable
							range: idx_node.range()
							is_top_level: false
							return_sym: key_sym
							file_path: sr.context.file_path
							file_version: sr.context.file_version
						}

						scope.register(idx_sym) or {}
					}

					mut value_node := left_node.named_child(last_idx) or {
						return report_error('value identifier not found', left_node.range())
					}
					mut symbol_access := SymbolAccess.private
					mut return_sym := if right_sym.name == 'string' {
						sr.context.find_symbol('', 'rune') or { void_sym }
					} else {
						right_return_sym.value_sym()
					}

					if value_node.type_name == .mutable_identifier {
						value_node = value_node.named_child(0) or {
							return report_error('mutable identifier not found', value_node.range())
						}
						if right_sym.is_mutable() {
							if return_sym.kind == .ref {
								return_sym = return_sym.parent_sym
							}

							symbol_access = .private_mutable
						}
					}

					mut value_sym := Symbol{
						name: value_node.text(sr.context.text)
						kind: .variable
						range: value_node.range()
						is_top_level: false
						return_sym: return_sym
						access: symbol_access
						file_path: sr.context.file_path
						file_version: sr.context.file_version
					}

					scope.register(value_sym) or {}
				} else if iter_next_method := right_return_sym.children_syms.get('next') {
					// Iterators
					if iter_next_method.return_sym.kind == .optional
						&& !iter_next_method.return_sym.parent_sym.is_void() {
						// TODO: merge code with existing branch
						mut value_node := left_node.named_child(0) or {
							return report_error('value identifier not found', left_node.range())
						}
						// NOTE: can returned iterator values be mutable?
						if value_node.type_name == .mutable_identifier {
							value_node = value_node.named_child(0) or {
								return report_error('mutable identifier not found', value_node.range())
							}
						}

						mut value_sym := Symbol{
							name: value_node.text(sr.context.text)
							kind: .variable
							range: value_node.range()
							is_top_level: false
							return_sym: iter_next_method.return_sym.parent_sym
							file_path: sr.context.file_path
							file_version: sr.context.file_version
						}

						scope.register(value_sym) or {}
					}
				}
			}
		} else if cond_node_type == .cstyle_for_clause {
			initializer_node := cond_node.child_by_field_name('initializer') or {
				return report_error('initializer not found', cond_node.range())
			}
			if vars := sr.short_var_decl(initializer_node) {
				for var in vars {
					sym := &Symbol{
						...(*var)
						access: .private_mutable
					}
					scope.register(sym) or { continue }
				}
			}
		}
	}

	sr.extract_block(body_node, mut scope)!
}

// NOTE: make array of symbols return a multi-return instead (?)
fn (mut sr SymbolAnalyzer) expression(node ast.Node) ![]&Symbol {
	match node.type_name {
		.if_expression {
			return sr.if_expression(node)
		}
		.match_expression {
			return sr.match_expression(node)
		}
		.unsafe_expression {
			block_node := node.named_child(0) or {
				return report_error('statement body not found', node.range())
			}
			mut local_scope := sr.get_scope(block_node) or { &ScopeTree(0) }
			block_return_sym := sr.extract_block(block_node, mut local_scope)!
			if node.type_name == .unsafe_expression {
				return block_return_sym
			}
		}
		.fn_literal {
			return [sr.fn_literal(node) or { void_sym }]
		}
		.call_expression {
			return_sym := sr.context.infer_value_type_from_node(node)
			if opt_propagator := node.last_node_by_type(v.NodeType.option_propagator) {
				if or_block_node := opt_propagator.last_node_by_type(v.NodeType.or_block) {
					block_node := or_block_node.last_node_by_type(v.NodeType.block) or {
						return report_error('or block body not found', or_block_node.range())
					}
					mut or_scope := sr.get_scope(block_node)!
					or_scope.register(&Symbol{
						name: 'err'
						kind: .variable
						access: .private
						return_sym: sr.context.find_symbol('', 'IError') or { void_sym }
						is_top_level: false
						range: C.TSRange{
							start_point: block_node.start_point()
							end_point: block_node.start_point()
							start_byte: block_node.start_byte()
							end_byte: block_node.start_byte()
						}
						file_path: sr.context.file_path
						file_version: sr.context.file_version
					})!
				}
			}

			if return_sym.kind == .multi_return {
				return return_sym.children_syms
			} else {
				return [return_sym]
			}
		}
		else {
			// TODO: anything with block
			return [sr.context.infer_value_type_from_node(node)]
		}
	}
	return void_sym_arr
}

fn (mut sr SymbolAnalyzer) statement(node ast.Node, mut scope ScopeTree) ![]&Symbol {
	match node.type_name {
		.defer_statement {
			block_node := node.named_child(0) or {
				return report_error('statement body not found', node.range())
			}
			mut local_scope := sr.get_scope(block_node) or { &ScopeTree(0) }
			sr.extract_block(block_node, mut local_scope)!
		}
		.short_var_declaration {
			vars := sr.short_var_decl(node)!
			for var in vars {
				scope.register(var) or { continue }
			}
			return vars
		}
		.for_statement {
			sr.for_statement(node)!
		}
		.block {
			mut local_scope := sr.get_scope(node) or { &ScopeTree(0) }
			sr.extract_block(node, mut local_scope)!
		}
		else {
			return sr.expression(node)
		}
	}
	return void_sym_arr
}

fn (mut sr SymbolAnalyzer) extract_block(node ast.Node, mut scope ScopeTree) ![]&Symbol {
	if node.type_name != .block {
		return report_error('expected a `block` node', node.range())
	} else if sr.is_import {
		return error('cannot be used in `is_import` mode')
	}

	body_sym_len := node.named_child_count()
	mut return_syms := [void_sym]
	for i := u32(0); i < body_sym_len; i++ {
		stmt_node := node.named_child(i) or {
			sr.trace_report(
				message: 'failed to get child ${i} in block'
				range: node.range()
			)
			continue
		}
		if stmt_node.type_name == .expression_list && i == body_sym_len - 1 {
			list_len := stmt_node.named_child_count()
			if list_len != 0 {
				return_syms.clear()
				return_syms.grow_cap(int(list_len) - return_syms.len)
			}
			for j in u32(0) .. list_len {
				expr_node := stmt_node.named_child(j) or {
					sr.trace_report(
						message: 'failed to get child ${j} in statement'
						range: stmt_node.range()
					)
					continue
				}
				return_syms << sr.expression(expr_node) or { void_sym_arr }
			}
		} else {
			got_return_sym := sr.statement(stmt_node, mut scope) or {
				sr.trace_report_error(err)
				continue
			}
			if i == body_sym_len - 1 {
				return_syms[0] = got_return_sym[0]
			}
		}
	}

	return return_syms
}

fn extract_parameter_list(mut ctx AnalyzerContext, node ast.Node) []&Symbol {
	params_len := node.named_child_count()
	mut syms := []&Symbol{cap: int(params_len)}

	for i := u32(0); i < params_len; i++ {
		mut access := SymbolAccess.private
		param_node := node.named_child(i) or {
			ctx.trace_report(
				message: 'failed to get param ${i}'
				range: node.range()
			)
			continue
		}
		mut param_name_node := param_node.child_by_field_name('name') or {
			ctx.trace_report(
				message: 'name node not found'
				range: param_node.range()
			)
			continue
		}
		param_type_node := param_node.child_by_field_name('type') or {
			ctx.trace_report(
				message: 'type node not found'
				range: param_node.range()
			)
			continue
		}
		return_sym := ctx.find_symbol_by_type_node(param_type_node) or { void_sym }
		if param_name_node.type_name == .mutable_identifier {
			access = SymbolAccess.private_mutable
			param_name_node = param_name_node.named_child(0) or { param_name_node }
		}

		syms << &Symbol{
			name: param_name_node.text(ctx.text)
			kind: .variable
			range: param_name_node.range()
			access: access
			return_sym: return_sym
			is_top_level: false
			file_path: ctx.file_path
			file_version: ctx.file_version
		}
	}

	return syms
}

// analyze scans and returns a list of symbols and messages (errors/warnings)
pub fn (mut sr SymbolAnalyzer) analyze(node ast.Node) ![]&Symbol {
	match node.type_name.group() {
		.top_level_declaration {
			return sr.top_level_decl(node)
		}
		.statement, .simple_statement {
			return sr.statement(node, mut sr.get_scope(node)!)
		}
		.expression, .expression_with_blocks {
			return sr.expression(node)
		}
		else {
			// return report_error('unsupported node type: `${node.type_name}`', node.range())
			return error('')
		}
	}
}

pub fn (mut sr SymbolAnalyzer) analyze_from_cursor(mut cursor TreeCursor) []&Symbol {
	defer {
		cursor.reset()
	}
	if cur_node := cursor.current_node() {
		sr.get_scope(cur_node) or {}
	}

	mut global_scope := unsafe { sr.context.store.opened_scopes[sr.context.file_path] }
	mut symbols := []&Symbol{cap: 255}
	for got_node in cursor {
		mut syms := sr.analyze(got_node) or {
			sr.trace_report_error(err)
			continue
		}
		for i, mut sym in syms {
			if sym.kind == .function && !sym.parent_sym.is_void() {
				continue
			}

			sr.context.store.register_symbol(mut *sym) or {
				// add error message
				continue
			}

			if sym.kind == .variable {
				global_scope.register(*sym) or { continue }
			}

			symbols << syms[i]
		}
	}
	return symbols
}

// register_symbols_from_tree scans and registers all the symbols based on the given tree
pub fn (mut store Store) register_symbols_from_tree(context AnalyzerContext, tree &ast.Tree, is_import bool, cfg NewTreeCursorConfig) {
	mut sr := new_symbol_analyzer(context, is_import)
	mut cursor := new_tree_cursor(tree.root_node(), cfg)
	sr.analyze_from_cursor(mut cursor)
}

// new_symbol_analyzer creates an instance of SymbolAnalyzer with the given store, tree, source, and is_import.
pub fn new_symbol_analyzer(context AnalyzerContext, is_import bool) SymbolAnalyzer {
	return SymbolAnalyzer{
		context: context
		is_import: is_import
	}
}
