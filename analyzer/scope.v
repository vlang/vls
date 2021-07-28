module analyzer

pub struct ScopeTree {
mut:
	parent     &ScopeTree = &ScopeTree(0)
	start_byte u32
	end_byte   u32
	symbols    []&Symbol
	children   []&ScopeTree
}

pub fn (scope &ScopeTree) str() string {
	return if isnil(scope) {
		'<nil scope>'
	} else {
		scope.symbols.str()
	}
}

[unsafe]
pub fn (scope &ScopeTree) free() {
	if isnil(scope) {
		return
	}

	// TODO: incremental add/delete scope
	unsafe {
		for i := 0; scope.symbols.len != 0; {
			scope.symbols[i].free()
			scope.symbols.delete(i)
		}

		for i := 0; scope.children.len != 0; {
			scope.children[i].free()
			scope.children.delete(i)
		}
	}
}

// contains checks if a given position is within the scope's range
pub fn (scope &ScopeTree) contains(pos u32) bool {
	return pos >= scope.start_byte && pos <= scope.end_byte
}

// innermost returns the scope based on the given byte ranges
pub fn (scope &ScopeTree) innermost(start_byte u32, end_byte u32) &ScopeTree {
	if !isnil(scope) {
		for mut child_scope in scope.children {
			if child_scope.contains(start_byte) && child_scope.contains(end_byte) {
				return child_scope.innermost(start_byte, end_byte)
			}
		}
	}

	return unsafe { scope }
}

// register registers the symbol to the scope
pub fn (mut scope ScopeTree) register(info &Symbol) ? {
	// Just to ensure that scope is not null
	if isnil(scope) {
		return
	}

	mut existing_idx := scope.symbols.index(info.name)
	if existing_idx != -1 {
		mut existing_sym := scope.symbols[existing_idx]
		// unsafe { scope.symbols[existing_idx].free() }
		if existing_sym.file_version >= info.file_version {
			return error('Symbol already exists. (Scope Range=${scope.start_byte}-${scope.end_byte}) (idx=${existing_idx}) (name="$existing_sym.name")')
		}

		if existing_sym.name != info.name {
			existing_sym.name = info.name.clone()
		}

		existing_sym.return_type = info.return_type
		existing_sym.access = info.access
		existing_sym.range = info.range
		existing_sym.file_path = info.file_path
		existing_sym.file_version = info.file_version
	} else {
		scope.symbols << info
	}

	if info.range.start_byte < scope.start_byte {
		scope.start_byte = info.range.start_byte
	}
}

pub fn (scope &ScopeTree) get_all_symbols() []&Symbol {
	if isnil(scope) {
		return []&Symbol{}
	}
	return scope.symbols
}

// get_scope retrieves a specified symbol from the scope
pub fn (scope &ScopeTree) get_symbol(name string) ?&Symbol {
	if isnil(scope) {
		return none
	}

	return scope.symbols.get(name)
}

// new_child removes a child scope
pub fn (mut scope ScopeTree) new_child(start_byte u32, end_byte u32) ?&ScopeTree {
	if isnil(scope) {
		return none
	}

	innermost := scope.innermost(start_byte, end_byte)
	if innermost == scope {
		scope.children << &ScopeTree{
			start_byte: start_byte
			end_byte: end_byte
			parent: unsafe { scope }
		}

		return scope.children.last()
	}

	return innermost
}

// remove_child removes a child scope based on the given position
pub fn (mut scope ScopeTree) remove_child(start_byte u32, end_byte u32) bool {
	if isnil(scope) {
		return false
	}

	if start_byte == scope.start_byte && end_byte == scope.end_byte {
		unsafe { scope.free() }
		return true
	}

	for i := 0; i < scope.children.len; i++ {
		if !scope.children[i].remove_child(start_byte, end_byte) {
			continue
		}
	}

	return false
}

// remove removes the specified symbol
pub fn (mut scope ScopeTree) remove(name string) bool {
	if isnil(scope) {
		return false
	}

	idx := scope.symbols.index(name)
	if idx == -1 {
		return false
	}

	scope.symbols.delete(idx)
	return true
}