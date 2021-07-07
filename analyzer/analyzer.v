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



pub fn (mut an Analyzer) unwrap_error(err IError) {
	if err is AnalyzerError {
		an.report({ 
			content: err.msg
			range: err.range
			file_path: an.store.cur_file_path.clone()
		})
	}
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

pub fn (mut store Store) analyze(tree &C.TSTree, src_text []byte) {
	mut analyzer := analyzer.Analyzer{}
	analyzer.analyze(tree.root_node(), src_text, mut store)
}
