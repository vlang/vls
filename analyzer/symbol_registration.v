module analyzer

const (
	mut_struct_keyword = 'mut:'
	pub_struct_keyword = 'pub:'
	pub_mut_struct_keyword = 'pub mut:'
	global_struct_keyword = '__global:'
)

fn new_top_level_symbol(identifier_node C.TSNode, access SymbolAccess) ?&Symbol {
	id_node_type := identifier_node.get_type()
	if id_node_type == 'qualified_type' {
		return report_error('Invalid top-level node type `$id_node_type`', identifier_node.range())
	}

	mut symbol := Symbol{
		access: access
	}

	match id_node_type {
		'generic_type' {
			if identifier_node.named_child(0).get_type() == 'generic_type' {
				return error('Invalid top-level generic node type `$id_node_type`')
			}

			symbol = new_top_level_symbol(identifier_node.named_child(0), access) ?
			symbol.generic_placeholder_len = int(identifier_node.named_child(1).named_child_count())
		}
		else {
			// type_identifier, binded_type
			symbol.name = identifier_node.get_text(an.src_text)
			symbol.range = identifier_node.range()
			
			if id_node_type == 'binded_type' {
				sym_language := identifier_node.child_by_field_name('language').get_text(an.src_text)
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

	return &symbol
}

struct SymbolRegistration {
mut:
	store &Store = &Store(0)
	cursor C.TSTreeCursor
	src_text []byte

	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import bool
}

fn (mut rs SymbolRegistration) current_node() C.TSNode {
	return rs.cursor.current_node()
}

fn (mut rs SymbolRegistration) const_decl(const_node C.TSNode) []&Symbol {
	mut access := SymbolAccess.private
	if const_node.child(0).get_type() == 'pub' {
		access = .public
	}

	specs_len := const_node.named_child_count()
	mut consts = []Symbol{cap: int(specs_len)}

	for i in 0 .. specs_len {
		spec_node := const_node.named_child(i)
		consts << &Symbol{	
			name: spec_node.child_by_field_name('name').get_text(sr.src_text)
			kind: .variable
			access: access
			range: spec_node.range()
			file_path: sr.store.cur_file_path
			return_type: sr.infer_value_type(spec_node.child_by_field_name('value'))
		}
	}

	return consts
}

fn (mut sr SymbolRegistration) struct_decl(struct_decl_node C.TSNode) ?&Symbol {
	mut access := SymbolAccess.private
	if struct_decl_node.child(0).get_type() == 'pub' {
		access = .public
	}
	
	mut sym := new_top_level_symbol(struct_decl_node.named_child(0), access) ?
	sym.kind = .struct_

	decl_list_node := struct_decl_node.named_child(1)
	fields_len := decl_list_node.named_child_count()

	mut scope := sr.store.get_scope_from_node(decl_list_node) ?
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
				field_typ := sr.find_symbol_by_node(field_node.child_by_field_name('type'))
				mut field_sym := Symbol{
					name: field_node.child_by_field_name('name').get_text(sr.src_text)
					kind: .field
					range: field_node.range()
					access: field_access
					return_type: field_typ
					file_path: sr.store.cur_file_path
				}

				sym.add_child(mut field_sym) or { 
					// eprintln(err)
				}

				scope.register(field_sym)
			}
			else {
				continue
			}
		}
	}

	return sym
}

fn (mut sr SymbolRegistration) interface_decl(interface_decl_node C.TSNode) ?&Symbol {
	mut access := SymbolAccess.private
	if interface_decl_node.child(0).get_type() == 'pub' {
		access = SymbolAccess.public
	}
	
	mut sym := new_top_level_symbol(interface_decl_node.named_child(0), access) ?
	sym.kind = .interface_

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
				mut empty_scope := &ScopeTree(0)
				sr.extract_parameter_list(param_node, mut sym, mut empty_scope)
			}
			'struct_field_declaration' {
				field_typ := sr.find_symbol_by_node(field_node.child_by_field_name('type'))
				mut field_sym := &Symbol{
					name: field_node.child_by_field_name('name').get_text(sr.src_text)
					kind: .field
					range: field_node.range()
					access: access
					return_type: field_typ
					file_path: sr.store.cur_file_path
				}

				sym.add_child(mut field_sym) or { 
					// eprintln(err)
				}
			}
			else { continue }
		}
	}

	return sym
}

fn (mut sr SymbolRegistration) enum_decl(enum_decl_node C.TSNode) ?&Symbol {
	mut access := SymbolAccess.private
	if enum_decl_node.child(0).get_type() == 'pub' {
		access = SymbolAccess.public
	}

	mut sym := sr.new_top_level_symbol(enum_decl_node.named_child(0), access) ?
	sym.kind = .enum_

	member_list_node := enum_decl_node.named_child(1)
	members_len := member_list_node.named_child_count()
	for i in 0 .. members_len {
		member_node := member_list_node.named_child(i)
		if member_node.get_type() != 'enum_member' {
			continue
		}

		mut member_sym := &Symbol{
			name: member_node.child_by_field_name('name').get_text(sr.src_text)
			kind: .field
			range: member_node.range()
			access: access
			// builtin
			return_type: sr.store.find_symbol('', 'int')
			file_path: sr.store.cur_file_path
		}

		sym.add_child(mut member_sym) or { 
			sr.unwrap_error(AnalyzerError{
				msg: err.msg
				range: member_node.range()
			})
			return
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

	mut scope := sr.store.get_scope_from_node(body_node) ?
	mut fn_sym := new_top_level_symbol(name_node, access) ?

	fn_sym.kind = .function
	fn_sym.return_type = sr.find_symbol_by_node(fn_node.child_by_field_name('result'))

	if !receiver_node.is_null() {
		sr.extract_parameter_list(params_list_node, mut fn_sym, mut scope)
		keys := fn_sym.children.keys()
		if keys.len != 0 {
			last_param_key := keys.last()
			if !isnil(fn_sym.children[last_param_key].return_type) {
				fn_sym.children[last_param_key].return_type.add_child(mut fn_sym) or { 
					// eprintln(err) 
				}
			}
			unsafe { last_param_key.free() }
		}
		unsafe { keys.free() }
		return none
	} else {
		return sym
	}

	// scan params
	sr.extract_parameter_list(params_list_node, mut fn_sym, mut scope)

	if !body_node.is_null() {
		sr.extract_block(body_node, mut scope)
	}
}

fn (mut sr SymbolRegistration) top_level_statement() {
	defer { sr.next() }

	mut node_type := sr.current_node().get_type()
	mut access := SymbolAccess.private
	if node_type == 'source_file' {
		sr.cursor.to_first_child()
		node_type = sr.current_node().get_type()
	}

	mut global_scope := sr.get_scope(sr.current_node().parent())
	match node_type {
		'const_declaration' {
			const_syms := sr.const_decl(sr.current_node())
			for i := 0; const_syms.len != 0; {
				mut const_sym := const_syms[i]
				sr.store.register_symbol(const_sym) or {
					// if err is AnalyzerError {
					// 	// eprintln(err.str())
					// } else {
					// 	// eprintln('Unknown error')
					// }
					continue
				}	

				global_scope.register(const_sym)
				const_syms.delete(i)
			}

			unsafe { const_syms.free() }
		}
		'struct_declaration' {
			sym := sr.struct_decl(sr.current_node()) or {
				// eprintln(err)
				return
			}

			sr.store.register_symbol(sym) or { 
				// eprintln(err) 
			}
		}
		'interface_declaration' {
			sym := sr.interface_decl(sr.current_node()) or {
				// eprintln(err)
				return
			}

			sr.store.register_symbol(sym) or { 
				// eprintln(err) 
			}
		}
		'enum_declaration' {
			sym := sr.enum_decl(sr.current_node()) or {
				// eprintln(err)
				return
			}

			sr.store.register_symbol(sym) or { 
				// eprintln(err) 
			}
		}
		'function_declaration' {
			if sym := sr.fn_decl(sr.current_node()) {
				sr.store.register_symbol(sym) or { 
					// eprintln(err) 
				}
			}
		}
		else {}
	}
}

pub fn (mut store Store) register_symbols(tree &C.TSTree, src_text []byte) {
	
}