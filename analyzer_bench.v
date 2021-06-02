import tree_sitter
import analyzer
import tree_sitter_v.bindings.v

fn main() {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	
	src := '
import os
import json as json2

pub const (
	hello = 1
	foo = \'bar\'
)

interface Speaker {
	speak(name string) string
	foo int
}

struct Hey {
	what string
}

pub enum Color {
	red
	blue
	yellow
}

pub fn (mut h Hey) main(num int) int {
	mut a, b := 0, 1
	hello := 1
	what := 2.5
}
'
	tree := parser.parse_string(src)
	mut an := analyzer.Analyzer{}
	mut store := analyzer.Store{}
	an.analyze(tree.root_node(), src.bytes(), mut store)

	// println(analyzer.scope)
	// println(analyzer.scope.innermost(55))
	println(store.symbols)
}