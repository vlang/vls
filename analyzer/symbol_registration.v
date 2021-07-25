module analyzer

const (
	mut_struct_keyword     = 'mut:'
	pub_struct_keyword     = 'pub:'
	pub_mut_struct_keyword = 'pub mut:'
	global_struct_keyword  = '__global:'
)

struct SymbolRegistration {
mut:
	store    &Store = &Store(0)
	cursor   TreeCursor
	src_text []byte
	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import bool
}

fn (sr &SymbolRegistration) new_top_level_symbol(identifier_node C.TSNode, access SymbolAccess, kind SymbolKind) ?&Symbol {
	id_node_type := identifier_node.get_type()
	if id_node_type == 'qualified_type' {
		return report_error('Invalid top-level node type `$id_node_type`', identifier_node.range())
	}

	mut symbol := &Symbol{
		access: access
		kind: kind
		file_path: sr.store.cur_file_path.clone()
		file_version: sr.store.cur_version
	}

	match id_node_type {
		'generic_type' {
			if identifier_node.named_child(0).get_type() == 'generic_type' {
				return error('Invalid top-level generic node type `$id_node_type`')
			}

			unsafe { symbol.free() }
			symbol = sr.new_top_level_symbol(identifier_node.named_child(0), access, kind) ?
			symbol.generic_placeholder_len = int(identifier_node.named_child(1).named_child_count())
		}
		else {
			// type_identifier, binded_type
			symbol.name = identifier_node.get_text(sr.src_text)
			symbol.range = identifier_node.range()

			if id_node_type == 'binded_type' {
				sym_language := identifier_node.child_by_field_name('language').get_text(sr.src_text)
				symbol.language = match sym_language {
					'C' { SymbolLanguage.c }
					'JS' { SymbolLanguage.js }
					else { symbol.language }
				}
			}

			// for function names with generic parameters
			if identifier_node.next_named_sibling().get_type() == 'type_parameters' {
				symbol.generic_placeholder_len = int(identifier_node.next_named_sibling().named_child_count())
			}
		}
	}

	return symbol
}

fn (mut sr SymbolRegistration) get_scope(node C.TSNode) ?&ScopeTree {
	if sr.is_import {
		return error('Cannot use scope in import mode')
	}

	return sr.store.get_scope_from_node(node)
}

fn (mut sr SymbolRegistration) const_decl(const_node C.TSNode) ?[]&Symbol {
	mut access := SymbolAccess.private
	if const_node.child(0).get_type() == 'pub' {
		access = .public
	}

	specs_len := const_node.named_child_count()
	mut consts := []&Symbol{cap: int(specs_len)}

	for i in 0 .. specs_len {
		spec_node := const_node.named_child(i)
		// skip comments
		if spec_node.is_extra() {
			continue
		}

		consts << &Symbol{
			name: spec_node.child_by_field_name('name').get_text(sr.src_text)
			kind: .variable
			access: access
			range: spec_node.range()
			file_path: sr.store.cur_file_path.clone()
			file_version: sr.store.cur_version
			return_type: sr.store.infer_value_type_from_node(spec_node.child_by_field_name('value'),
				sr.src_text)
		}
	}

	return consts
}

fn (mut sr SymbolRegistration) struct_decl(struct_decl_node C.TSNode) ?&Symbol {
	mut access := SymbolAccess.private
	if struct_decl_node.child(0).get_type() == 'pub' {
		access = .public
	}

	mut sym := sr.new_top_level_symbol(struct_decl_node.child_by_field_name('name'), access, .struct_) ?
	decl_list_node := struct_decl_node.named_child(1)
	fields_len := decl_list_node.named_child_count()

	mut field_access := SymbolAccess.private
	for i in 0 .. fields_len {
		field_node := decl_list_node.named_child(i)
		field_type := field_node.get_type()
		match field_type {
			'struct_field_scope' {
				scope_text := field_node.get_text(sr.src_text)
				field_access = match scope_text {
					analyzer.mut_struct_keyword { SymbolAccess.private_mutable }
					analyzer.pub_struct_keyword { SymbolAccess.public }
					analyzer.pub_mut_struct_keyword { SymbolAccess.public_mutable }
					analyzer.global_struct_keyword { SymbolAccess.global }
					else { field_access }
				}
				unsafe { scope_text.free() }
				continue
			}
			'struct_field_declaration' {
				mut field_sym := sr.struct_field_decl(field_access, field_node)
				sym.add_child(mut field_sym) or {
					// eprintln(err)
					continue
				}
			}
			else {
				continue
			}
		}
	}

	return sym
}

fn (mut sr SymbolRegistration) struct_field_decl(field_access SymbolAccess, field_decl_node C.TSNode) &Symbol {
	field_typ := sr.store.find_symbol_by_type_node(field_decl_node.child_by_field_name('type'), sr.src_text) or { analyzer.void_type }
	field_name_node := field_decl_node.child_by_field_name('name')
	return &Symbol{
		name: field_name_node.get_text(sr.src_text)
		kind: .field
		range: field_name_node.range()
		access: field_access
		return_type: field_typ
		file_path: sr.store.cur_file_path.clone()
		file_version: sr.store.cur_version
	}
}

fn (mut sr SymbolRegistration) interface_decl(interface_decl_node C.TSNode) ?&Symbol {
	mut access := SymbolAccess.private
	if interface_decl_node.child(0).get_type() == 'pub' {
		access = SymbolAccess.public
	}

	mut sym := sr.new_top_level_symbol(interface_decl_node.child_by_field_name('name'), access, .interface_) ?
	fields_list_node := interface_decl_node.named_child(1)
	fields_len := interface_decl_node.named_child_count()

	for i in 0 .. fields_len {
		field_node := fields_list_node.named_child(i)
		if field_node.is_null() {
			continue
		}

		match field_node.get_type() {
			'interface_field_scope' {
				// TODO: add if mut: check
				access = .private_mutable
			}
			'interface_spec' {
				param_node := field_node.child_by_field_name('parameters')
				mut children := extract_parameter_list(param_node, mut sr.store, sr.src_text)
				for j := 0; j < children.len; j++ {
					mut child := children[j]
					sym.add_child(mut child) or {
						// eprintln(err)
						continue
					}
				}
				unsafe { children.free() }
			}
			'struct_field_declaration' {
				mut field_sym := sr.struct_field_decl(access, field_node)
				sym.add_child(mut field_sym) or {
					// eprintln(err)
					continue
				}
			}
			else {
				continue
			}
		}
	}

	return sym
}

fn (mut sr SymbolRegistration) enum_decl(enum_decl_node C.TSNode) ?&Symbol {
	mut access := SymbolAccess.private
	if enum_decl_node.child(0).get_type() == 'pub' {
		access = SymbolAccess.public
	}

	mut sym := sr.new_top_level_symbol(enum_decl_node.child_by_field_name('name'), access, .enum_) ?
	member_list_node := enum_decl_node.named_child(1)
	members_len := member_list_node.named_child_count()
	for i in 0 .. members_len {
		member_node := member_list_node.named_child(i)
		if member_node.get_type() != 'enum_member' {
			continue
		}

		int_type := sr.store.find_symbol('', 'int') or {
			mut new_int_symbol := Symbol{name: 'int', kind: .typedef }
			sr.store.register_symbol(mut new_int_symbol) or { analyzer.void_type }
		}

		mut member_sym := &Symbol{
			name: member_node.child_by_field_name('name').get_text(sr.src_text)
			kind: .field
			range: member_node.range()
			access: access
			return_type: int_type
			file_path: sr.store.cur_file_path.clone()
			file_version: sr.store.cur_version
		}

		sym.add_child(mut member_sym) or {
			sr.store.report_error(AnalyzerError{
				msg: err.msg
				range: member_node.range()
			})
			continue
		}
	}

	return sym
}

fn (mut sr SymbolRegistration) fn_decl(fn_node C.TSNode) ?&Symbol {
	mut access := SymbolAccess.private
	if fn_node.child(0).get_type() == 'pub' {
		access = SymbolAccess.public
	}

	receiver_node := fn_node.child_by_field_name('receiver')
	params_list_node := fn_node.child_by_field_name('parameters')
	name_node := fn_node.child_by_field_name('name')
	body_node := fn_node.child_by_field_name('body')

	mut fn_sym := sr.new_top_level_symbol(name_node, access, .function) ?
	mut scope := sr.get_scope(body_node) or { &ScopeTree(0) }
	fn_sym.return_type = sr.store.find_symbol_by_type_node(fn_node.child_by_field_name('result'), sr.src_text) or { analyzer.void_type }

	mut is_method := false
	if !receiver_node.is_null() {
		is_method = true
		mut children := extract_parameter_list(receiver_node, mut sr.store, sr.src_text)
		// just use a loop for convinience
		for i := 0; i < children.len; i++ {
			mut parent := children[i].return_type
			if !isnil(parent) && !parent.is_void() {
				// eprintln('adding ${fn_sym.name} to ${parent.kind} ${parent.gen_str()} ${parent.is_void()}')
				parent.add_child(mut fn_sym) or {
					break
				}

				if parent.range.start_byte == 0 && parent.range.end_byte == 0 && !parent.range.eq(fn_sym.range) {
					parent.file_path = fn_sym.file_path
					parent.range = fn_sym.range
				}
			}
			scope.register(children[i])
		}

		unsafe { children.free() }
	}

	// scan params
	mut params := extract_parameter_list(params_list_node, mut sr.store, sr.src_text)
	for i := 0; i < params.len; i++ {
		mut param := params[i]
		fn_sym.add_child(mut param) or { continue }
		scope.register(param)
	}

	unsafe { params.free() }

	// extract function body
	if !body_node.is_null() && !sr.is_import {
		sr.extract_block(body_node, mut scope) ?
	}

	if is_method {
		return none
	} else {
		return fn_sym
	}
}

fn (mut sr SymbolRegistration) type_decl(type_decl_node C.TSNode) ?&Symbol {
	mut access := SymbolAccess.private
	if type_decl_node.child(0).get_type() == 'pub' {
		access = SymbolAccess.public
	}

	mut sym := sr.new_top_level_symbol(type_decl_node.child_by_field_name('name'), access, .typedef) ?
	types_node :=  type_decl_node.child_by_field_name('types')
	if types_node.is_null() {
		return none
	}

	types_count := types_node.named_child_count()
	if types_count == 0 {
		return none
	} else if types_count == 1 {
		// alias type
		selected_type_node := types_node.named_child(0)
		found_sym := sr.store.find_symbol_by_type_node(selected_type_node, sr.src_text) or { analyzer.void_type }
		sym.parent = found_sym
	} else {
		// sum type
		for i in 0 .. types_count {
			selected_type_node := types_node.named_child(i)
			mut found_sym := sr.store.find_symbol_by_type_node(selected_type_node, sr.src_text) or {
				continue
			}
			sym.add_child(mut found_sym, false) or {
				continue
			}
			sym.sumtype_children_len++
		}
		sym.kind = .sumtype
	}

	return sym
}

fn (mut sr SymbolRegistration) top_level_statement() ? {
	defer {
		sr.cursor.next()
	}

	mut node_type := sr.cursor.current_node().get_type()
	if node_type == 'source_file' {
		sr.cursor.to_first_child()
		node_type = sr.cursor.current_node().get_type()
	}

	mut global_scope := sr.get_scope(sr.cursor.current_node().parent()) or { &ScopeTree(0) }
	match node_type {
		'const_declaration' {
			mut const_syms := sr.const_decl(sr.cursor.current_node()) ?
			for i := 0; i < const_syms.len; i++ {
				mut const_sym := const_syms[i]
				sr.store.register_symbol(mut const_sym) or {
					// if err is AnalyzerError {
					// 	// eprintln(err.str())
					// } else {
					// 	// eprintln('Unknown error')
					// }
					continue
				}

				global_scope.register(const_sym)
			}

			unsafe { const_syms.free() }
		}
		'struct_declaration' {
			mut sym := sr.struct_decl(sr.cursor.current_node()) ?
			sr.store.register_symbol(mut sym) ?
		}
		'interface_declaration' {
			mut sym := sr.interface_decl(sr.cursor.current_node()) ?
			sr.store.register_symbol(mut sym) ?
		}
		'enum_declaration' {
			mut sym := sr.enum_decl(sr.cursor.current_node()) ?
			sr.store.register_symbol(mut sym) ?
		}
		'function_declaration' {
			mut sym := sr.fn_decl(sr.cursor.current_node()) ?
			sr.store.register_symbol(mut sym) ?
		}
		'type_declaration' {
			mut sym := sr.type_decl(sr.cursor.current_node()) ?
			sr.store.register_symbol(mut sym) ?
		}
		else {}
	}
}

fn (mut sr SymbolRegistration) extract_block(node C.TSNode, mut scope ScopeTree) ? {
	if node.get_type() != 'block' || sr.is_import {
		return error('node should be a `block` and cannot be used in `is_import` mode.')
	}

	body_sym_len := node.named_child_count()

	for i := u32(0); i < body_sym_len; i++ {
		decl_node := node.named_child(i)
		if decl_node.get_type() != 'short_var_declaration' {
			continue
		}

		// TODO: further type checks

		left_expr_lists := decl_node.child_by_field_name('left')
		right_expr_lists := decl_node.child_by_field_name('right')
		left_len := left_expr_lists.named_child_count()
		right_len := right_expr_lists.named_child_count()

		if left_len == right_len {
			for j in 0 .. left_len {
				mut var_access := SymbolAccess.private

				left := left_expr_lists.named_child(j)
				right := right_expr_lists.named_child(j)

				prev_left := left.prev_sibling()
				if !prev_left.is_null() && prev_left.get_type() == 'mut' {
					var_access = .private_mutable
				}

				right_type := sr.store.infer_value_type_from_node(right, sr.src_text)
				var := &Symbol{
					name: left.get_text(sr.src_text)
					kind: .variable
					access: var_access
					range: left.range()
					return_type: right_type
					file_path: sr.store.cur_file_path.clone()
					file_version: sr.store.cur_version
				}

				scope.register(var)
			}
		} else {
			// TODO: if left_len > right_len
			// and right_len < left_len
		}
	}
}

fn extract_parameter_list(node C.TSNode, mut store Store, src_text []byte) []&Symbol {
	params_len := node.named_child_count()
	mut syms := []&Symbol{cap: int(params_len)}

	for i := u32(0); i < params_len; i++ {
		mut access := SymbolAccess.private
		param_node := node.named_child(i)
		if param_node.child(0).get_type() == 'mut' {
			access = SymbolAccess.private_mutable
		}

		param_name_node := param_node.child_by_field_name('name')
		param_type_node := param_node.child_by_field_name('type')
		return_type := store.find_symbol_by_type_node(param_type_node, src_text) or { analyzer.void_type }
		syms << &Symbol{
			name: param_name_node.get_text(src_text)
			kind: .variable
			range: param_name_node.range()
			access: access
			return_type: return_type
			file_path: store.cur_file_path.clone()
			file_version: store.cur_version
		}
	}

	return syms
}

// register_symbols_from_tree scans and registers all the symbols based on the given tree
pub fn (mut store Store) register_symbols_from_tree(tree &C.TSTree, src_text []byte) {
	root_node := tree.root_node()
	child_len := int(root_node.named_child_count())

	mut sr := SymbolRegistration{
		store: unsafe { store }
		src_text: src_text
		cursor: TreeCursor{root_node.tree_cursor()}
	}
	 
	for _ in 0 .. child_len {
		sr.top_level_statement() or {
			sr.store.report_error(err)
			continue
		}
	}
	unsafe { sr.cursor.free() }
}
