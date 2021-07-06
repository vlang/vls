module depgraph

// Taken from: https://gist.github.com/Fordi/1706368
// Transpiled to ES6 for readability using Lebab: https://lebab.unibtc.me/editor
// Credits to: https://github.com/Fordi

pub struct Tree {
mut:
	nodes map[string]&Node
}

pub fn (tree &Tree) str() string {
	return tree.nodes.str()
}

pub fn (tree &Tree) has(id string) bool {
	return id in tree.nodes
}

pub fn (tree &Tree) has_dependents(id string, excluded ...string) bool {
	for _, node in tree.nodes {
		if id !in excluded && id in node.dependencies {
			return true
		}
	}

	return false
}

pub fn (mut tree Tree) delete(nid string) {
	mut node := tree.nodes[nid] or { return }
	for i := 0; node.dependencies.len != 0; {
		unsafe { node.dependencies[i].free() }
		node.dependencies.delete(i)
	}

	unsafe {
		node.dependencies.free()
		node.id.free()
	}

	tree.nodes.delete(nid)
}

pub fn (mut tree Tree) add(node Node) &Node {
	tree.nodes[node.id] = &Node{
		id: node.id.clone()
		dependencies: node.dependencies.clone()
		tree: unsafe { tree }
	} 

	return tree.nodes[node.id]
}

pub fn (tree &Tree) get_node(id string) ?&Node {
	return tree.nodes[id] ?
}

pub fn (tree &Tree) get_nodes() map[string]&Node {
	return tree.nodes
}

pub fn (tree &Tree) get_available_nodes(completed ...string) []string {
	mut ret := []string{}
	for node_id, node in tree.nodes {
		deps := node.get_all_dependencies(...completed)
		if deps.len == 0 && node_id !in completed {
			ret << node_id
		}
	}

	return ret
}

[heap]
pub struct Node {
mut:
	tree &Tree = &Tree(0)
pub mut:
	id string
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
	mut ret := node.dependencies.clone()

	for d in node.dependencies {
		sub_node := node.tree.get_node(d) or {
			// eprintln('Node ${d}, referenced as a dependency of ${node.id} does not exist in the tree.')
			// return error
			continue
		}

		other_deps := sub_node.get_all_dependencies()
		for other_dep in other_deps {
			if other_dep !in ret {
				// push if other_dep is not present in ret
				ret << other_dep
			}
		}

		unsafe { other_deps.free() }
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

	unsafe { available_and_required.free() }
	return ret
}