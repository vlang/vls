module an_test_utils

import strings
import analyzer { ScopeTree, Symbol, Collector, Report, Import, SymbolFormatter }
// import tree_sitter
import os

// sexpr_str returns the S expression-like stringified
// representation of the []Symbol.
pub fn sexpr_str_symbol_array(mut symbol_formatter SymbolFormatter, symbols []&Symbol) string {
	mut sb := strings.new_builder(200)
	for i, sym in symbols {
		sexpr_str_write_symbol(mut sb, mut symbol_formatter, sym)
		if i < symbols.len - 1 {
			sb.write_byte(` `)
		}
	}
	return sb.str()
}

fn sexpr_str_write_symbol(mut writer strings.Builder, mut symbol_formatter SymbolFormatter, sym &Symbol) {
	writer.write_byte(`(`)
	writer.write_string(sym.access.str())
	writer.write_string(sym.kind.str() + ' ')
	writer.write_string(sym.name + ' ')
	if !sym.return_sym.is_void() {
		if sym.return_sym.kind == .function_type {
			symbol_formatter.format_with_builder(sym.return_sym, mut writer)
			writer.write_u8(` `)
		} else {
			writer.write_string(sym.return_sym.name + ' ')
		}
	}
	if sym.kind in analyzer.sym_kinds_allowed_to_print_parent && !sym.parent_sym.is_void() && sym.parent_sym.kind != .variable {
		writer.write_string('(parent ')
		writer.write_string(sym.parent_sym.kind.str() + ' ')
		if sym.parent_sym.kind == .function_type {
			symbol_formatter.format_with_builder(sym.parent_sym, mut writer)
		} else {
			writer.write_string(sym.parent_sym.name)
		}
		writer.write_string(') ')
	}
	sexpr_str_write_tspoint(mut writer, sym.range.start_point)
	writer.write_byte(`-`)
	sexpr_str_write_tspoint(mut writer, sym.range.end_point)
	if sym.kind == .function {
		sexpr_str_write_scopetree(mut writer, mut symbol_formatter, sym.scope)
	} else {
		for child in sym.children_syms {
			writer.write_byte(` `)
			if sym.kind == .typedef || sym.kind == .sumtype {
				writer.write_byte(`(`)
				writer.write_string(child.kind.str() + ' ')
				writer.write_string(child.name)
				writer.write_byte(`)`)
			} else {
				sexpr_str_write_symbol(mut writer, mut symbol_formatter, child)
			}
		}
	}
	writer.write_byte(`)`)
}

pub fn sexpr_str_write_tspoint(mut writer strings.Builder, point C.TSPoint) {
	writer.write_byte(`[`)
	writer.write_string(point.row.str())
	writer.write_byte(`,`)
	writer.write_string(point.column.str())
	writer.write_byte(`]`)
}

pub fn sexpr_str_write_scopetree(mut writer strings.Builder, mut symbol_formatter SymbolFormatter, scope &ScopeTree) {
	if isnil(scope) {
		return
	}

	for sym in scope.symbols {
		writer.write_byte(` `)
		sexpr_str_write_symbol(mut writer, mut symbol_formatter, sym)
	}

	for child in scope.children {
		if isnil(child) || (!isnil(child) && child.symbols.len == 0) {
			continue
		}
		writer.write_string(' (scope [$child.start_byte]-[$child.end_byte]')
		sexpr_str_write_scopetree(mut writer, mut symbol_formatter, child)
		writer.write_byte(`)`)
	}
}

pub fn sexpr_str_reports(reports []Report, mut writer strings.Builder) {
	for i, report in reports {
		writer.write_byte(`(`)
		writer.write_string(report.kind.str())
		writer.write([u8(` `), `"`]) or {}
		writer.write_string(report.message)
		writer.write([u8(`"`), ` `]) or {}
		sexpr_str_write_tspoint(mut writer, report.range.start_point)
		writer.write_byte(`-`)
		sexpr_str_write_tspoint(mut writer, report.range.end_point)
		writer.write_byte(`)`)
		if i < reports.len - 1 {
			writer.write_byte(` `)
		}
	}
}

pub fn sexpr_str_reporter(collector Collector) string {
	mut writer := strings.new_builder(200)
	sexpr_str_reports(collector.notices, mut writer)
	if collector.notices.len != 0 {
		writer.write_byte(` `)
	}
	sexpr_str_reports(collector.warnings, mut writer)
	if collector.warnings.len != 0 {
		writer.write_byte(` `)
	}
	sexpr_str_reports(collector.errors, mut writer)
	return writer.str()
}

pub fn sexpr_str_import(file_path string, imp Import, mut writer strings.Builder) {
	file_name := os.base(file_path)
	writer.write_byte(`(`)
	if file_name in imp.aliases {
		writer.write_string(imp.aliases[file_name])
	} else {
		writer.write_string(imp.module_name)
	}
	writer.write_byte(` `)
	writer.write_byte(`"`)
	writer.write_string(imp.path)
	writer.write_byte(`"`)
	writer.write_byte(` `)
	sexpr_str_write_tspoint(mut writer, imp.ranges[file_path].start_point)
	writer.write_byte(`-`)
	sexpr_str_write_tspoint(mut writer, imp.ranges[file_path].end_point)
	writer.write_byte(`)`)
}

pub fn sexpr_str_imports(file_path string, imports []Import) string {
	mut writer := strings.new_builder(200)

	for i, imp in imports {
		if file_path !in imp.ranges {
			continue
		}

		sexpr_str_import(file_path, imp, mut writer)

		if i < imports.len - 1 {
			writer.write_byte(` `)
		}
	}

	return writer.str()
}