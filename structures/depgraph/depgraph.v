module depgraph

// Taken from: https://gist.github.com/Fordi/1706368
// Transpiled to ES6 for readability using Lebab: https://lebab.unibtc.me/editor
// Credits to: https://github.com/Fordi

[heap]
pub struct Tree {
mut:
	len    int
	keys   []string
	values []&Node
}

pub fn (tree &Tree) str() string {
	return tree.values.str()
}

pub fn (tree &Tree) has(id string) bool {
	return id in tree.keys
}

pub fn (mut tree Tree) add(id string, dependencies ...string) &Node {
	new_id := id
	tree.keys << new_id
	tree.values << &Node{tree, new_id, dependencies}
	defer {
		tree.len++
	}
	return tree.values[tree.values.len - 1]
}

pub fn (mut tree Tree) delete(id string) {
	idx := tree.keys.index(id)
	if idx == -1 {
		return
	}

	// unsafe {
	// tree.keys[idx].free()
	// tree.values[idx].free()
	tree.keys.delete(idx)
	tree.values.delete(idx)
	// }
	tree.len--
}

pub fn (tree &Tree) get_node(id string) !&Node {
	idx := tree.keys.index(id)
	if idx == -1 {
		return error('Node not found')
	}
	value := tree.values[idx] or { return error('') }
	return value
}

pub fn (tree &Tree) size() int {
	return tree.len
}

pub fn (tree &Tree) has_dependents(id string, excluded ...string) bool {
	for node in tree.values {
		if (excluded.len != 0 && node.id !in excluded) && id in node.dependencies {
			return true
		}
	}

	return false
}

pub fn (tree &Tree) get_available_nodes(completed ...string) []string {
	mut ret := []string{}
	for node in tree.values {
		deps := node.get_all_dependencies(...completed)
		if deps.len == 0 && node.id !in completed {
			ret << node.id
		}
	}

	return ret
}

[heap]
pub struct Node {
mut:
	tree &Tree = &Tree(0)
pub mut:
	id           string
	dependencies []string
}

pub fn (node &Node) str() string {
	return '${node.id} -> (${node.dependencies.join(', ')})'
}

pub fn (mut node Node) remove_dependency(dep_path string) int {
	if node.dependencies.len == 0 || dep_path.len == 0 {
		return -1
	}

	for i := 0; i < node.dependencies.len; i++ {
		if node.dependencies[i] == dep_path {
			node.dependencies.delete(i)
			return i
		}
	}

	return -2
}

pub fn (node &Node) get_all_dependencies(completed ...string) []string {
	mut ret := []string{}
	if isnil(node) {
		return ret
	}

	for d in node.dependencies {
		if completed.len == 0 || d !in completed {
			ret << d
		}
	}

	for d in node.dependencies {
		dep_node := node.tree.get_node(d) or {
			// eprintln('Node ${d}, referenced as a dependency of ${node.id} does not exist in the tree.')
			// return error
			continue
		}

		if isnil(dep_node) || isnil(dep_node.dependencies) {
			continue
		}

		other_deps := dep_node.get_all_dependencies()
		for other_dep in other_deps {
			if other_dep in ret || other_dep in completed {
				continue
			}

			// push if other_dep is not present in ret
			ret << other_dep
		}

		// unsafe { other_deps.free() }
	}

	return ret
}

pub fn (node &Node) get_next_nodes(completed ...string) []string {
	required_nodes := node.get_all_dependencies(...completed)
	available_nodes := node.tree.get_available_nodes(...completed)

	mut available_and_required := map[string]bool{}
	mut ret := []string{}

	for a in available_nodes {
		available_and_required[a] = false
	}

	for a in required_nodes {
		if a in available_and_required && !available_and_required[a] {
			available_and_required[a] = true
		}
	}

	for k, ar in available_and_required {
		if ar {
			ret << k
		}
	}

	// unsafe { available_and_required.free() }
	return ret
}

[unsafe]
pub fn (node &Node) free() {
	unsafe {
		// assume id has been freed
		// since they share the same address
		for i := 0; node.dependencies.len != 0; {
			// node.dependencies[i].free()
			node.dependencies.delete(i)
		}
	}
}
