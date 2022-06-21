module analyzer

import ast
import tree_sitter_v as v

fn within_range(node_range C.TSRange, range C.TSRange) bool {
	return (node_range.start_byte >= range.start_byte && node_range.start_byte <= range.end_byte)
		|| (node_range.end_byte >= range.start_byte && node_range.end_byte <= range.end_byte)
}

const excluded_nodes = [v.NodeType.const_declaration, .global_var_declaration]

const included_nodes = [v.NodeType.const_spec, .global_var_spec, .global_var_type_initializer, .block]

fn get_nodes_within_range(node ast.Node, range C.TSRange) ?[]ast.Node {
	child_count := node.named_child_count()
	mut nodes := []ast.Node{cap: int(child_count)}

	for i in u32(0) .. child_count {
		child := node.named_child(i) or { continue }
		type_name := child.type_name
		if !child.is_null()
			&& ((type_name.is_declaration() && type_name !in analyzer.excluded_nodes)
			|| type_name in analyzer.included_nodes) && within_range(child.range(), range) {
			nodes << child
		} else {
			nodes << get_nodes_within_range(child, range) or { continue }
		}
	}

	if nodes.len == 0 {
		// unsafe { nodes.free() }
		return none
	}

	return nodes
}
