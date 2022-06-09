module analyzer

import strconv
import errors
import tree_sitter as ts
import tree_sitter_v as v

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

struct SemanticAnalyzerContext {
	params []ReportData
}

fn (mut an SemanticAnalyzer) report(node ts.Node<v.NodeType>, code_or_msg string, data ...ReportData) IError {
	mut is_msg_code := false
	if code_or_msg in errors.message_templates {
		is_msg_code = true
	}

	return error(an.format_report(
		kind: .error
		message: if is_msg_code { errors.message_templates[code_or_msg] } else { code_or_msg }
		range: node.range()
		file_path: an.store.cur_file_path
		code: if is_msg_code { code_or_msg } else { '' }
		data: SemanticAnalyzerContext{data}
	))
}

fn (mut an SemanticAnalyzer) format_report(report Report) string {
	if report.data is SemanticAnalyzerContext {
		if report.data.params.len != 0 {
			mut final_params := []string{cap: report.data.params.len}
			for d in report.data.params {
				if d is string {
					final_params << d
				} else if d is Symbol {
					final_params << d.gen_str()
				} else {
					// final_params << d.str()
					final_params << 'unknown'
				}
			}

			ptrs := unsafe { final_params.pointers() }
			final_report := Report{
				...report
				message: strconv.v_sprintf(report.message, ...ptrs)
				data: 0
			}

			an.store.report(final_report)
			return final_report.message
		}
	}

	an.store.report(report)
	return report.message
}

fn (mut an SemanticAnalyzer) import_decl(node ts.Node<v.NodeType>) ? {
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
			an.report(sym_node, 'Symbol `$symbol_name` in module `$module_name` not found')
			continue
		}

		if int(got_sym.access) < int(SymbolAccess.public) {
			an.report(sym_node, 'Symbol `$symbol_name` in module `$module_name` not public')
			continue
		}
	}
}

fn (mut an SemanticAnalyzer) const_decl(node ts.Node<v.NodeType>) {
}

fn (mut an SemanticAnalyzer) struct_decl(node ts.Node<v.NodeType>) {
}

fn (mut an SemanticAnalyzer) interface_decl(node ts.Node<v.NodeType>) {
}

fn (mut an SemanticAnalyzer) enum_decl(node ts.Node<v.NodeType>) {
}

fn (mut an SemanticAnalyzer) fn_decl(node ts.Node<v.NodeType>) {
}

pub fn (mut an SemanticAnalyzer) top_level_statement(current_node ts.Node<v.NodeType>) {
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
			an.enum_decl(current_node)
		}
		.function_declaration {
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
pub fn (mut store Store) analyze(tree &ts.Tree<v.NodeType>, src_text []rune) {
	mut an := SemanticAnalyzer{
		store: unsafe { store }
		src_text: src_text
		cursor: new_tree_cursor(tree.root_node())
	}
	an.analyze()
}
