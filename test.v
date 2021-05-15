import tree_sitter
import tree_sitter_v.bindings.v

fn main() {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	
	tree := parser.parse_string('module main')
	// root_node() returns C.TSNode
	println(tree.root_node().str())
}