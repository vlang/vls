module main

import (
    compiler
    os
)

const (
	// JRPC_LSP_REQUEST_CANCELLED = -32800
    // JRPC_LSP_CONTENT_MODIFIED = -32801
)

struct Computed {
mut:
	modules []string
	structs []ItemType
	functions []ItemType
	variables []ItemType
	types []ItemType
}

struct ItemType {
	name string
	typ string
	mod string
	is_mut bool
	is_local bool
	is_arg bool
	is_public bool
mut:
	locals []ItemType
}

pub fn (itm_arr []ItemType) str() string {
	mut items := []string

	for item in itm_arr {
		items << item.str()
	}

	return items.str()
}

pub fn (item ItemType) str() string {
	return '{ name: "${item.name}", type: "${item.typ}", module: "${item.mod}", is_public: ${item.is_public}, locals: ${item.locals.len} }\n'
}

fn (typ_arr []ItemType) type_exists(name string) bool {
	for t in typ_arr {
		if t.name == name {
			return true
		}
	}

	return false
}

fn (c Computed) type_exists(name string, typ string) bool {
	typ_arr := match typ {
		'struct' { c.structs }
		'function' { c.functions }
		'variable' { c.variables }
		else { c.types }
	}

	return typ_arr.type_exists(name)
}

fn (c Computed) type_idx(name string, typ string) int {
	typ_arr := match typ {
		'struct' { c.structs }
		'function' { c.functions }
		'variable' { c.variables }
		else { c.types }
	}

	for i, t in typ_arr {
		if t.name == name {
			return i
		}
	}

	return -1
}

fn (lsp Lsp) analyze() {
	mut computed := Computed{}
	token_typ := ['builtin', 'struct', 'func', 'interface', 'enum', 'union', 'c_struct', 'c_typedef', 'objc_interface', 'array', 'alias']
	// set vroot folder
	compiler.set_vroot_folder(lsp.init.initialization_options.vroot_folder)

	mut v := compiler.new_v_compiler_with_args([lsp.file])
	v.add_v_files_to_compile()

	// get file
	// temp_out_file := os.getwd() + '/a.out.tmp.c'
	computed.modules = v.files

	// parse files
	for _, f in v.files {
		v.parse(f, .decl)

		for _, c in v.table.typesmap {
			typ_name := c.name.replace('Option_', '?').replace('array_', '[]').replace('array_', '[]').replace('map_', 'map[string]').replace('__', '.')
			typ_typ := token_typ[c.cat]
			if computed.type_exists(typ_name, typ_typ) { continue }
			if typ_typ == 'struct' {
				computed.structs << ItemType{
					name: typ_name,
					typ: typ_typ,
					mod: c.mod,
					locals: [],
					is_mut: false,
					is_local: false,
					is_arg: false,
					is_public: c.is_public
				}

				parent_idx_typ := computed.type_idx(typ_name, typ_typ)

				for cf in c.fields {
					if computed.structs[parent_idx_typ].locals.type_exists(cf.name) { continue }

					computed.structs[parent_idx_typ].locals << ItemType{
						name: cf.name,
						typ: cf.typ,
						mod: c.mod,
						locals: [],
						is_mut: cf.is_mut,
						is_local: true,
						is_arg: cf.is_arg,
						is_public: cf.is_public
					}
				}
			} else {
				computed.types << ItemType{
					name: typ_name,
					typ: typ_typ,
					mod: c.mod,
					locals: [],
					is_mut: false,
					is_local: false,
					is_arg: false,
					is_public: c.is_public
				}
			}
		}

		for _, c in v.table.fns {
			fn_mod := if c.v_fn_module() == 'builtin' { '' } else { c.v_fn_module() + '.' }
			fn_name := fn_mod + c.v_fn_name()

			if computed.type_exists(fn_name, 'function') { continue }

			// println(c.local_vars.len)

			computed.functions << ItemType {
				name: fn_name,
				typ: 'function',
				mod: c.v_fn_module(),
				locals: [],
				is_mut: true,
				is_local: false,
				is_arg: false,
				is_public: c.is_public
			}

			parent_idx_typ := computed.type_idx(fn_name, 'function')

			for _, cf in c.args {
				if computed.functions[parent_idx_typ].locals.type_exists(cf.name) { continue }

				computed.functions[parent_idx_typ].locals << ItemType {
					name: cf.name,
					typ: cf.typ,
					mod: c.v_fn_module(),
					locals: [],
					is_mut: cf.is_mut,
					is_local: true,
					is_arg: cf.is_arg,
					is_public: cf.is_public
				}
			}
		}
	}

	encoded := computed

	println(encoded)

	// // delete out file
	// if os.exists(temp_out_file) {
	// 	os.rm(temp_out_file)
	// } else {
	// 	os.rm(os.getwd() + '.out.c')
	// }
}