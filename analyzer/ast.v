module analyzer

fn within_range(node_range C.TSRange, range C.TSRange) bool {
	return (node_range.start_byte >= range.start_byte && node_range.start_byte <= range.end_byte)
		|| (node_range.end_byte >= range.start_byte && node_range.end_byte <= range.end_byte)
}

const excluded_nodes = ['const_declaration', 'global_var_declaration']
const included_nodes = ['const_spec', 'global_var_spec', 'global_var_type_initializer', 'block']

fn get_nodes_within_range(node C.TSNode, range C.TSRange) ?[]C.TSNode {
	child_count := node.named_child_count()
	mut nodes := []C.TSNode{cap: int(child_count)}

	for i in u32(0) .. child_count {
		child := node.named_child(i)
		child_type := child.get_type()
		if !child.is_null() && ((child_type.ends_with('_declaration') && child_type !in excluded_nodes) || child_type in included_nodes) && within_range(child.range(), range) {
			nodes << child
		} else {
			nodes << get_nodes_within_range(child, range) or { 
				continue 
			}
		}
	}

	if nodes.len == 0 {
		unsafe { nodes.free() }
		return none
	}

	return nodes
}