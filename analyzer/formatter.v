module analyzer

import strings

pub struct SymbolFormatter {
mut:
	context   AnalyzerContext
	replacers []string
}

[params]
pub struct SymbolFormatterConfig {
	with_kind     bool = true
	with_access   bool = true
	with_contents bool = true
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

fn (fmt &SymbolFormatter) write_docstrings(docstrings []string, mut builder strings.Builder) {
	if docstrings.len == 0 {
		return
	}

	builder.write_byte(`\n`)

	mut need_newline := true
	for ds in docstrings {
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
		} else {
			builder.write_byte(` `)
		}

		builder.write_string(ds)

		// append newline check
		need_newline = false
		if ds.ends_with('.') || ds.ends_with('|') || is_header || is_hr {
			need_newline = true
			continue
		}
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
				fmt.format_with_builder(sym.return_sym, mut builder, analyzer.types_format_cfg)
			}

			fmt.write_docstrings(sym.docstrings, mut builder)
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
			fmt.format_with_builder(sym.parent_sym, mut builder, analyzer.types_format_cfg)
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
					for i in 0 .. sym.sumtype_children_len {
						fmt.format_with_builder(sym.children_syms[i], mut builder, analyzer.child_types_format_cfg)

						if i < sym.sumtype_children_len - 1 {
							builder.write_string(' | ')
						}
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
