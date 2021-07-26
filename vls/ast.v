module vls

// import tree_sitter

// any node that is separated by a comma or other symbol
const	list_node_types = ['expression_list', 'identifier_list', 'argument_list', 'array']

fn traverse_node(root_node C.TSNode, offset u32) C.TSNode {
	root_type := root_node.get_type()
	direct_named_child := root_node.first_named_child_for_byte(offset)
	child_type := direct_named_child.get_type()
	if direct_named_child.is_null() {
		return root_node
	}

	if (!root_type.ends_with('_declaration') && root_type !in list_node_types) && (child_type.ends_with('identifier') || child_type == 'builtin_type') {
		if root_type == 'selector_expression' {
			root_children_count := root_node.named_child_count()
			for i := u32(0); i < root_children_count; i++ {
				selected_child_node := root_node.named_child(i)
				if selected_child_node.range().eq(direct_named_child.range()) && i == 0 {
					return direct_named_child
				}
			}
		} else if root_type == 'index_expression' {
			index_node := root_node.child_by_field_name('index')
			if index_node.range().eq(direct_named_child.range()) {
				return direct_named_child
			}
		}

		return root_node
	}

	// eprintln('direct_named_child: ${direct_named_child.sexpr_str()}')
	named_children_count := direct_named_child.named_child_count()
	if named_children_count == 0 {
		return direct_named_child
	}

	return traverse_node(direct_named_child, offset)
}

// for auto-completion
fn traverse_node2(starting_node C.TSNode, offset u32) C.TSNode {
	mut root_node := starting_node
	mut root_type := root_node.get_type()

	direct_named_child := root_node.first_named_child_for_byte(offset)
	eprintln('$root_type ${root_node.sexpr_str()}')

	child_type := direct_named_child.get_type()
	if direct_named_child.is_null() {
		// root_node = root_node.first_child_for_byte(offset)
		// if !root_node.prev_named_sibling().is_null() {
		// 	root_node = root_node.prev_named_sibling()
		// }
		return root_node
	}

	if (!root_type.ends_with('_declaration') && root_type !in list_node_types) && (child_type.ends_with('identifier') || child_type == 'builtin_type') {
		if root_type == 'selector_expression' {
			root_children_count := root_node.named_child_count()
			for i := u32(0); i < root_children_count; i++ {
				selected_child_node := root_node.named_child(i)
				if selected_child_node.range().eq(direct_named_child.range()) && i == 0 {
					return direct_named_child
				}
			}
		} else if root_type == 'index_expression' {
			index_node := root_node.child_by_field_name('index')
			if index_node.range().eq(direct_named_child.range()) {
				return direct_named_child
			}
		}

		return root_node
	}

	// eprintln('direct_named_child: ${direct_named_child.sexpr_str()}')
	named_children_count := direct_named_child.named_child_count()
	if named_children_count == 0 {
		return direct_named_child
	}

	return traverse_node2(direct_named_child, offset)
}

// fn closest_child_to_offset(starting_node C.TSNode, offset u32) C.TSNode {

// }