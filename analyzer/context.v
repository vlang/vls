module analyzer

import os
import ast
import tree_sitter { SourceText }

[params]
pub struct AnalyzerContext {
pub mut:
	store        &Store     [required]
	file_path    string     [required]
	file_version int
	file_name    string
	file_dir     string
	text         SourceText = Runes([]rune{len: 0})
}

[params]
pub struct AnalyzerContextParams {
	file_path    string     [required]
	file_version int
	store        &Store     = &Store(0)
	text         SourceText = Runes([]rune{len: 0})
}

pub fn new_context(params AnalyzerContextParams) AnalyzerContext {
	return AnalyzerContext{
		store: params.store
		file_path: params.file_path
		file_version: params.file_version
		file_name: if params.file_path.len != 0 { os.base(params.file_path) } else { '' }
		file_dir: if params.file_path.len != 0 { os.dir(params.file_path) } else { '' }
		text: params.text
	}
}

[if trace ?]
pub fn (mut ctx AnalyzerContext) trace_report(report Report) {
	r := Report{
		...report
		file_path: ctx.file_path
	}
	ctx.store.trace_report(r)
}

[if trace ?]
pub fn (mut ctx AnalyzerContext) trace_report_error(err IError) {
	ctx.store.report_error_with_path(err, ctx.file_path)
}

pub fn (mut ctx AnalyzerContext) replace_file_path(new_file_path string) AnalyzerContext {
	ctx.file_path = new_file_path
	ctx.file_name = os.base(new_file_path)
	ctx.file_dir = os.dir(new_file_path)
	return ctx
}

pub fn (mut ctx AnalyzerContext) infer_value_type_from_node(node ast.Node) &Symbol {
	return ctx.store.infer_value_type_from_node(ctx.file_path, node, ctx.text)
}

pub fn (mut ctx AnalyzerContext) infer_symbol_from_node(node ast.Node) !&Symbol {
	return ctx.store.infer_symbol_from_node(ctx.file_path, node, ctx.text)
}

pub fn (mut ctx AnalyzerContext) find_symbol_by_type_node(node ast.Node) !&Symbol {
	return ctx.store.find_symbol_by_type_node(ctx.file_path, node, ctx.text)
}

pub fn (ctx AnalyzerContext) find_symbol(module_name string, name string) !&Symbol {
	return ctx.store.find_symbol(ctx.file_path, module_name, name)
}

pub fn (ctx AnalyzerContext) symbol_formatter(from_semantic bool) SymbolFormatter {
	return SymbolFormatter{
		context: ctx
		replacers: if from_semantic {
			['int_literal', 'int literal', 'float_literal', 'float literal']
		} else {
			[]string{}
		}
	}
}

// get_docstring find all single-line comments immediately preceding given node.
pub fn (ctx AnalyzerContext) get_docstring(node ast.Node) []string {
	mut docstrings := []string{}
	mut cur := node
	mut last_line := node.start_point().row
	mut min_space_cnt := -1
	for {
		cur = cur.prev_sibling() or { break }
		if cur.type_name != .comment {
			break
		}

		st, ed := cur.start_point(), cur.end_point()
		if st.row != ed.row {
			// multi-line comment
			break
		} else if last_line - ed.row > 1 {
			break
		}
		last_line = st.row

		s := cur.text(ctx.text).all_after('//')
		for i := 0; i < s.len; i++ {
			if s[i] != ` ` {
				if i < min_space_cnt || min_space_cnt < 0 {
					min_space_cnt = i
				}
				break
			}
		}
		docstrings << s
	}

	if min_space_cnt > 0 {
		for i := 0; i < docstrings.len; i++ {
			if docstrings[i].len > 0 {
				docstrings[i] = docstrings[i][min_space_cnt..]
			}
		}
	}

	docstrings.reverse_in_place()

	return docstrings
}
