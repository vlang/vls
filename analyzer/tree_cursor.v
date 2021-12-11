module analyzer

struct TreeCursor {
mut:
	cur_child_idx int  = -1
	named_only    bool = true
	child_count   int            [required]
	cursor        C.TSTreeCursor [required]
}

pub fn (mut tc TreeCursor) next() ?C.TSNode {
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

pub fn (mut tc TreeCursor) to_first_child() bool {
	return tc.cursor.to_first_child()
}

pub fn (tc &TreeCursor) current_node() ?C.TSNode {
	return tc.cursor.current_node()
}

[unsafe]
pub fn (tc &TreeCursor) free() {
	unsafe {
		tc.cursor.free()
		tc.cur_child_idx = 0
		tc.child_count = 0
	}
}

pub fn new_tree_cursor(root_node C.TSNode) TreeCursor {
	return TreeCursor{
		child_count: int(root_node.child_count())
		cursor: root_node.tree_cursor()
	}
}
