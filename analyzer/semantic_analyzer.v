module analyzer

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

fn (mut an SemanticAnalyzer) report(msg string, node C.TSNode) {
	an.store.report(
		kind: .error
		message: msg
		range: node.range()
		file_path: an.store.cur_file_path
	)
}

fn (mut an SemanticAnalyzer) import_decl(node C.TSNode) ? {
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
			an.report('Symbol `$symbol_name` in module `$module_name` not found', sym_node)
			continue
		}

		if int(got_sym.access) < int(SymbolAccess.public) {
			an.report('Symbol `$symbol_name` in module `$module_name` not public', sym_node)
			continue
		}
	}
}

fn (mut an SemanticAnalyzer) const_decl(node C.TSNode) {
}

fn (mut an SemanticAnalyzer) struct_decl(node C.TSNode) {
}

fn (mut an SemanticAnalyzer) interface_decl(node C.TSNode) {
}

fn (mut an SemanticAnalyzer) enum_decl(node C.TSNode) {
}

fn (mut an SemanticAnalyzer) fn_decl(node C.TSNode) {
}

pub fn (mut an SemanticAnalyzer) top_level_statement(current_node C.TSNode) {
	match current_node.type_name() {
		'import_declaration' {
			an.import_decl(current_node) or {
				// an.messages.report(err)
			}
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

pub fn (mut an SemanticAnalyzer) analyze() {
	for got_node in an.cursor {
		an.top_level_statement(got_node)
	}
}

// analyze analyzes the given tree
pub fn (mut store Store) analyze(tree &C.TSTree, src_text []rune) {
	mut an := SemanticAnalyzer{
		store: unsafe { store }
		src_text: src_text
		cursor: new_tree_cursor(tree.root_node())
	}
	an.analyze()
}
