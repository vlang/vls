module analyzer

import os

pub fn register_builtin_symbols(mut ss Store) {
	builtin_path := ss.auto_imports['']
	placeholder_file_path := os.join_path(builtin_path, 'placeholder.vv')
	defer { unsafe { placeholder_file_path.free() } }
	builtin_types := [
		'voidptr'
		'byteptr'
		'charptr'
		'i8'
		'i16'
		'int'
		'i64'
		'byte'
		'u16'
		'u32'
		'u64'
		'f32'
		'f64'
		'char'
		'bool'
		'none'
		'string'
		'rune'
		'array'
		'map'
		'chan'
		'size_t'
		'float_literal'
		'int_literal'
		'thread'
		'IError'
	]

	for type_name in builtin_types {
		mut builtin_sym := Symbol{
			name: type_name 
			kind: .placeholder
			access: .public
			file_path: placeholder_file_path
		}

		ss.register_symbol(mut builtin_sym) or {
			eprintln('$type_name registration is skipped. Reason: $err')
			continue
		}
	}
}