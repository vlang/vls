module analyzer

import os

const numeric_types = ['u8', 'u16', 'u32', 'u64', 'i8', 'i16', 'int', 'i64', 'f32', 'f64']
const numeric_types_with_any_type = ['u8', 'u16', 'u32', 'u64' 'i8', 'i16', 'int', 'i64', 'f32', 'f64', 'int_literal', 'float_literal']

pub fn setup_builtin(mut store Store, builtin_path string) {
	mut importer := Importer{
		context: store.default_context()
	}
	
	mut builtin_import, builtin_idx, _ := store.add_import(
		'',
		resolved: true
		module_name: 'builtin'
		path: builtin_path
	)

	store.register_auto_import(builtin_import, '')
	register_builtin_symbols(mut store, builtin_import)
	importer.import_modules(mut store.imports[importer.context.file_dir], [builtin_idx])
	register_none(mut store, builtin_import)
}

fn register_none(mut ss Store, builtin_import &Import) {
	registered_none_sym := ss.symbols[builtin_import.path].get('None__') or {
		return
	}

	mut none_sym := Symbol{
		name: 'none'
		kind: .typedef
		access: .public
		parent_sym: &Symbol{
			name: '&' + registered_none_sym.name
			is_top_level: true
			file_path: registered_none_sym.file_path
			parent_sym: registered_none_sym
			kind: .ref
			file_version: 0
		}
		is_top_level: true
		file_path: registered_none_sym.file_path
		file_version: 0
	}

	ss.register_symbol(mut none_sym) or {
		eprintln('none registration is skipped. Reason: $err')
	}
}

fn register_builtin_symbols(mut ss Store, builtin_import &Import) {
	builtin_path := builtin_import.path
	placeholder_file_path := os.join_path(builtin_path, 'placeholder.vv')
	// defer {
	// unsafe { placeholder_file_path.free() }
	// }

	builtin_types := [
		'voidptr',
		'byteptr',
		'charptr',
		'i8',
		'i16',
		'int',
		'i64',
		'byte',
		'u8',
		'u16',
		'u32',
		'u64',
		'f32',
		'f64',
		'char',
		'bool',
		'string',
		'rune',
		'array',
		'map',
		'chan',
		'size_t',
		'float_literal',
		'int_literal',
		'thread',
		'IError',
	]

	should_be_placeholders := ['IError', 'string', 'array', 'map']

	for type_name in builtin_types {
		mut builtin_sym := Symbol{
			name: type_name
			kind: .placeholder
			access: .public
			is_top_level: true
			file_path: placeholder_file_path
			file_version: if type_name in should_be_placeholders { -1 } else { 0 }
		}

		ss.register_symbol(mut builtin_sym) or {
			eprintln('$type_name registration is skipped. Reason: $err')
			continue
		}
	}

	for type_name in builtin_types {
		mut returned_sym := ss.symbols[builtin_path].get(type_name) or { continue }

		if type_name == 'string' {
			// register []string
			mut array_sym := Symbol{
				name: '[]' + type_name
				kind: .array_
				access: .public
				is_top_level: true
				children_syms: [returned_sym]
				file_path: os.join_path(builtin_path, 'array.vv')
				file_version: 0
			}

			ss.register_symbol(mut array_sym) or {
				eprintln('$array_sym.name registration is skipped. Reason: $err')
				continue
			}
		}

		if returned_sym.name !in should_be_placeholders {
			returned_sym.kind = .typedef
		}

		match returned_sym.name {
			'array' {
				ss.base_symbol_locations << BaseSymbolLocation{
					module_name: ''
					symbol_name: returned_sym.name
					for_kind: .array_
				}

				ss.base_symbol_locations << BaseSymbolLocation{
					module_name: ''
					symbol_name: returned_sym.name
					for_kind: .variadic
				}
			}
			'map' {
				ss.base_symbol_locations << BaseSymbolLocation{
					module_name: ''
					symbol_name: returned_sym.name
					for_kind: .map_
				}
			}
			'chan' {
				ss.base_symbol_locations << BaseSymbolLocation{
					module_name: ''
					symbol_name: returned_sym.name
					for_kind: .chan_
				}
			}
			'IError' {
				ss.base_symbol_locations << BaseSymbolLocation{
					module_name: ''
					symbol_name: returned_sym.name
					for_kind: .optional
				}
			}
			else {}
		}
	}
}
