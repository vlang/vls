module analyzer

// it should be imported just to have those C type symbols available
// import tree_sitter
// import os
import strings

// pub interface ISymbol {
// 	str() string
// mut:
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (isym ISymbol) root() &Symbol {
// 	if isym is Symbol {
// 		return isym
// 	} else if isym.parent is Symbol {
// 		return isym.parent
// 	}

// 	return isym.parent.root()
// }

// TODO: From ref to chan_, use interface

pub enum SymbolKind {
	void
	placeholder
	ref
	array_
	map_
	multi_return
	optional
	chan_
	variadic
	function
	struct_
	enum_
	typedef
	interface_
	field
	embedded_field
	variable
	sumtype
	function_type
}

pub enum SymbolLanguage {
	c
	js
	v
}

// pub enum Platform {
// 	auto
// 	ios
// 	macos
// 	linux
// 	windows
// 	freebsd
// 	openbsd
// 	netbsd
// 	dragonfly
// 	js
// 	android
// 	solaris
// 	haiku
// 	cross
// }

pub enum SymbolAccess {
	private
	private_mutable
	public
	public_mutable
	global
}

pub fn (sa SymbolAccess) str() string {
	return match sa {
		.private { '' }
		.private_mutable { 'mut ' }
		.public { 'pub ' }
		.public_mutable { 'pub mut ' }
		.global { '__global ' }
	}
}

pub const void_type = &Symbol{ 
	name: 'void'
	kind: .void 
	file_path: ''
	file_version: 0
	is_top_level: true
}

[heap]
pub struct Symbol {
pub mut:
	name                    string
	kind                    SymbolKind // see SymbolKind
	access                  SymbolAccess // see SymbolAccess
	range                   C.TSRange
	parent                  &Symbol        = analyzer.void_type // parent is for typedefs, aliases
	return_type             &Symbol        = analyzer.void_type // return_type is for functions and variables
	language                SymbolLanguage = .v
	is_top_level						bool [required]
	generic_placeholder_len int
	sumtype_children_len    int
	interface_children_len  int
	children                []&Symbol // methods, sum types, map types, optionals, struct fields, etc.
	file_path               string [required] // required in order to register the symbol at its appropriate directory.
	file_version            int [required]// file version when the symbol was registered
}

const kinds_in_multi_return_to_be_excluded = [SymbolKind.function, .variable, .field]

// gen_str returns the string representation of a symbol.
// Use this since str() has a pointer symbol attached at the beginning.
pub fn (info &Symbol) gen_str() string {
	if isnil(info) {
		return 'nil symbol'
	}

	mut sb := strings.new_builder(100)
	defer {
		unsafe { sb.free() }
	}

	// sb.write_string(info.access.str())
	
	match info.kind {
		.ref {
			sb.write_string('&')
			sb.write_string(info.parent.gen_str())
		}
		.chan_ {
			sb.write_string('chan ')
			sb.write_string(info.parent.gen_str())
		}
		.optional {
			sb.write_string('?')
			sb.write_string(info.parent.gen_str())
		}
		.map_, .array_, .variadic {
			sb.write_string(info.name)
		}
		// .array_ {
		// 	sb.write_string('[]')
		// 	sb.write_string(info.children[0].str())
		// }
		.multi_return {
			sb.write_b(`(`)
			for v in info.children {
				if v.kind !in kinds_in_multi_return_to_be_excluded {
					sb.write_string(v.gen_str())
				}
			}
			sb.write_b(`)`)
		}
		.function, .function_type {
			sb.write_string(info.access.str())
			sb.write_string('fn ')

			if !isnil(info.parent) && !info.parent.is_void() {
				sb.write_b(`(`)
				sb.write_string(info.parent.gen_str())
				sb.write_b(`)`)
				sb.write_b(` `)
			}

			if !info.name.starts_with(analyzer.anon_fn_prefix) {
				sb.write_string(info.name)
			}

			sb.write_b(`(`)
			for i, v in info.children {
				if v.name.len != 0 {
					sb.write_string(v.gen_str())
				} else {
					sb.write_string(v.return_type.gen_str())
				}
				if i < info.children.len - 1 {
					sb.write_string(', ')
				}
			}
			sb.write_string(') ')
			sb.write_string(info.return_type.name)
		}
		.variable, .field {
			sb.write_string(info.access.str())
			if info.kind == .field {
				sb.write_b(`(`)
				sb.write_string(info.parent.gen_str())
				sb.write_b(`)`)
				sb.write_b(`.`)
			}

			sb.write_string(info.name)
			sb.write_b(` `)
			if info.return_type.kind == .function_type {
				sb.write_string(info.return_type.gen_str())
			} else {
				sb.write_string(info.return_type.name)
			}
		}
		.typedef, .sumtype {
			if info.kind == .typedef && info.parent.is_void() {
				return info.name	
			}

			sb.write_string('type ')
			sb.write_string(info.name)
			sb.write_string(' = ')
			
			if info.kind == .typedef {
				if info.parent.kind == .function_type {
					sb.write_string(info.parent.gen_str())
				} else {
					sb.write_string(info.parent.name)
				}
			} else {
				for i in 0 .. info.sumtype_children_len {
					sb.write_string(info.children[i].name)
					if i < info.sumtype_children_len - 1{
						sb.write_b(` `)
						sb.write_b(`|`)
						sb.write_b(` `)
					}
				}
			}
		}
		else {
			// sb.write_string(info.kind.str())
			// sb.write_b(` `)
			sb.write_string(info.name)
		}
	}

	return sb.str()
}

pub fn (sym &Symbol) str() string {
	return sym.gen_str()
}

pub fn (infos []&Symbol) str() string {
	return '[' + infos.map(it.gen_str()).join(', ') + ']'
}

// index returns the index based on the given symbol name
pub fn (infos []&Symbol) index(name string) int {
	for i, v in infos {
		if v.name == name {
			return i
		}
	}

	return -1
}

// index_by_row returns the index based on the given file path and row
pub fn (infos []&Symbol) index_by_row(file_path string, row u32) int {
	for i, v in infos {
		if v.file_path == file_path && v.range.start_point.row == row {
			return i
		}
	}

	return -1
}

pub fn (symbols []&Symbol) filter_by_file_path(file_path string) []&Symbol {
	mut filtered := []&Symbol{}
	for sym in symbols {
		if sym.file_path == file_path {
			filtered << sym
		}

		filtered_from_children := sym.children.filter_by_file_path(file_path)
		for child_sym in filtered_from_children {
			if filtered.exists(child_sym.name) {
				continue
			}
			filtered << child_sym
		}
		unsafe{ filtered_from_children.free() }
	}
	return filtered
}

// pub fn (mut infos []&Symbol) remove_symbol_by_range(file_path string, range C.TSRange) {
// 	mut to_delete_i := -1
// 	for i, v in infos {
// 		// not the best solution so far :(
// 		if v.file_path == file_path {
// 			eprintln('${v.name} ${v.range}')
// 		}
// 		if v.file_path == file_path && v.range.eq(range) {
// 			eprintln('deleted ${v.name}')
// 			to_delete_i = i
// 			break
// 		}
// 	}

// 	if to_delete_i == -1 {
// 		return
// 	}

// 	unsafe { infos[to_delete_i].free() }
// 	infos.delete(to_delete_i)
// }

// exists checks if a symbol is present
pub fn (infos []&Symbol) exists(name string) bool {
	return infos.index(name) != -1
}


// get retreives the symbol based on the given name
pub fn (infos []&Symbol) get(name string) ?&Symbol {
	index := infos.index(name)
	if index == -1 {
		return error('Symbol `$name` not found')
	}

	return infos[index] ?
}

// add_child registers the symbol as a child of a given parent symbol
pub fn (mut info Symbol) add_child(mut new_child Symbol, add_as_parent ...bool) ? {
	if add_as_parent.len == 0 || add_as_parent[0] {
		new_child.parent = unsafe { info }
	}

	if info.children.exists(new_child.name) {
		return error('child exists. (name="$new_child.name")')
	}

	info.children << new_child
}

// is_void returns true if a symbol is void/invalid
pub fn (sym &Symbol) is_void() bool {
	if (sym.kind == .ref || sym.kind == .array_) && sym.children.len >= 1 {
		return sym.children[0].is_void()
	}

	return sym.kind == .void
}

pub fn (sym &Symbol) is_returnable() bool {
	return sym.kind == .variable || sym.kind == .field || sym.kind == .function
}

pub fn (sym &Symbol) is_mutable() bool {
	return sym.access == .private_mutable || sym.access == .public_mutable || sym.access == .global
}

[unsafe]
pub fn (sym &Symbol) free() {
	unsafe {
		sym.name.free()

		for v in sym.children {
			v.free()
		}

		sym.children.free()
		// sym.file_path.free()
	}
}

fn (sym &Symbol) value_sym() &Symbol {
	if sym.kind == .array_ {
		return sym.children[0] or { analyzer.void_type }
	} else if sym.kind == .map_ {
		return sym.children[1] or { analyzer.void_type }
	} else {
		return analyzer.void_type
	}
}

fn (sym &Symbol) count_ptr() int {
	mut ptr_count := 0
	mut starting_sym := sym
	for !isnil(starting_sym) && starting_sym.kind == .ref {
		ptr_count++
	}
	return ptr_count
}

pub fn is_interface_satisfied(sym &Symbol, interface_sym &Symbol) bool {
	if sym.kind != .struct_ && sym.kind != .typedef && sym.kind != .sumtype {
		return false
	} else if interface_sym.kind != .interface_ {
		return false
	}

	for i in 0 .. interface_sym.interface_children_len {
		spec_sym := interface_sym.children[i]
		selected_child_sym := sym.children.get(spec_sym.name) or {
			return false
		}
		if spec_sym.kind == .field {
			if selected_child_sym.access != spec_sym.access 
				|| selected_child_sym.kind != spec_sym.kind 
				|| selected_child_sym.return_type != spec_sym.return_type {
				return false
			}
		} else if spec_sym.kind == .function {
			if selected_child_sym.kind != spec_sym.kind
				|| !compare_params_and_ret_type(selected_child_sym.children, selected_child_sym.return_type, spec_sym, false) {
				return false
			}
		}
	}
	return true
}

// pub fn (ars ArraySymbol) str() string {
// 	return
// }

// pub struct RefSymbol {
// pub mut:
// 	ref_count int = 1
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (rs RefSymbol) str() string {
// 	return '&'.repeat(rs.ref_count) + rs.parent.str()
// }

// pub struct MapSymbol {
// pub mut:
// 	range C.TSRange
// 	key_parent ISymbol // string in map[string]Foo
// 	parent ISymbol // Foo in map[string]Foo
// }

// pub fn (ms MapSymbol) str() string {
// 	return 'map[${ms.key_parent}]${ms.parent}'
// }

// pub struct ChanSymbol {
// pub mut:
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (cs ChanSymbol) str() string {
// 	return 'chan ${cs.parent}'
// }

// pub struct OptionSymbol {
// pub mut:
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (opts OptionSymbol) str() string {
// 	return '?${opts.parent}'
// }

pub struct BaseSymbolLocation {
	module_name string
	symbol_name string
	for_kind SymbolKind
}