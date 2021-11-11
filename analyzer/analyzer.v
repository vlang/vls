module analyzer

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

fn (mut an Analyzer) import_decl(node C.TSNode) ? {
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
		sym := list.named_child(i) ?
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
	current_node := an.cursor.current_node() or { return }

	match current_node.type_name() {
		'import_declaration' {
			an.import_decl(current_node) or {}
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
	mut an := Analyzer{
		store: unsafe { store }
		src_text: src_text
		cursor: new_tree_cursor(tree.root_node())
	}

	an.cursor.to_first_child()
	for _ in an.cursor {
		an.top_level_statement()
	}

	// unsafe { an.cursor.free() }
}
