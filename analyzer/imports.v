module analyzer

pub struct Import {
mut:
	// resolved indicates that an import's path has been resolved.
	resolved bool
	// imported indicates that the files of the modules are already imported.
	imported bool
pub mut:
	// absolute_module_name is the name that was declared when imported.
	absolute_module_name string
	// module_name is the name to be used for symbol lookups
	module_name string
	// path is the path where the module was located.
	path string
	// track the location of the import statements
	// this one uses the full path instead of the usual file name
	// for error reporting (just in case)
	ranges map[string]C.TSRange
	// original module_names are not recorded as aliases
	// e.g {'file.v': 'foo', 'file1.v': 'bar'}
	aliases map[string]string
	// e.g {'file.v': ['Any', 'decode', 'encode'], 'file2.v': ['foo']}
	symbols map[string][]string
}

// set_alias records/changes the alias of the import from the file
pub fn (mut imp Import) set_alias(file_name string, alias string) {
	if alias == imp.module_name {
		return
	}

	// if imp.aliases.len == 0 {
	// 	unsafe { imp.aliases[file_name].free() }
	// }

	imp.aliases[file_name] = alias
}

// track_file records the location of the import declaration of a file
pub fn (mut imp Import) track_file(file_name string, range C.TSRange) {
	if file_name in imp.ranges && range.eq(imp.ranges[file_name]) {
		return
	}

	imp.ranges[file_name] = range
}

// untrack_file removes the location of the import declaration of a file
pub fn (mut imp Import) untrack_file(file_name string) {
	if file_name in imp.ranges {
		imp.ranges.delete(file_name)
	}
}

// set_symbols records/changes the imported symbols on a specific file
pub fn (mut imp Import) set_symbols(file_name string, symbols ...string) {
	if file_name in imp.symbols {
		for i := 0; imp.symbols[file_name].len != 0; {
			// unsafe { imp.symbols[file_name][i].free() }
			imp.symbols[file_name].delete(i)
		}
		// unsafe { imp.symbols[file_name].free() }
	}

	imp.symbols[file_name] = symbols
}

// set_path changes the path of a given import
pub fn (mut imp Import) set_path(path string) {
	if path.len == 0 {
		return
	}

	imp.resolved = true
	imp.path = path
}

[unsafe]
pub fn (imp &Import) free() {
	unsafe {
		// imp.absolute_module_name.free()
		// imp.module_name.free()
		// imp.path.free()
		imp.ranges.free()
		imp.aliases.free()
		imp.symbols.free()
	}
}
