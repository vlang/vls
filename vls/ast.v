module vls

import v.ast
import v.ast.walker

struct FindNodeByPos {
	pos int
mut:
	node ast.Node
}

pub fn find_ast_by_pos(nodes []ast.Node, offset int) ?ast.Node {
	mut data := FindNodeByPos{
		pos: offset
	}
	for node in nodes {
		walker.inspect(node, data, fn (node ast.Node, mut data FindNodeByPos) bool {
			node_pos := node.position()
			// match node {
			// 	ast.Expr {
			// 		println(typeof(node))
			// 	}
			// 	ast.Stmt {
			// 		println(typeof(node))
			// 	}
			// 	else {}
			// }
			if node is ast.Expr {
				expr := node
				if node is ast.SelectorExpr {
					data.node = expr
					return false
				}
			}
			if data.pos >= node_pos.pos && data.pos <= node_pos.pos + node_pos.len {
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
