module analyzer

import tree_sitter

struct TreeWalker<T> {
mut:
	already_visited_children bool
	cursor                   tree_sitter.TreeCursor<T>
}

pub fn (mut tw TreeWalker<T>) next() ?tree_sitter.Node<T> {
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

pub fn new_tree_walker<T>(root_node tree_sitter.Node<T>) TreeWalker<T> {
	return TreeWalker<T>{
		cursor: root_node.tree_cursor()
	}
}
