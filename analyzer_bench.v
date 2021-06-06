import tree_sitter
import analyzer
import tree_sitter_v.bindings.v

fn main() {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	
	src := '
module main

struct Hello {}
'
	tree := parser.parse_string(src)
	mut store := analyzer.Store{}
	store.set_active_file_path('foo/bar')
	println(tree.root_node().sexpr_str())
	analyzer.analyze(tree, src.bytes(), mut store)
	println(store.symbols)
}