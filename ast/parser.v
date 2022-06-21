module ast

import tree_sitter
import tree_sitter_v as v

pub type Node = tree_sitter.Node<v.NodeType>
pub type Tree = tree_sitter.Tree<v.NodeType>

pub fn new_parser() &tree_sitter.Parser<v.NodeType> {
	return tree_sitter.new_parser<v.NodeType>(v.language, v.type_factory)
}