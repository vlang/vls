module analyzer

struct TreeCursor {
mut:
	cur_child_idx u32
	named_only    bool = true
	child_count   u32            [required]
	cursor        C.TSTreeCursor [required]
}

fn (mut tc TreeCursor) next() bool {
	for tc.cur_child_idx < tc.child_count {
		if !tc.cursor.next() {
			return false
		}
		tc.cur_child_idx++
		if tc.named_only && (tc.current_node().is_named() && !tc.current_node().is_extra()) {
			break
		}
	}

	return true
}

fn (mut tc TreeCursor) to_first_child() bool {
	return tc.cursor.to_first_child()
}

fn (tc &TreeCursor) current_node() C.TSNode {
	return tc.cursor.current_node()
}

[unsafe]
fn (tc &TreeCursor) free() {
	unsafe {
		tc.cursor.free()
		tc.cur_child_idx = 0
		tc.child_count = 0
	}
}

pub struct Analyzer {
pub mut:
	cur_file_path string
	cursor        TreeCursor
	src_text      []byte
	store         &Store = &Store(0)
	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import bool
}

fn (mut an Analyzer) report(msg string, node C.TSNode) {
	an.store.report_error(report_error(msg, node.range()))
}

fn (mut an Analyzer) import_decl(node C.TSNode) {
	// Most of the checking is already done in `import_modules_from_trees`
	// Check only the symbols if they are available
	symbols := node.child_by_field_name('symbols')
	if symbols.is_null() {
		return
	}

	module_name_node := node.child_by_field_name('path')
	module_name := module_name_node.code(an.src_text)
	// defer { unsafe { module_name.free() } }

	module_path := an.store.get_module_path_opt(module_name) or {
		// `import_modules_from_trees` already reported it
		return
	}

	list := symbols.named_child(0)
	symbols_count := list.named_child_count()
	for i := u32(0); i < symbols_count; i++ {
		sym := list.named_child(i)
		if sym.is_null() {
			continue
		}

		symbol_name := sym.code(an.src_text)
		got_sym := an.store.symbols[module_path].get(symbol_name) or {
			an.report('Symbol `$symbol_name` not found', sym)
			// unsafe { symbol_name.free() }
			continue
		}

		if int(got_sym.access) < int(SymbolAccess.public) {
			an.report('Symbol `$symbol_name not public', sym)
			// unsafe { symbol_name.free() }
			continue
		}
	}
}

fn (mut an Analyzer) const_decl(node C.TSNode) {
}

fn (mut an Analyzer) struct_decl(node C.TSNode) {
}

fn (mut an Analyzer) interface_decl(node C.TSNode) {
}

fn (mut an Analyzer) enum_decl(node C.TSNode) {
}

fn (mut an Analyzer) fn_decl(node C.TSNode) {
}

pub fn (mut an Analyzer) top_level_statement() {
	current_node := an.cursor.current_node()
	node_type := current_node.name()
	defer {
		an.cursor.next()
		// unsafe { node_type.free() }
	}

	match node_type {
		'import_declaration' {
			an.import_decl(current_node)
		}
		'const_declaration' {
			an.const_decl(current_node)
		}
		'struct_declaration' {
			an.struct_decl(current_node)
		}
		'interface_declaration' {
			an.interface_decl(current_node)
		}
		'enum_declaration' {
			an.enum_decl(current_node)
		}
		'function_declaration' {
			an.fn_decl(current_node)
		}
		else {}
	}
}

// analyze analyzes the given tree
pub fn (mut store Store) analyze(tree &C.TSTree, src_text []byte) {
	root_node := tree.root_node()
	child_len := int(root_node.child_count())
	mut an := Analyzer{
		store: unsafe { store }
		src_text: src_text
		cursor: TreeCursor{
			child_count: u32(child_len)
			cursor: root_node.tree_cursor()
		}
	}

	an.cursor.to_first_child()

	for _ in 0 .. child_len {
		an.top_level_statement()
	}

	// unsafe { an.cursor.free() }
}
