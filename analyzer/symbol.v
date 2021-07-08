module analyzer
// it should be imported just to have those C type symbols available
// import tree_sitter
// import os

import strings

pub interface ISymbol {
	str() string
mut:
	range C.TSRange
	parent ISymbol
}

pub fn (isym ISymbol) root() &Symbol {
	if isym is Symbol {
		return isym
	} else if isym.parent is Symbol {
		return isym.parent
	}

	return isym.parent.root()
}

pub enum SymbolKind {
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

pub const void_type = &Symbol{ name: 'void' }

[heap]
pub struct Symbol {
pub mut:
	name string
	kind SymbolKind
	access SymbolAccess
	range C.TSRange
	parent ISymbol = analyzer.void_type
	return_type ISymbol = analyzer.void_type
	language SymbolLanguage = .v
	generic_placeholder_len int
	children map[string]&Symbol
	file_path string
}

pub fn (info &Symbol) str() string {
	mut sb := strings.new_builder(100)
	defer { unsafe { sb.free() } }

	match info.kind {
		.function {
			sb.write_string(info.kind.str())
			sb.write_string('fn ')
			sb.write_string(info.name)
			sb.write_b(`(`)
			mut i := 0
			for _, v in info.children {
				sb.write_string(v.str())
				if i < info.children.len - 1 {
					sb.write_b(`,`)
					sb.write_b(` `)
				}
			}
			sb.write_b(`)`)
			sb.write_b(` `)
			sb.write_string(info.return_type.str())
			return sb.str()
		}
		.variable, .field {
			sb.write_string(info.name)
			sb.write_b(` `)
			sb.write_string(info.return_type.str())
		}
		else { 
			sb.write_string(info.name) 
		}
	}

	return sb.str()
}

pub fn (infos []&Symbol) str() string {
	return '[' +  infos.map(it.str()).join(', ') + ']'
}

pub fn (mut info Symbol) add_child(new_child ISymbol) ? {
	if new_child is Symbol {
		mut nc := new_child
		if nc.name in info.children {
			return error('child exists. (name="$new_child.name")')
		}

		nc.parent = info
		info.children[nc.name] = new_child
		return
	}

	return error('not a symbol')
}

[unsafe]
pub fn (sym &Symbol) free() {
	unsafe {
		sym.name.free()
		
		for _, v in sym.children {
			v.free()
		}
	
		sym.children.free()
		sym.file_path.free()
	}
}

pub struct ArraySymbol {
pub mut:
	range C.TSRange
	parent ISymbol
}

pub fn (ars ArraySymbol) str() string {
	return '[]' + ars.str()
}

pub struct RefSymbol {
pub mut:
	ref_count int = 1
	range C.TSRange
	parent ISymbol
}

pub fn (rs RefSymbol) str() string {
	return '&'.repeat(rs.ref_count) + rs.parent.str()
}

pub struct MapSymbol {
pub mut:
	range C.TSRange
	key_parent ISymbol // string in map[string]Foo
	parent ISymbol // Foo in map[string]Foo
}

pub fn (ms MapSymbol) str() string {
	return 'map[${ms.key_parent}]${ms.parent}'
}

pub struct ChanSymbol {
pub mut:
	range C.TSRange
	parent ISymbol
}

pub fn (cs ChanSymbol) str() string {
	return 'chan ${cs.parent}'
}