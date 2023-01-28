module analyzer

import os
import strings

pub struct SymbolFormatter {
mut:
	context   AnalyzerContext
	replacers []string
}

[params]
pub struct SymbolFormatterConfig {
	with_kind                bool = true
	with_access              bool = true
	with_contents            bool = true
	docstring_line_len_limit int
	field_indent             string = '\t'
}

pub const params_format_cfg = SymbolFormatterConfig{
	with_kind: false
	with_contents: false
}

const types_format_cfg = SymbolFormatterConfig{
	with_kind: false
	with_access: false
}

const child_types_format_cfg = SymbolFormatterConfig{
	with_kind: false
	with_access: false
	with_contents: false
}

pub fn (mut fmt SymbolFormatter) format(sym &Symbol, cfg SymbolFormatterConfig) string {
	mut sb := strings.new_builder(300)
	fmt.format_with_builder(sym, mut sb, cfg)
	return sb.str()
}

fn (fmt &SymbolFormatter) get_module_name(from_file_path string) string {
	if from_file_path.len != 0 {
		if import_lists := fmt.context.store.imports[fmt.context.file_dir] {
			for imp in import_lists {
				if !from_file_path.starts_with(imp.path) || fmt.context.file_path !in imp.ranges {
					continue
				} else if fmt.context.file_name in imp.symbols
					&& imp.symbols[fmt.context.file_name].len != 0 {
					eprintln(imp.symbols[fmt.context.file_name])
					// DO NOT PREFIX SELECTIVELY-IMPORTED SYMBOLS!
					return ''
				}
				return imp.aliases[fmt.context.file_name] or { imp.module_name }
			}
		}

		for auto_import_module, imp_path in fmt.context.store.auto_imports {
			if !from_file_path.starts_with(imp_path) {
				continue
			}
			return auto_import_module
		}
	}

	return ''
}

fn (mut fmt SymbolFormatter) write_name(sym &Symbol, mut builder strings.Builder) {
	if isnil(sym) {
		builder.write_string('invalid symbol')
		return
	}

	// if sym.language == .c {
	// 	builder.write_string('C.')
	// } else if sym.language == .js {
	// 	builder.write_string('JS.')
	// } else {
	if sym.language == .v {
		module_name := fmt.get_module_name(sym.file_path)
		if module_name.len != 0 {
			builder.write_string(module_name + '.')
		}
	}

	builder.write_string(sym.name.replace_each(fmt.replacers))
}

fn (fmt &SymbolFormatter) write_access(sym &Symbol, mut builder strings.Builder, cfg SymbolFormatterConfig) {
	if cfg.with_access {
		builder.write_string(sym.access.str())
	}
}

fn (fmt &SymbolFormatter) write_kind(kind string, mut builder strings.Builder, cfg SymbolFormatterConfig) {
	if cfg.with_kind {
		builder.write_string(kind)
		builder.write_u8(` `)
	}
}

pub fn (mut fmt SymbolFormatter) format_with_builder(sym &Symbol, mut builder strings.Builder, cfg SymbolFormatterConfig) {
	if isnil(sym) {
		builder.write_string('invalid symbol')
		return
	}

	match sym.kind {
		.array_ {
			builder.write_string('[]')
			fmt.write_name(sym.children_syms[0] or { void_sym }, mut builder)
		}
		.variadic {
			builder.write_string('...')
			fmt.write_name(sym.children_syms[0] or { void_sym }, mut builder)
		}
		.map_ {
			builder.write_string('map[')
			fmt.write_name(sym.children_syms[0] or { void_sym }, mut builder)
			builder.write_u8(`]`)
			fmt.write_name(sym.children_syms[1] or { void_sym }, mut builder)
		}
		.chan_ {
			builder.write_string('chan ')
			fmt.write_name(sym.parent_sym, mut builder)
		}
		.enum_ {
			fmt.write_access(sym, mut builder, cfg)
			fmt.write_kind('enum', mut builder, cfg)
			fmt.write_name(sym, mut builder)
		}
		.function, .function_type {
			fmt.write_access(sym, mut builder, cfg)
			builder.write_string('fn ')

			if !isnil(sym.parent_sym) && !sym.parent_sym.is_void() {
				builder.write_byte(`(`)
				fmt.format_with_builder(sym.parent_sym, mut builder, analyzer.params_format_cfg)
				builder.write_string(') ')
				builder.write_string(sym.name)
			} else if !sym.name.starts_with(anon_fn_prefix) {
				fmt.write_name(sym, mut builder)
			}

			builder.write_byte(`(`)
			for i, parameter_sym in sym.children_syms {
				if parameter_sym.name.len != 0 {
					fmt.format_with_builder(parameter_sym, mut builder, analyzer.params_format_cfg)
				} else {
					fmt.format_with_builder(parameter_sym.return_sym, mut builder, analyzer.params_format_cfg)
				}
				if i < sym.children_syms.len - 1 {
					builder.write_string(', ')
				}
			}
			builder.write_byte(`)`)
			if !sym.return_sym.is_void() {
				builder.write_byte(` `)
				fmt.format_with_builder(sym.return_sym, mut builder, analyzer.child_types_format_cfg)
			}
		}
		.multi_return {
			builder.write_byte(`(`)
			for i, type_sym in sym.children_syms {
				if type_sym.kind in kinds_in_multi_return_to_be_excluded {
					continue
				}

				fmt.format_with_builder(type_sym, mut builder, analyzer.types_format_cfg)
				if i < sym.children_syms.len - 1 {
					builder.write_string(', ')
				}
			}
			builder.write_byte(`)`)
		}
		.optional {
			builder.write_string('?')
			if !sym.parent_sym.is_void() {
				fmt.format_with_builder(sym.parent_sym, mut builder, analyzer.types_format_cfg)
			}
		}
		.result {
			builder.write_string('!')
			if !sym.parent_sym.is_void() {
				fmt.format_with_builder(sym.parent_sym, mut builder, analyzer.types_format_cfg)
			}
		}
		.ref {
			builder.write_string('&')
			fmt.format_with_builder(sym.parent_sym, mut builder, analyzer.types_format_cfg)
		}
		.struct_ {
			fmt.write_access(sym, mut builder, cfg)
			fmt.write_kind('struct', mut builder, cfg)
			fmt.write_name(sym, mut builder)
		}
		.typedef, .sumtype {
			if sym.kind == .typedef && sym.parent_sym.is_void() {
				fmt.write_name(sym, mut builder)
				return
			}

			fmt.write_access(sym, mut builder, cfg)
			fmt.write_kind('type', mut builder, cfg)
			fmt.write_name(sym, mut builder)

			if cfg.with_contents {
				builder.write_string(' = ')

				if sym.kind == .typedef {
					fmt.format_with_builder(sym.parent_sym, mut builder, analyzer.child_types_format_cfg)
				} else {
					for i, child in sym.children_syms {
						if i != 0 {
							builder.write_string(' | ')
						}
						fmt.format_with_builder(child, mut builder, analyzer.child_types_format_cfg)
					}
				}
			}
		}
		.variable, .field {
			fmt.write_access(sym, mut builder, cfg)

			if sym.kind == .field {
				fmt.format_with_builder(sym.parent_sym, mut builder, analyzer.child_types_format_cfg)
				builder.write_byte(`.`)
			}

			if sym.is_const {
				builder.write_string('const ')
			}

			builder.write_string(sym.name)
			if !sym.return_sym.is_void() {
				builder.write_byte(` `)

				if sym.return_sym.kind == .function_type {
					fmt.format_with_builder(sym.return_sym, mut builder, cfg)
				} else {
					fmt.write_name(sym.return_sym, mut builder)
				}
			}
		}
		else {
			// builder.write_string(sym.kind.str())
			// builder.write_byte(` `)
			fmt.write_name(sym, mut builder)
		}
	}
}

// check_is_header_line check if a line starts with at least `#` and followed by
// space.
fn check_is_header_line(line string) bool {
	if line.len == 0 {
		return false
	}

	if line[0] != `#` {
		return false
	}

	mut is_header := false
	for byt in line {
		if byt != `#` {
			is_header = byt == ` `
			break
		}
	}

	return is_header
}

// check_is_horizontal_rule check if a line contains only
// `-, =, _, *, ~` (any one of them), and with length of at least 3.
fn check_is_horizontal_rule(line string) bool {
	if line.len < 3 {
		return false
	}

	first_byt := line[0]
	if first_byt !in [`-`, `=`, `_`, `*`, `~`] {
		return false
	}

	mut is_hr := true
	for byt in line {
		if byt != first_byt {
			is_hr = false
			break
		}
	}

	return is_hr
}

// write_line_with_wrapping write string to builder, string will be wrapped into
// multiple lines if needed. This function returns length of the last written line.
fn write_line_with_wrapping(mut builder strings.Builder, line string, line_limit int, init_offset int) int {
	if line_limit <= 0 {
		builder.write_string(line)
		return line.len
	}

	mut offset := init_offset
	mut bound := line_limit - offset
	if bound > line.len {
		bound = line.len
		offset += bound
	}
	builder.write_string(line[0..bound])

	for i := bound; i < line.len; i += line_limit {
		bound = i + line_limit
		if bound >= line.len {
			bound = line.len
			offset = bound - i
		}
		builder.write_byte(`\n`)
		builder.write_string(line[i..bound])
	}

	return offset
}

// write_docstrings_with_line_concate get docstring for symbol, using newline
// concatenate rule described in [v doc](https://github.com/vlang/v/blob/master/doc/docs.md#newlines-in-documentation-comments).
pub fn (fmt &SymbolFormatter) format_docstrings_with_line_concate(sym &Symbol, cfg SymbolFormatterConfig) string {
	len := sym.docstrings.len
	if len == 0 {
		return ''
	} else if len == 1 {
		return sym.docstrings[0]
	}

	mut builder := strings.new_builder(300)
	line_limit := cfg.docstring_line_len_limit
	mut need_newline, mut offset := true, 0

	offset = write_line_with_wrapping(mut builder, sym.docstrings[0], line_limit, offset)
	for ds in sym.docstrings[1..] {
		trimed_line := ds.trim_space()

		if trimed_line.len == 0 {
			need_newline = true
			continue
		}

		// prepend newline check
		is_header := check_is_header_line(trimed_line)
		is_hr := check_is_horizontal_rule(trimed_line)
		if ds.starts_with('- ') || ds.starts_with('|') || is_header || is_hr {
			need_newline = true
		}

		// doc content
		if need_newline {
			builder.write_byte(`\n`)
			offset = 0
		} else {
			builder.write_byte(` `)
			offset += 1
		}

		offset = write_line_with_wrapping(mut builder, ds, line_limit, offset)

		// append newline check
		need_newline = false
		if ds.ends_with('.') || ds.ends_with('|') || is_header || is_hr {
			need_newline = true
			continue
		}
	}

	return builder.str()
}

// write_docstrings get docstring for symbol, all newline in original docstring
// comment will be presented as is.
pub fn (fmt &SymbolFormatter) format_docstrings(sym &Symbol, cfg SymbolFormatterConfig) string {
	len := sym.docstrings.len
	if len == 0 {
		return ''
	} else if len == 1 {
		return sym.docstrings[0]
	}

	mut builder := strings.new_builder(300)
	line_limit := cfg.docstring_line_len_limit

	write_line_with_wrapping(mut builder, sym.docstrings[0], line_limit, 0)
	for ds in sym.docstrings[1..] {
		trimed_line := ds.trim_space()
		if trimed_line.len == 0 {
			continue
		}

		builder.write_byte(`\n`)
		write_line_with_wrapping(mut builder, ds, line_limit, 0)
	}

	return builder.str()
}

pub fn (mut fmt SymbolFormatter) format_type_definition(sym &Symbol, cfg SymbolFormatterConfig) string {
	if isnil(sym) || sym.is_void() {
		return 'invalid symbol'
	}

	mut builder := strings.new_builder(50)

	if keywrod := sym.get_type_def_keyword() {
		builder.write_string('${keywrod} ')
	}

	match sym.kind {
		.interface_, .struct_ {
			fmt.format_with_builder(sym, mut builder, analyzer.types_format_cfg)
			if field_str := fmt.format_fields(sym) {
				builder.write_string('{\n')
				builder.write_string(field_str)
				builder.write_string('\n}')
			}
		}
		.sumtype, .typedef {
			fmt.format_with_builder(sym, mut builder, analyzer.types_format_cfg)
		}
		else {
			fmt.format_with_builder(sym, mut builder, analyzer.types_format_cfg)
		}
	}

	return builder.str()
}

pub fn (mut fmt SymbolFormatter) write_field(sym &Symbol, mut builder strings.Builder, cfg SymbolFormatterConfig) {
	builder.write_string(cfg.field_indent)
	builder.write_string(sym.name)
	builder.write_rune(` `)
	fmt.format_with_builder(sym.return_sym, mut builder, analyzer.child_types_format_cfg)
}

pub fn (mut fmt SymbolFormatter) format_fields(sym &Symbol, cfg SymbolFormatterConfig) ?string {
	field_syms := sym.get_fields() or { return none }

	mut builder := strings.new_builder(100)
	mut last_access := SymbolAccess.private

	mut is_dirty := false
	for field in field_syms {
		if os.dir(field.file_path) != fmt.context.file_dir
			&& int(field.access) < int(SymbolAccess.public) {
			continue
		} else if is_dirty {
			builder.write_byte(`\n`)
		}

		is_dirty = true
		if field.access != last_access {
			last_access = field.access
			builder.write_string('${last_access.str().trim_space()}: \n')
		}
		fmt.write_field(field, mut builder, cfg)
	}

	if !is_dirty {
		return none
	}

	return builder.str()
}

pub fn (mut fmt SymbolFormatter) format_methods(sym &Symbol, cfg SymbolFormatterConfig) ?string {
	method_syms := sym.get_methods() or { return none }

	mut builder := strings.new_builder(100)

	mut is_dirty := false
	for method in method_syms {
		if os.dir(method.file_path) != fmt.context.file_dir
			&& int(method.access) < int(SymbolAccess.public) {
			continue
		} else if is_dirty {
			builder.write_string('\n\n')
		}

		is_dirty = true
		fmt.format_with_builder(method, mut builder, analyzer.types_format_cfg)
	}

	if !is_dirty {
		return none
	}

	return builder.str()
}
