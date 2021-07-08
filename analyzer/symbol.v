module analyzer
// it should be imported just to have those C type symbols available
// import tree_sitter
// import os

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

pub const void_type = &Symbol{ name: 'void' }

[heap]
pub struct Symbol {
pub mut:
	name string
	kind SymbolKind
	access SymbolAccess
	range C.TSRange
	parent &Symbol = analyzer.void_type
	return_type &Symbol = analyzer.void_type
	language SymbolLanguage = .v
	generic_placeholder_len int
	children map[string]&Symbol
	file_path string
}

pub fn (info &Symbol) str() string {
	typ := if isnil(info.return_type) { 'void' } else { info.return_type.name }
	return '(${info.access} ${info.kind} ${info.name} -> ($typ) ${info.children})'
}

pub fn (infos []&Symbol) str() string {
	return '[' +  infos.map(it.str()).join(', ') + ']'
}

pub fn (mut info Symbol) add_child(mut new_child Symbol) ? {
	if new_child.name in info.children {
		return error('child exists. (name="$new_child.name")')
	}

	new_child.parent = info
	info.children[new_child.name] = new_child
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

