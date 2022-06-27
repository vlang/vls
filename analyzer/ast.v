module analyzer

import ast
import tree_sitter_v as v
import datatypes { Stack }

fn within_range(node_range C.TSRange, start_line u32, end_line u32) bool {
	return (node_range.start_point.row >= start_line && node_range.start_point.row <= end_line)
		|| (node_range.end_point.row >= start_line && node_range.end_point.row <= end_line)
}

const excluded_nodes = [v.NodeType.const_declaration, .global_var_declaration]

const included_nodes = [v.NodeType.const_spec, .global_var_spec, .global_var_type_initializer, .block]

struct NodeIterAttr {
	cur_node    ast.Node
	child_count u32
	cur_idx     u32
}

struct RangeNodeIterator {
mut:
	cur_node    ast.Node
	child_count u32
	cur_idx     u32
	start_line  u32
	end_line    u32
	stack       Stack<NodeIterAttr>
}

fn (mut iter RangeNodeIterator) next() ?ast.Node {
	if iter.cur_idx >= iter.child_count {
		if last_attr := iter.stack.pop() {
			iter.cur_node = last_attr.cur_node.next_named_sibling() or { return none }
			iter.child_count = last_attr.child_count
			iter.cur_idx = last_attr.cur_idx
			return iter.next()
		}
		return none
	}
	child := if iter.cur_idx == 0 {
		iter.cur_node.named_child(0) or { return none }
	} else {
		iter.cur_node.next_named_sibling() or { return none }
	}
	type_name := child.type_name
	if ((type_name.is_declaration() && type_name !in analyzer.excluded_nodes)
		|| type_name in analyzer.included_nodes) && within_range(child.range(), iter.start_line, iter.end_line) {
		defer {
			iter.cur_node = child
			iter.cur_idx++
		}
		return child
	} else {
		iter.stack.push(NodeIterAttr{
			cur_node: iter.cur_node
			child_count: iter.child_count
			cur_idx: iter.cur_idx
		})
		iter.cur_node = child
		iter.child_count = child.named_child_count()
		iter.cur_idx = 0
		return iter.next()
	}
}

fn get_nodes_within_range(node ast.Node, start_line u32, end_line u32) &RangeNodeIterator {
	return &RangeNodeIterator{
		cur_node: node
		child_count: node.named_child_count()
		start_line: start_line
		end_line: end_line
	}
}
