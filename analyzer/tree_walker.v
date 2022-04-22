module analyzer

struct TreeWalker {
mut:
	already_visited_children bool
	cursor                   C.TSTreeCursor
}

pub fn (mut tw TreeWalker) next() ?C.TSNode {
	if !tw.already_visited_children {
		if tw.cursor.to_first_child() {
			tw.already_visited_children = false
		} else if tw.cursor.next() {
			tw.already_visited_children = false
		} else {
			if !tw.cursor.to_parent() {
				return error('')
			}
			tw.already_visited_children = true
			return tw.next()
		}
	} else {
		if tw.cursor.next() {
			tw.already_visited_children = false
		} else {
			if !tw.cursor.to_parent() {
				return error('')
			}
			return tw.next()
		}
	}
	return tw.cursor.current_node()
}

pub fn new_tree_walker(root_node C.TSNode) TreeWalker {
	return TreeWalker{
		cursor: root_node.tree_cursor()
	}
}
