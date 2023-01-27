module analyzer

// it should be imported just to have those C type symbols available
// import tree_sitter
// import os

// pub interface ISymbol {
// 	str() string
// mut:
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (isym ISymbol) root() &Symbol {
// 	if isym is Symbol {
// 		return isym
// 	} else if isym.parent_sym is Symbol {
// 		return isym.parent_sym
// 	}

// 	return isym.parent_sym.root()
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
	result
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

pub fn (kind SymbolKind) str() string {
	match kind {
		.void { return 'void' }
		.placeholder { return 'placeholder' }
		.ref { return 'ref' }
		.array_ { return 'array' }
		.map_ { return 'map' }
		.multi_return { return 'multi_return' }
		.optional { return 'optional' }
		.result { return 'result' }
		.chan_ { return 'chan' }
		.variadic { return 'variadic' }
		.function { return 'function' }
		.struct_ { return 'struct' }
		.enum_ { return 'enum' }
		.typedef { return 'typedef' }
		.interface_ { return 'interface' }
		.field { return 'field' }
		.embedded_field { return 'embedded_field' }
		.variable { return 'variable' }
		.sumtype { return 'sumtype' }
		.function_type { return 'function_type' }
	}
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

pub const void_sym = &Symbol{
	name: 'void'
	kind: .void
	file_path: ''
	file_version: 0
	is_top_level: true
}

pub const void_sym_arr = [void_sym]

[heap]
pub struct Symbol {
pub mut:
	name                    string
	kind                    SymbolKind   // see SymbolKind
	access                  SymbolAccess // see SymbolAccess
	range                   C.TSRange
	parent_sym              &Symbol        = analyzer.void_sym // parent_sym is for typedefs, aliases
	return_sym              &Symbol        = analyzer.void_sym // return_sym is for functions and variables
	language                SymbolLanguage = .v
	is_top_level            bool           [required]
	is_const                bool
	generic_placeholder_len int
	sumtype_children_len    int
	interface_children_len  int
	children_syms           []&Symbol // methods, sum types, map types, optionals, struct fields, etc.
	file_path               string         [required] // required in order to register the symbol at its appropriate directory.
	file_version            int            [required] // file version when the symbol was registered
	scope                   &ScopeTree = &ScopeTree(0)
}

const kinds_in_multi_return_to_be_excluded = [SymbolKind.function, .variable, .field]

[params]
pub struct SymbolGenStrConfig {
	module_prefix string
	with_kind     bool = true
	with_access   bool = true
	with_contents bool = true
}

const child_cfg = SymbolGenStrConfig{
	with_kind: false
	with_access: false
	with_contents: false
}

pub fn (sym &Symbol) str() string {
	if isnil(sym) {
		return 'nil symbol'
	}

	return sym.name
}

const sym_kinds_allowed_to_print_parent = [SymbolKind.typedef, .function]

pub fn (infos []&Symbol) str() string {
	return '[' + infos.map(it.str()).join(', ') + ']'
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

		filtered_from_children := sym.children_syms
			.filter(!symbols.exists(it.name))
			.filter_by_file_path(file_path)
		for child_sym in filtered_from_children {
			if filtered.exists(child_sym.name) {
				continue
			}
			filtered << child_sym
		}
		// unsafe { filtered_from_children.free() }
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
		return none
	}
	info := infos[index] or { return none }
	return info
}

// add_child registers the symbol as a child of a given parent symbol
pub fn (mut info Symbol) add_child(mut new_child_sym Symbol, add_as_parent ...bool) ! {
	if add_as_parent.len == 0 || add_as_parent[0] {
		new_child_sym.parent_sym = unsafe { info }
	}

	if info.children_syms.exists(new_child_sym.name) {
		return error('child exists. (name="$new_child_sym.name")')
	}

	info.children_syms << new_child_sym
}

// is_void returns true if a symbol is void/invalid
pub fn (sym &Symbol) is_void() bool {
	if (sym.kind == .ref || sym.kind == .array_) && sym.children_syms.len >= 1 {
		return sym.children_syms[0].is_void()
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
		for v in sym.children_syms {
			v.free()
		}
		sym.children_syms.free()
	}
}

fn (sym &Symbol) value_sym() &Symbol {
	if sym.kind == .array_ {
		return sym.children_syms[0] or { analyzer.void_sym }
	} else if sym.kind == .map_ {
		return sym.children_syms[1] or { analyzer.void_sym }
	} else {
		return analyzer.void_sym
	}
}

fn (sym &Symbol) count_ptr() int {
	mut ptr_count := 0
	mut starting_sym := unsafe { sym }
	for !isnil(starting_sym) && starting_sym.kind == .ref {
		ptr_count++
	}
	return ptr_count
}

// final_sym returns the final symbol to be returned
// from container symbols (optional types, channel types, and etc.)
pub fn (sym &Symbol) final_sym() &Symbol {
	match sym.kind {
		.optional, .result {
			return sym.parent_sym
		}
		else {
			return sym
		}
	}
}

pub fn is_interface_satisfied(sym &Symbol, interface_sym &Symbol) bool {
	if sym.kind != .struct_ && sym.kind != .typedef && sym.kind != .sumtype {
		return false
	} else if interface_sym.kind != .interface_ {
		return false
	}

	for i in 0 .. interface_sym.interface_children_len {
		spec_sym := interface_sym.children_syms[i]
		selected_child_sym := sym.children_syms.get(spec_sym.name) or { return false }
		if spec_sym.kind == .field {
			if selected_child_sym.access != spec_sym.access
				|| selected_child_sym.kind != spec_sym.kind
				|| selected_child_sym.return_sym != spec_sym.return_sym {
				return false
			}
		} else if spec_sym.kind == .function {
			if selected_child_sym.kind != spec_sym.kind
				|| !compare_params_and_ret_type(selected_child_sym.children_syms, selected_child_sym.return_sym, spec_sym, false) {
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
// 	return '&'.repeat(rs.ref_count) + rs.parent_sym.str()
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
// 	return '!${opts.parent}'
// }

pub struct BaseSymbolLocation {
pub:
	module_name string
	symbol_name string
	for_kind    SymbolKind
}

pub struct BindedSymbolLocation {
pub:
	for_sym_name string
	language     SymbolLanguage
	module_path  string
}

fn (locs []BindedSymbolLocation) get_path(sym_name string) !string {
	idx := locs.index(sym_name)
	if idx != -1 {
		return locs[idx].module_path
	}
	return error('not found!')
}

fn (locs []BindedSymbolLocation) index(sym_name string) int {
	for i, bsl in locs {
		if bsl.for_sym_name == sym_name {
			return i
		}
	}
	return -1
}
