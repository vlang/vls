module ast

import strings
import tree_sitter
import tree_sitter_v as v

pub type Node = tree_sitter.Node[v.NodeType]
pub type Tree = tree_sitter.Tree[v.NodeType]

pub fn new_parser() &tree_sitter.Parser[v.NodeType] {
	return tree_sitter.new_parser[v.NodeType](v.language, v.type_factory)
}

fn (n Node) str() string {
	mut cursor := n.tree_cursor()
	if !cursor.to_first_child() {
		return ''
	}

	mut builder := strings.new_builder(0)
	mut indent_level := 0
	for {
		current := cursor.current_node() or { break }

		if current.type_name != v.NodeType.unknown {
			for _ in 0 .. indent_level {
				builder.write_string('  ')
			}

			builder.write_string('${current.type_name}')
			builder.write_string(' *')

			st := current.start_point()
			builder.write_string('[${st.row}, ${st.column}]')

			builder.write_string(' - ')

			ed := current.end_point()
			builder.write_string('[${ed.row}, ${ed.column}]')

			builder.write_string('\n')
		}

		if cursor.to_first_child() {
			indent_level += 1
		} else if cursor.next() {
			// do nothing
		} else if cursor.to_parent() {
			indent_level -= 1

			mut ok := true
			for !cursor.next() {
				if cursor.to_parent() {
					indent_level -= 1
				} else {
					ok = false
					break
				}
			}

			if !ok {
				break
			}
		} else {
			break
		}
	}

	return builder.str()
}
