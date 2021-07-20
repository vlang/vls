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

pub fn (scope &ScopeTree) contains(pos u32) bool {
	return pos >= scope.start_byte && pos <= scope.end_byte
}

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

// pub fn (mut scope ScopeTree) remove(name string) bool {
// 	idx := scope.symbols.index(name)
// 	if idx == -1 {
// 		return false
// 	}

// 	scope.symbols.delete(idx)
// 	return true
// }