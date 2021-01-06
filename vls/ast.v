module vls

import v.ast
import v.ast.walker

struct FindNodeByPos {
	pos         int
mut:
	node        ast.Node
}

pub fn find_ast_by_pos(nodes []ast.Node, offset int) ?ast.Node {
	mut data := FindNodeByPos{pos: offset}
	for node in nodes {
		walker.inspect(node, data, fn (node ast.Node, mut data FindNodeByPos) bool {
			pos := data.pos
			node_pos := node.position()
			if pos >= node_pos.pos && pos <= node_pos.pos + node_pos.len {
				data.node = node
				return false
			}

			return true
		})
	}
	
	if isnil(data.node) {
		return error('not found')
	}

	return data.node
}