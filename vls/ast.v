module vls

import v.ast
import v.ast.walker

struct FindNodeByPos {
	pos int
mut:
	found bool
	node  ast.Node
}

pub fn find_ast_by_pos(nodes []ast.Node, offset int) ?ast.Node {
	mut data := FindNodeByPos{
		pos: offset
	}
	for node in nodes {
		if data.found {
			return data.node
		}
		walker.inspect(node, data, fn (node ast.Node, mut data FindNodeByPos) bool {
			node_pos := node.position()
			if is_within_pos(data.pos, node_pos) {
				data.node = node
				data.found = true
			} else if data.pos - node_pos.pos <= 5 {
				if node is ast.Expr {
					expr := node
					match node {
						ast.SelectorExpr, ast.CallExpr {
							data.node = expr
							data.found = true
						}
						else {}
					}
				} else if node is ast.Stmt {
					data.found = node is ast.Import
				}
			}
			return if data.found { false } else { true }
		})
	}
	if isnil(data.node) {
		return error('not found')
	}
	return data.node
}
