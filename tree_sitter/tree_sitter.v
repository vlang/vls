module tree_sitter

#include <@VROOT/tree_sitter/lib/api.h>
#flag @VROOT/tree_sitter/lib/lib.o

[typedef]
struct C.TSParser {}

[typedef]
struct C.TSLanguage {}

[typedef]
struct C.TSTree {}

[typedef]
struct C.TSNode {}

fn C.ts_parser_new() &C.TSParser
fn C.ts_parser_set_language(parser &C.TSParser, language &C.TSLanguage) bool
fn C.ts_parser_parse_string(parser &C.TSParser, old_tree &C.TSTree, str &char, len u32) &C.TSTree
fn C.ts_tree_root_node(tree &C.TSTree) C.TSNode 
fn C.ts_node_string(node &C.TSNode) &char

pub fn new_parser() &C.TSParser {
	return C.ts_parser_new()
}

pub fn (mut parser C.TSParser) set_language(language &C.TSLanguage) bool {
	return C.ts_parser_set_language(parser, language)
} 

pub fn (mut parser C.TSParser) parse_string(content string) &C.TSTree {
	return parser.parse_string_with_old_tree(content, &C.TSTree(0))
}

pub fn (mut parser C.TSParser) parse_string_with_old_tree(content string, old_tree &C.TSTree) &C.TSTree {
	return C.ts_parser_parse_string(parser, old_tree, content.str, content.len)
}

pub fn (tree &C.TSTree) root_node() C.TSNode {
	return C.ts_tree_root_node(tree)
}

pub fn (node C.TSNode) str() string {
	sexpr := C.ts_node_string(node)
	return unsafe { sexpr.vstring() }
}

// fn main() {
// 	parser := C.ts_parser_new()
// 	C.ts_parser_set_language(parser, vparser.language)
// 	text := 'module main struct Hello { name string }'
// 	tree := C.ts_parser_parse_string(parser, 0, text.str, text.len)
// 	root_node := C.ts_tree_root_node(tree)
// 	sexpr := C.ts_node_string(root_node)
// 	println(unsafe { sexpr.vstring() })
// }