module analyzer

import os
import ast
import tree_sitter { SourceText }

[params]
pub struct AnalyzerContext {
pub mut:
	store        &Store [required]
	file_path    string [required]
	file_version int
	file_name    string
	file_dir     string
	text         SourceText  = Runes([]rune{len: 0})
}

[params]
pub struct AnalyzerContextParams {
	file_path string [required]
	file_version int
	store     &Store = &Store(0)
	text      SourceText = Runes([]rune{len: 0})
}

pub fn new_context(params AnalyzerContextParams) AnalyzerContext {
	return AnalyzerContext{
		store: params.store
		file_path: params.file_path
		file_version: params.file_version
		file_name: os.base(params.file_path)
		file_dir: os.dir(params.file_path)
		text: params.text
	}
}

pub fn (mut ctx AnalyzerContext) replace_file_path(new_file_path string) AnalyzerContext{
	ctx.file_path = new_file_path
	ctx.file_name = os.base(new_file_path)
	ctx.file_dir = os.dir(new_file_path)
	return ctx
}

pub fn (mut ctx AnalyzerContext) infer_value_type_from_node(node ast.Node) &Symbol {
	return ctx.store.infer_value_type_from_node(ctx.file_path, node, ctx.text)
}

pub fn (mut ctx AnalyzerContext) infer_symbol_from_node(node ast.Node) ?&Symbol {
	return ctx.store.infer_symbol_from_node(ctx.file_path, node, ctx.text)
}

pub fn (mut ctx AnalyzerContext) find_symbol_by_type_node(node ast.Node) ?&Symbol {
	return ctx.store.find_symbol_by_type_node(ctx.file_path, node, ctx.text)
}

pub fn (ctx AnalyzerContext) find_symbol(module_name string, name string) ?&Symbol {
	return ctx.store.find_symbol(ctx.file_path, module_name, name)
}

pub fn (ctx AnalyzerContext) symbol_formatter(from_semantic bool) SymbolFormatter {
	return SymbolFormatter{
		context: ctx
	}
}