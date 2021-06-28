module tree_sitter

import tree_sitter_v.bindings.v

fn parse_content(content string) &C.TSTree {
	mut parser := new_parser()
	parser.set_language(v.language)
	return parser.parse_string(content)
}

fn test_same_tree() {
	content := '
	a := 10
	'
	tree1 := parse_content(content)
	tree2 := parse_content(content)
	println('Done')
	changes := tree1.get_changed_ranges(tree2)
	assert changes.len == 0
}

fn test_different_tree() {
	content := '
     a := 10
     '
	mut parser := new_parser()
	parser.set_language(v.language)
	tree1 := parser.parse_string(content)

	content2 := '
     a := 11
     '

	tree2 := parser.parse_string_with_old_tree(content2, tree1)
	changes := tree1.get_changed_ranges(tree2)
	assert changes.len == 1
}
