module depgraph

// Taken from: https://gist.github.com/Fordi/1706368
// Transpiled to ES6 for readability using Lebab: https://lebab.unibtc.me/editor
// Credits to: https://github.com/Fordi

pub struct Tree {
mut:
	nodes map[string]&Node
}

pub fn (tree &Tree) has(id string) bool {
	tree.get_node(id) or {
		return false
	}
	
	return true
}

pub fn (mut tree Tree) add(node Node) &Node {
	tree.nodes[node.id] = &Node{
		id: node.id.clone()
		dependencies: node.dependencies.clone()
		tree: unsafe { tree }
	} 

	return tree.nodes[node.id]
}

pub fn (tree Tree) get_node(id string) ?&Node {
	return tree.nodes[id] ?
}

pub fn (mut tree Tree) get_nodes() map[string]&Node {
	return tree.nodes
}

pub fn (tree Tree) get_available_nodes(completed ...string) []string {
	mut ret := []string{}
	for node_id, _ in tree.nodes {
		node := tree.get_node(node_id) or { continue }
		deps := node.get_all_dependencies(...completed)
		if deps.len == 0 && node_id !in completed {
			ret << node_id
		}
	}

	return ret
}

pub struct Node {
mut:
	tree &Tree = &Tree(0)
pub mut:
	id string
	dependencies []string
}

pub fn (node &Node) get_all_dependencies(completed ...string) []string {
	if node.dependencies.len == 0 {
		return node.dependencies
	}

	mut ret := node.dependencies.clone()
	mut satisfied := map[string]bool{}
	defer {
		unsafe { satisfied.free() }
	}
	
	for d in node.dependencies {
		sub_node := node.tree.get_node(d) or {
			// eprintln('Node ${d}, referenced as a dependency of ${node.id} does not exist in the tree.')
			// return error
			continue
		}

		ret << sub_node.get_all_dependencies()
	}

	if completed.len == 0 {
		return ret
	}

	for r in ret {
		satisfied[r] = false
	}

	for c in completed {
		satisfied[c] = true
	}

	unsafe { ret.free() }
	ret = []

	for name, status in satisfied {
		if !status {
			ret << name
		}
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
