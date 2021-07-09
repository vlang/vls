module analyzer

// it should be imported just to have those C type symbols available
// import tree_sitter
// import os

pub enum SymbolKind {
	function
	struct_
	enum_
	typedef
	interface_
	field
	placeholder
	variable
}

pub enum SymbolLanguage {
	c
	js
	v
}

// pub enum Platform {
// 	auto
// 	ios
// 	macos
// 	linux
// 	windows
// 	freebsd
// 	openbsd
// 	netbsd
// 	dragonfly
// 	js
// 	android
// 	solaris
// 	haiku
// 	cross
// }

pub enum SymbolAccess {
	private
	private_mutable
	public
	public_mutable
	global
}

pub enum MessageKind {
	error
	warning
	notice
}

pub struct Message {
pub:
	kind MessageKind = .error
	file_path string
	range C.TSRange
	content string
}

pub struct AnalyzerError {
	msg string
	code int
	range C.TSRange
}

const void_type = &Symbol{ name: 'void' }

[heap]
pub struct Symbol {
pub mut:
	name string
	kind SymbolKind
	access SymbolAccess
	range C.TSRange
	parent &Symbol = analyzer.void_type
	return_type &Symbol = analyzer.void_type
	language SymbolLanguage = .v
	generic_placeholder_len int
	children map[string]&Symbol
	file_path string
}

pub fn (info AnalyzerError) str() string {
	start := '{${info.range.start_point.row}:${info.range.start_point.column}}'
	end := '{${info.range.end_point.row}:${info.range.end_point.column}}'
	return '[${start} -> ${end}] ${info.msg} (${info.code})'
}

pub fn (info &Symbol) str() string {
	typ := if isnil(info.return_type) { 'void' } else { info.return_type.name }
	return '(${info.access} ${info.kind} ${info.name} -> ($typ) ${info.children})'
}

pub fn (infos []&Symbol) str() string {
	return '[' +  infos.map(it.str()).join(', ') + ']'
}

pub fn (mut info Symbol) add_child(mut new_child Symbol) ? {
	if new_child.name in info.children {
		return error('child exists. (name="$new_child.name")')
	}

	new_child.parent = info
	info.children[new_child.name] = new_child
}

[unsafe]
pub fn (sym &Symbol) free() {
	unsafe {
		sym.name.free()
		
		for _, v in sym.children {
			v.free()
		}
	
		sym.children.free()
		sym.file_path.free()
	}
}

pub struct Analyzer {
pub mut:
	cur_file_path string
	cursor   C.TSTreeCursor
	src_text []byte
	store &Store = &Store(0)

	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import bool
}

pub fn (mut an Analyzer) report(msg Message) {
	an.store.report(msg)
}

pub fn (mut an Analyzer) find_symbol_by_node(node C.TSNode) &Symbol {
	if node.is_null() {
		return analyzer.void_type
	}

	mut module_name := ''
	mut symbol_name := ''

	unsafe { symbol_name.free() }
	match node.get_type() {
		'qualified_type' {
			unsafe { module_name.free() }
			module_name = node.child_by_field_name('module').get_text(an.src_text)
			symbol_name = node.child_by_field_name('name').get_text(an.src_text)
		}
		'pointer_type' {
			symbol_name = node.child(1).get_text(an.src_text)
		}
		// 'array_type', 'fixed_array_type' {
			
		// }
		// 'generic_type' {

		// }
		// 'map_type' {}
		// 'channel_type'
		else {
			// type_identifier should go here
			symbol_name = node.get_text(an.src_text)
		}
	}
	
	defer { 
		unsafe {
			module_name.free()
			symbol_name.free()
		}
	}
	return an.store.find_symbol(module_name, symbol_name)
}

pub fn (mut an Analyzer) get_scope(node C.TSNode) &ScopeTree {
	if !node.is_null() && !an.is_import {	
		if node.get_type() == 'source_file' {
			if an.store.cur_file_path !in an.store.opened_scopes {
				an.store.opened_scopes[an.store.cur_file_path] = &ScopeTree{
					start_byte: node.start_byte()
					end_byte: node.end_byte()
				}
			}

			return an.store.opened_scopes[an.store.cur_file_path]
		} else {
			an.store.opened_scopes[an.store.cur_file_path].children << &ScopeTree{
				start_byte: node.start_byte()
				end_byte: node.end_byte()
				parent: an.store.opened_scopes[an.store.cur_file_path]
			}

			return an.store.opened_scopes[an.store.cur_file_path].children.last()
		}
	}
}

fn (mut an Analyzer) move_cursor() bool {
	// NOTE: Do this in the type checking instead.
	// if an.current_node().has_error() && !an.current_node().is_missing() {
	// 	an.report({
	// 		kind: .error
	// 		range: an.current_node().range()
	// 		file_path: an.cur_file_path
	// 		content: 'Node error'
	// 	})
	// }

	return an.cursor.next()
}

fn (mut an Analyzer) next() bool {
	mut rep := 0
	if !an.move_cursor() {
		return false
	}

	for (!an.current_node().is_named() || an.current_node().has_error()) && rep < 5 {
		if !an.move_cursor() {
			return false
		}

		rep++
	}

	return true
}

fn (mut an Analyzer) current_node() C.TSNode {
	return an.cursor.current_node()
}

pub fn (mut an Analyzer) infer_value_type(right C.TSNode) &Symbol {
	if right.is_null() {
		return analyzer.void_type
	}

	node_type := right.get_type()
	// TODO
	mut typ := match node_type {
		'true', 'false' { 'bool' }
		'int_literal' { 'int' }
		'float_literal' { 'f32' }
		'rune_literal' { 'byte' }
		'interpreted_string_literal' { 'string' }
		else { '' }
	}

	return an.store.find_symbol('', typ)
}

fn (mut an Analyzer) extract_parameter_list(node C.TSNode, mut type_symbol Symbol, mut scope ScopeTree) {
	params_len := node.named_child_count()

	for i := u32(0); i < params_len; i++ {
		mut access := SymbolAccess.private
		param_node := node.named_child(i)
		if param_node.child(0).get_type() == 'mut' {
			access = SymbolAccess.private_mutable
		}

		param_name := param_node.child_by_field_name('name')
		param_type_node := param_node.child_by_field_name('type')

		mut param_sym := &Symbol{
			name: param_name.get_text(an.src_text)
			kind: .variable
			range: param_node.range()
			access: access
			return_type: an.find_symbol_by_node(param_type_node)
		}

		type_symbol.add_child(mut param_sym) or { 
			// eprintln(err) 
		}
		scope.register(param_sym)
	}
}

pub fn (mut an Analyzer) extract_block(node C.TSNode, mut scope ScopeTree) {
	if node.get_type() != 'block' || an.is_import {
		return
	}
	
	body_sym_len := node.named_child_count()
	for i := u32(0); i < body_sym_len; i++ {
		an.next()
		if an.current_node().get_type() != 'short_var_declaration' {
			continue
		}

		// TODO: further type checks

		decl_node := node.named_child(i)
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

				right_type := an.infer_value_type(right)
				mut var_sym := &Symbol{
					name: left.get_text(an.src_text)
					kind: .variable
					access: var_access
					range: decl_node.range()
					return_type: right_type
				}

				scope.register(var_sym)
			}
		} else {
			// TODO: if left_len > right_len
			// and right_len < left_len
		}
	}
}

fn report_error(msg string, range C.TSRange) IError {
	return AnalyzerError{
		msg: msg
		code: 0
		range: range
	}
}

pub fn (an Analyzer) new_top_level_symbol(identifier_node C.TSNode, access SymbolAccess) ?&Symbol {
	id_node_type := identifier_node.get_type()
	if id_node_type == 'qualified_type' {
		return report_error('Invalid top-level node type `$id_node_type`', identifier_node.range())
	}

	mut symbol := Symbol{
		access: access
		file_path: an.store.cur_file_path
	}

	match id_node_type {
		'generic_type' {
			if identifier_node.named_child(0).get_type() == 'generic_type' {
				return error('Invalid top-level generic node type `$id_node_type`')
			}

			symbol = an.new_top_level_symbol(identifier_node.named_child(0), access) ?
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

pub fn (mut an Analyzer) unwrap_error(err IError) {
	if err is AnalyzerError {
		an.report({ 
			content: err.msg
			range: err.range
			file_path: an.store.cur_file_path.clone()
		})
	}
}

pub fn (mut an Analyzer) top_level_statement() {
	mut node_type := an.current_node().get_type()
	mut access := SymbolAccess.private
	if node_type == 'source_file' {
		an.cursor.to_first_child()
		node_type = an.current_node().get_type()
	}

	mut global_scope := an.get_scope(an.current_node().parent())
	match node_type {
		'import_declaration' {}
		'const_declaration' {
			const_node := an.current_node()
			if const_node.child(0).get_type() == 'pub' {
				access = .public
			}

			specs_len := const_node.named_child_count()
			for i in 0 .. specs_len {
				spec_node := const_node.named_child(i)
				mut const_sym := &Symbol{	
					name: spec_node.child_by_field_name('name').get_text(an.src_text)
					kind: .variable
					access: access
					range: spec_node.range()
					file_path: an.store.cur_file_path
					return_type: an.infer_value_type(spec_node.child_by_field_name('value'))
				}

				an.store.register_symbol(const_sym) or {
					if err is AnalyzerError {
						// eprintln(err.str())
					} else {
						// eprintln('Unknown error')
					}
				}
				global_scope.register(const_sym)
			}
		}
		'struct_declaration' {
			struct_decl_node := an.current_node()
			if struct_decl_node.child(0).get_type() == 'pub' {
				access = .public
			}
			
			mut sym := an.new_top_level_symbol(struct_decl_node.named_child(0), access) or {
				an.unwrap_error(err)
				return
			}
			sym.kind = .struct_

			decl_list_node := struct_decl_node.named_child(1)
			fields_len := decl_list_node.named_child_count()
			mut scope := an.get_scope(decl_list_node)
			mut field_access := SymbolAccess.private

			for i in 0 .. fields_len {
				field_node := decl_list_node.named_child(i)
				field_type := field_node.get_type()

				match field_type {
					'struct_field_scope' {
						scope_text := field_node.get_text(an.src_text)
						field_access = match scope_text {
							'mut:' { SymbolAccess.private_mutable }
							'pub:' { SymbolAccess.public }
							'pub mut:' { SymbolAccess.public_mutable }
							'__global:' { SymbolAccess.global }
							else { field_access }
						}

						continue
					}
					'struct_field_declaration' {
						field_typ := an.find_symbol_by_node(field_node.child_by_field_name('type'))

						mut field_sym := Symbol{
							name: field_node.child_by_field_name('name').get_text(an.src_text)
							kind: .field
							range: field_node.range()
							access: field_access
							return_type: field_typ
							file_path: an.store.cur_file_path
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

			an.store.register_symbol(sym) or { 
				// eprintln(err) 
			}
		}
		'interface_declaration' {
			interface_decl_node := an.current_node()
			if interface_decl_node.child(0).get_type() == 'pub' {
				access = SymbolAccess.public
			}
			
			mut sym := an.new_top_level_symbol(interface_decl_node.named_child(0), access) or {
				an.unwrap_error(err)
				return
			}
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
						an.extract_parameter_list(param_node, mut sym, mut empty_scope)
					}
					'struct_field_declaration' {
						field_typ := an.find_symbol_by_node(field_node.child_by_field_name('type'))
						mut field_sym := &Symbol{
							name: field_node.child_by_field_name('name').get_text(an.src_text)
							kind: .field
							range: field_node.range()
							access: access
							return_type: field_typ
							file_path: an.store.cur_file_path
						}

						sym.add_child(mut field_sym) or { 
							// eprintln(err)
						}
					}
					else { continue }
				}
			}

			an.store.register_symbol(sym) or { 
				// eprintln(err)
			}
		}
		'enum_declaration' {
			enum_decl_node := an.current_node()
			if enum_decl_node.child(0).get_type() == 'pub' {
				access = SymbolAccess.public
			}

			mut sym := an.new_top_level_symbol(enum_decl_node.named_child(0), access) or {
				an.unwrap_error(err)
				return
			}

			member_list_node := enum_decl_node.named_child(1)
			members_len := member_list_node.named_child_count()

			for i in 0 .. members_len {
				member_node := member_list_node.named_child(i)
				if member_node.get_type() != 'enum_member' {
					continue
				}

				mut member_sym := &Symbol{
					name: member_node.child_by_field_name('name').get_text(an.src_text)
					kind: .field
					range: member_node.range()
					access: access
					// builtin
					return_type: an.store.find_symbol('', 'int')
					file_path: an.store.cur_file_path
				}

				sym.add_child(mut member_sym) or { 
					an.unwrap_error(AnalyzerError{
						msg: err.msg
						range: member_node.range()
					})
					return
				}
			}

			an.store.register_symbol(sym) or { 
				// an.unwrap_error(err)
				return
			}
		}
		'function_declaration' {
			fn_node := an.current_node()
			receiver_node := fn_node.child_by_field_name('receiver')
			params_list_node := fn_node.child_by_field_name('parameters')
			name_node := fn_node.child_by_field_name('name')
			body_node := fn_node.child_by_field_name('body')
			if fn_node.child(0).get_type() == 'pub' {
				access = SymbolAccess.public
			}

			mut scope := an.get_scope(body_node)
			mut fn_sym := an.new_top_level_symbol(name_node, access) or {
				an.unwrap_error(err)
				return
			}

			fn_sym.kind = .function
			fn_sym.return_type = an.find_symbol_by_node(fn_node.child_by_field_name('result'))

			if !receiver_node.is_null() {
				an.extract_parameter_list(params_list_node, mut fn_sym, mut scope)
				keys := fn_sym.children.keys()
				if keys.len != 0 {
					last_param_key := keys.last()
					if !isnil(fn_sym.children[last_param_key].return_type) {
						fn_sym.children[last_param_key].return_type.add_child(mut fn_sym) or { 
							// eprintln(err) 
						}
					}
					unsafe {
						last_param_key.free()
					}
				}
				unsafe {
					keys.free()
				}
			} else {
				an.store.register_symbol(fn_sym) or { 
					// eprintln(err) 
				}
			}

			// scan params
			an.extract_parameter_list(params_list_node, mut fn_sym, mut scope)

			if !body_node.is_null() {
				an.extract_block(body_node, mut scope)
			}
		}
		else {}
	}

	an.next()
}

pub fn (mut an Analyzer) analyze(root_node C.TSNode, src_text []byte, mut store Store) {
	an.store = unsafe { store }
	an.src_text = src_text
	child_len := int(root_node.child_count())
	an.cursor = root_node.tree_cursor()
	for _ in 0 .. child_len {
		an.top_level_statement()
	}
	unsafe { an.cursor.free() }
}

pub fn analyze(tree &C.TSTree, src_text []byte, mut store Store) {
	mut analyzer := analyzer.Analyzer{}
	analyzer.analyze(tree.root_node(), src_text, mut store)
}
