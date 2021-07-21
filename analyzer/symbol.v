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
	ref
	array_
	map_
	multi_return
	optional
	chan_
	function
	struct_
	enum_
	typedef
	interface_
	field
	placeholder
	variable
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
}

[heap]
pub struct Symbol {
pub mut:
	name                    string
	kind                    SymbolKind
	access                  SymbolAccess
	range                   C.TSRange
	parent                  &Symbol        = analyzer.void_type
	return_type             &Symbol        = analyzer.void_type
	language                SymbolLanguage = .v
	generic_placeholder_len int
	children                []&Symbol
	file_path               string
	file_version            int = 1
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

	sb.write_string(info.access.str())
	
	match info.kind {
		.ref {
			sb.write_string('&')
			sb.write_string(info.parent.gen_str())
		}
		.chan_ {
			sb.write_string('chan ')
			sb.write_string(info.children[0].str())
		}
		.optional {
			sb.write_string('?')
			if info.children.len >= 1 {
				sb.write_string(info.children[0].gen_str())
			} else {
				sb.write_string('<invalid type>')
			}
		}
		.map_, .array_ {
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
		.function {
			sb.write_string('fn ')

			if !isnil(info.parent) && !info.parent.is_void() {
				sb.write_b(`(`)
				sb.write_string(info.parent.gen_str())
				sb.write_b(`)`)
				sb.write_b(` `)
			}

			sb.write_string(info.name)
			sb.write_b(`(`)
			for i, v in info.children {
				sb.write_string(v.gen_str())
				if i < info.children.len - 1 {
					sb.write_string(', ')
				}
			}
			sb.write_string(') ')
			sb.write_string(info.return_type.gen_str())
		}
		.variable, .field {
			sb.write_string(info.name)
			sb.write_b(` `)
			sb.write_string(info.return_type.gen_str())
		}
		.typedef {
			sb.write_string(info.name)
			sb.write_string(' = ')
			sb.write_string(info.parent.gen_str())
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
