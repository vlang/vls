module analyzer

// it should be imported just to have those C type symbols available
// import tree_sitter
import os

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

pub enum SymbolAccess {
	private
	private_mutable
	public
	public_mutable
	global
}

pub struct ScopeTree {
mut:
	parent &ScopeTree = &ScopeTree(0)
	start_byte u32
	end_byte u32
	symbols map[string]&TypeSymbol
	children []&ScopeTree
}

pub fn (scope &ScopeTree) contains(pos u32) bool {
	return pos >= scope.start_byte && pos <= scope.end_byte
}

pub fn (scope &ScopeTree) innermost(pos u32) &ScopeTree {
	for child_scope in scope.children {
		if child_scope.contains(pos) {
			return child_scope.innermost(pos)
		}
	}

	return unsafe { scope }
}

pub fn (mut scope ScopeTree) register(info &TypeSymbol) {
	// Just to ensure that scope is not null
	if isnil(scope) {
		return
	}

	scope.symbols[info.name] = info
}

pub enum MessageKind {
	error
	warning
	notice
}

pub struct Message {
pub:
	kind MessageKind
	file_path string
	range C.TSRange
	content string
}

struct Import {
mut:
	resolved bool
pub mut:
	module_name string
	path string
	// TODO: find a way to selectively import stuff
	aliases []string
}

pub struct Store {
pub mut:
	cur_file_path string
	imports map[string][]Import
	imported_paths []string
	messages []Message
	symbols map[string]map[string]&TypeSymbol
	opened_scopes map[string]&ScopeTree
}

pub fn (ss &Store) is_file_active(file_path string) bool {
	return ss.cur_file_path == file_path
}

pub fn (mut ss Store) set_active_file_path(file_path string) {
	if ss.is_file_active(file_path) {
		return
	}

	unsafe { ss.cur_file_path.free() }
	ss.cur_file_path = file_path
}

pub fn (mut ss Store) get_module_path(module_name string) string {
	dir := os.dir(ss.cur_file_path)
	import_lists := ss.imports[dir]
	for imp in import_lists {
		if imp.module_name == module_name || module_name in imp.aliases {
			unsafe { dir.free() } 
			return imp.path
		}
	}

	// empty names should return the dir instead
	return dir
}

pub fn (mut ss Store) find_symbol(module_name string, name string) &TypeSymbol {
	if name.len == 0 {
		return &TypeSymbol(0)
	}

	module_path := ss.get_module_path(module_name)
	defer { unsafe { module_path.free() } }

	typ := ss.symbols[module_path][name] or {
		ss.register_symbol(&TypeSymbol{
			name: name.clone()
			kind: .placeholder
		}) or { 
			&TypeSymbol(0)
		}
	}

	return typ
}

pub fn (mut ss Store) register_symbol(info &TypeSymbol) ?&TypeSymbol {
	dir := os.dir(info.file_path)
	defer {
		unsafe { dir.free() }
	}

	if info.name in ss.symbols[dir] {
		return error('Symbol already exists. (name="${info.name}")')
	}

	ss.symbols[dir][info.name] = info
	return info
}

pub fn (mut ss Store) add_import(imp Import) {
	mut idx := -1

	dir := os.dir(ss.cur_file_path)
	defer { unsafe { dir.free() } }
	if dir in ss.imports {
		// check if import has already imported
		for i, stored_imp in ss.imports[dir] {
			if stored_imp.module_name == imp.module_name && stored_imp.path == imp.path {
				idx = i
				break
			}
		}
	} else {
		ss.imports[dir] = []Import{}
	}

	if idx == -1 {
		mut new_import := Import{ ...imp }
		if new_import.path.len != 0 && !new_import.resolved {
			new_import.resolved = true
		}
		
		ss.imports[dir] << new_import 

		if imp.path !in ss.imported_paths {
			ss.imported_paths << new_import.path
		}
	}
}

[heap]
struct TypeSymbol {
pub mut:
	name string
	kind SymbolKind
	access SymbolAccess
	range C.TSRange
	parent &TypeSymbol = &TypeSymbol(0)
	return_type &TypeSymbol = &TypeSymbol(0)
	children map[string]&TypeSymbol
	file_path string
}

pub fn (info &TypeSymbol) str() string {
	typ := if isnil(info.return_type) { 'void' } else { info.return_type.name }
	return '(${info.access} ${info.kind} ${info.name} -> ($typ) ${info.children})'
}

pub fn (infos []&TypeSymbol) str() string {
	return '[' +  infos.map(it.str()).join(', ') + ']'
}

pub fn (mut info TypeSymbol) add_child(mut new_child TypeSymbol) ? {
	if new_child.name in info.children {
		return error('child exists.')
	}

	new_child.parent = info
	info.children[new_child.name] = new_child
}

pub struct Analyzer {
pub mut:
	cur_file_path string
	cursor   C.TSTreeCursor
	src_text []byte
	store &Store = &Store(0)
}

pub fn (mut an Analyzer) report(msg Message) {
	an.store.messages << msg
}

pub fn (mut an Analyzer) find_symbol_by_node(node C.TSNode) &TypeSymbol {
	if node.is_null() {
		return &TypeSymbol(0)
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
	if !node.is_null() {	
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
	if an.current_node().has_error() {
		an.report({
			kind: .error
			range: an.current_node().range()
			file_path: an.cur_file_path
			content: if an.current_node().is_missing() { 'Missing node' } else { 'Node error' }
		})
	}

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

pub fn (mut an Analyzer) infer_value_type(right C.TSNode) &TypeSymbol {
	if right.is_null() {
		return &TypeSymbol(0)
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

fn (mut an Analyzer) extract_parameter_list(node C.TSNode, mut type_symbol TypeSymbol, mut scope ScopeTree) {
	params_len := node.named_child_count()

	for i := u32(0); i < params_len; i++ {
		mut access := SymbolAccess.private
		param_node := node.named_child(i)
		if param_node.child(0).get_type() == 'mut' {
			access = SymbolAccess.private_mutable
		}

		param_name := param_node.child_by_field_name('name')
		param_type_node := param_node.child_by_field_name('type')

		mut param_sym := &TypeSymbol{
			name: param_name.get_text(an.src_text)
			kind: .variable
			range: param_node.range()
			access: access
			return_type: an.find_symbol_by_node(param_type_node)
		}

		type_symbol.add_child(mut param_sym) or { eprintln(err) }
		scope.register(param_sym)
	}
}

pub fn (mut an Analyzer) extract_block(node C.TSNode, mut scope ScopeTree) {
	if node.get_type() != 'block' {
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
				mut var_sym := &TypeSymbol{
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

pub fn (mut an Analyzer) top_level_statement() {
	mut node_type := an.current_node().get_type()
	mut access := SymbolAccess.private
	if node_type == 'source_file' {
		if an.current_node().is_missing() {
			an.report({
				kind: .warning
				range: an.current_node().range()
				file_path: an.cur_file_path
				content: 'Missing node (For testing. please remove this warning in `source_file` node after implementing initial basic check features)'
			})
		}

		an.cursor.to_first_child()
		node_type = an.current_node().get_type()
	}

	range :=  an.current_node().range()
	mut global_scope := an.get_scope(an.current_node().parent())

	match node_type {
		'import_declaration' {
			an.cursor.to_first_child()
			an.next()

			// TODO: make import system working
			// spec_node := an.cursor.current_node()
			// println(mod_path.sexpr_str())
			// mod_path := spec_node.child_by_field_name('path').get_text(an.src_text)
			// mod_alias := spec_node.child_by_field_name('alias')

			// print(mod_path)
			// if !mod_alias.is_null() {
			// 	println(' | alias: ${mod_alias.child_by_field_name('name').get_text(an.src_text)}')
			// }

			an.cursor.to_parent()
		}
		'const_declaration' {
			an.cursor.to_first_child()
			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
			}

			an.next()
			for an.current_node().get_type() == 'const_spec' {
				spec_node := an.current_node()
				mut const_sym := &TypeSymbol{	
					name: spec_node.child_by_field_name('name').get_text(an.src_text)
					kind: .variable
					access: access
					range: spec_node.range()
					file_path: an.store.cur_file_path
				}

				const_sym.return_type = an.infer_value_type(spec_node.child_by_field_name('value'))
				an.store.register_symbol(const_sym) or { eprint(err) }
				global_scope.register(const_sym)
				if !an.next() {
					break
				}
			}

			an.cursor.to_parent()
		}
		'struct_declaration' {
			an.cursor.to_first_child()
			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
			}
			
			an.next()
			mut sym := &TypeSymbol{
				name: an.current_node().get_text(an.src_text)
				access: access
				range: range
				kind: .struct_
			}
			
			an.next()
			fields_len := an.current_node().named_child_count()
			mut scope := an.get_scope(an.current_node())

			an.cursor.to_first_child()
			for i := 0; i < fields_len; i++ {
				an.next()
				field_node := an.current_node()

				if field_node.get_type() == 'struct_field_scope' {
					scope_text := field_node.get_text(an.src_text)
					access = match scope_text {
						'mut:' { SymbolAccess.private_mutable }
						'pub:' { SymbolAccess.public }
						'pub mut:' { SymbolAccess.public_mutable }
						'__global:' { SymbolAccess.global }
						else { access }
					}
				}

				if field_node.get_type() != 'struct_field_declaration' {
					continue
				} 
				
				field_typ := an.find_symbol_by_node(field_node.child_by_field_name('type'))
				mut field_sym := &TypeSymbol{
					name: field_node.child_by_field_name('name').get_text(an.src_text)
					kind: .field
					range: field_node.range()
					access: access
					return_type: field_typ
					file_path: an.store.cur_file_path
				}

				sym.add_child(mut field_sym) or { 
					eprintln(err)
				}

				scope.register(field_sym)
			}

			an.store.register_symbol(sym) or { eprintln(err) }
			an.cursor.to_parent()
			an.cursor.to_parent()
		}
		'interface_declaration' {
			an.cursor.to_first_child()
			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
			}
			
			an.next()
			mut sym := &TypeSymbol{
				name: an.current_node().get_text(an.src_text)
				access: access
				range: range
				kind: .interface_
			}

			an.next()

			fields_len := an.current_node().named_child_count()
			an.cursor.to_first_child()
			for i := 0; i < fields_len; i++ {
				an.next()
				field_node := an.current_node()
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
						mut field_sym := &TypeSymbol{
							name: field_node.child_by_field_name('name').get_text(an.src_text)
							kind: .field
							range: field_node.range()
							access: access
							return_type: field_typ
							file_path: an.store.cur_file_path
						}

						sym.add_child(mut field_sym) or { 
							eprintln(err)
						}
					}
					else { continue }
				}
			}

			an.store.register_symbol(sym) or { eprintln(err) }
			an.cursor.to_parent()
			an.cursor.to_parent()
		}
		'enum_declaration' {
			an.cursor.to_first_child()

			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
				an.cursor.next()
			}

			an.next()
			mut sym := &TypeSymbol{
				name: an.current_node().get_text(an.src_text)
				access: access
				range: range
				kind: .enum_
			}
			
			an.next()
			members_len := an.current_node().named_child_count()

			an.cursor.to_first_child()
			for i := 0; i < members_len; i++ {
				an.next()
				member_node := an.current_node()
				if member_node.get_type() != 'enum_member' {
					continue
				}

				mut member_sym := &TypeSymbol{
					name: member_node.child_by_field_name('name').get_text(an.src_text)
					kind: .field
					range: member_node.range()
					access: access
					// builtin
					return_type: an.store.find_symbol('', 'int')
					file_path: an.store.cur_file_path
				}

				sym.add_child(mut member_sym) or { 
					eprintln(err)
				}
			}

			an.store.register_symbol(sym) or { eprintln(err) }
			an.cursor.to_parent()
			an.cursor.to_parent()
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
			mut fn_sym := &TypeSymbol{
				name: name_node.get_text(an.src_text)
				kind: .function
				range: range
				access: access
				return_type: an.find_symbol_by_node(fn_node.child_by_field_name('result'))
			}

			if !receiver_node.is_null() {
				an.extract_parameter_list(params_list_node, mut fn_sym, mut scope)
				keys := fn_sym.children.keys()
				last_param_key := keys.last()
				if !isnil(fn_sym.children[last_param_key].return_type) {
					fn_sym.children[last_param_key].return_type.add_child(mut fn_sym) or { eprintln(err) }
				}

				unsafe {
					keys.free()
					last_param_key.free()
				}
			} else {
				an.store.register_symbol(fn_sym) or { eprintln(err) }
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
}

pub fn analyze(tree &C.TSTree, src_text []byte, mut store Store) {
	mut analyzer := analyzer.Analyzer{}
	analyzer.analyze(tree.root_node(), src_text, mut store)
}