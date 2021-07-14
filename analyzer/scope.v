module analyzer

pub struct ScopeTree {
pub mut:
	parent     &ScopeTree = &ScopeTree(0)
	start_byte u32
	end_byte   u32
	symbols    []&Symbol
	children   []&ScopeTree
}

[unsafe]
pub fn (scope &ScopeTree) free() {
	unsafe {
		// for _, s in scope.symbols {
		// 	s.free()
		// }

		for c in scope.children {
			c.free()
		}
	}
}

pub fn (scope &ScopeTree) contains(pos u32) bool {
	return pos >= scope.start_byte && pos <= scope.end_byte
}

pub fn (scope &ScopeTree) innermost(pos u32) &ScopeTree {
	for child_scope in scope.children {
		if child_scope.contains(pos) {
			return child_scope.innermost(pos)
		}
	}

	return unsafe { scope }
}

pub fn (mut scope ScopeTree) register(info &Symbol) {
	// Just to ensure that scope is not null
	if isnil(scope) {
		return
	}

	existing_idx := scope.symbols.index(info.name)
	if existing_idx != -1 {
		unsafe { scope.symbols[existing_idx].free() }
		scope.symbols.delete(existing_idx)
	}

	scope.symbols << info
}
