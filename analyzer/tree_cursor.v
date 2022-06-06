module analyzer

import tree_sitter

struct TreeCursor<T> {
mut:
	cur_child_idx int  = -1
	named_only    bool = true
	child_count   int                       [required]
	cursor        tree_sitter.TreeCursor<T> [required]
}

pub fn (mut tc TreeCursor<T>) next() ?tree_sitter.Node<T> {
	for tc.cur_child_idx < tc.child_count {
		if tc.cur_child_idx == -1 {
			tc.cursor.to_first_child()
		} else if !tc.cursor.next() {
			return none
		}

		tc.cur_child_idx++
		if cur_node := tc.current_node() {
			if tc.named_only && (cur_node.is_named() && !cur_node.is_extra()) {
				return cur_node
			}
		}
	}

	return none
}

pub fn (mut tc TreeCursor<T>) to_first_child() bool {
	return tc.cursor.to_first_child()
}

pub fn (tc &TreeCursor<T>) current_node() ?tree_sitter.Node<T> {
	return tc.cursor.current_node()
}

[unsafe]
pub fn (tc &TreeCursor<T>) free() {
	unsafe {
		tc.cursor.raw_cursor.free()
		tc.cur_child_idx = 0
		tc.child_count = 0
	}
}

pub fn new_tree_cursor<T>(root_node tree_sitter.Node<T>) TreeCursor<T> {
	return TreeCursor<T>{
		child_count: int(root_node.child_count())
		cursor: root_node.tree_cursor()
	}
}
