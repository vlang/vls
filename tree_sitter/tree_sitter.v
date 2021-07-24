module tree_sitter

#include "@VMODROOT/tree_sitter/lib/api.h"
#flag -I@VMODROOT/tree_sitter/lib
#flag @VMODROOT/tree_sitter/lib/lib.o

[typedef]
struct C.TSParser {}

// Parser
fn C.ts_parser_new() &C.TSParser
fn C.ts_parser_set_language(parser &C.TSParser, language &C.TSLanguage) bool
fn C.ts_parser_parse_string(parser &C.TSParser, old_tree &C.TSTree, str &char, len u32) &C.TSTree
fn C.ts_parser_parse(parser &C.TSParser, old_tree &C.TSTree, input C.TSInput) &C.TSTree
fn C.ts_parser_delete(tree &C.TSParser)

[inline]
pub fn new_parser() &C.TSParser {
	return C.ts_parser_new()
}

[inline]
pub fn (mut parser C.TSParser) set_language(language &C.TSLanguage) bool {
	return C.ts_parser_set_language(parser, language)
}

[inline]
pub fn (mut parser C.TSParser) parse_string(content string) &C.TSTree {
	return parser.parse_string_with_old_tree(content, &C.TSTree(0))
}

[inline]
pub fn (mut parser C.TSParser) parse_string_with_old_tree(content string, old_tree &C.TSTree) &C.TSTree {
	return C.ts_parser_parse_string(parser, old_tree, &char(content.str), content.len)
}

[inline; unsafe]
pub fn (parser &C.TSParser) free() {
	unsafe {
		C.ts_parser_delete(parser)
	}
}

[typedef]
struct C.TSLanguage {}

[typedef]
pub struct C.TSTree {}

// Tree
fn C.ts_tree_root_node(tree &C.TSTree) C.TSNode
fn C.ts_tree_delete(tree &C.TSTree)
fn C.ts_tree_edit(tree &C.TSTree, edit &C.TSInputEdit)
fn C.ts_tree_get_changed_ranges(old_tree &C.TSTree, new_tree &C.TSTree, count &u32) &C.TSRange

[inline]
pub fn (tree &C.TSTree) root_node() C.TSNode {
	return C.ts_tree_root_node(tree)
}

[inline]
pub fn (tree &C.TSTree) edit(input_edit &C.TSInputEdit) {
	C.ts_tree_edit(tree, input_edit)
}

[inline]
pub fn (old_tree &C.TSTree) get_changed_ranges(new_tree &C.TSTree) &C.TSRange {
	mut count := u32(0)
	return C.ts_tree_get_changed_ranges(old_tree, new_tree, &count)
}

[unsafe]
pub fn (tree &C.TSTree) free() {
	unsafe {
		C.ts_tree_delete(tree)
	}
}

[typedef]
struct C.TSNode {
	tree &C.TSTree
}

// Node
fn C.ts_node_string(node C.TSNode) &char
fn C.ts_node_type(node C.TSNode) &char
fn C.ts_node_is_null(node C.TSNode) bool
fn C.ts_node_is_named(node C.TSNode) bool
fn C.ts_node_is_missing(node C.TSNode) bool
fn C.ts_node_is_extra(node C.TSNode) bool
fn C.ts_node_has_changes(node C.TSNode) bool
fn C.ts_node_has_error(node C.TSNode) bool

fn C.ts_node_start_point(node C.TSNode) C.TSPoint
fn C.ts_node_end_point(node C.TSNode) C.TSPoint
fn C.ts_node_start_byte(node C.TSNode) u32
fn C.ts_node_end_byte(node C.TSNode) u32

fn C.ts_node_parent(node C.TSNode) C.TSNode
fn C.ts_node_child(node C.TSNode, index u32) C.TSNode
fn C.ts_node_child_count(node C.TSNode) u32
fn C.ts_node_named_child(node C.TSNode, index u32) C.TSNode
fn C.ts_node_named_child_count(node C.TSNode) u32
fn C.ts_node_child_by_field_name(node C.TSNode, field_name &char, field_name_length u32) C.TSNode

fn C.ts_node_next_sibling(node C.TSNode) C.TSNode
fn C.ts_node_prev_sibling(node C.TSNode) C.TSNode
fn C.ts_node_next_named_sibling(node C.TSNode) C.TSNode
fn C.ts_node_prev_named_sibling(node C.TSNode) C.TSNode

fn C.ts_node_first_child_for_byte(node C.TSNode, offset u32) C.TSNode
fn C.ts_node_first_named_child_for_byte(node C.TSNode, offset u32) C.TSNode

fn C.ts_node_descendant_for_byte_range(node C.TSNode, start_offset u32, end_offset u32) C.TSNode
fn C.ts_node_descendant_for_point_range(node C.TSNode, start_point C.TSPoint, end_point C.TSPoint) C.TSNode
fn C.ts_node_named_descendant_for_byte_range(node C.TSNode, start_offset u32, end_offset u32) C.TSNode
fn C.ts_node_named_descendant_for_point_range(node C.TSNode, start_point C.TSPoint, end_point C.TSPoint) C.TSNode

fn C.ts_node_eq(node C.TSNode, another_node C.TSNode) bool

pub fn (node C.TSNode) get_text(text []byte) string {
	start_index := node.start_byte()
	end_index := node.end_byte()
	len := int(end_index - start_index)
	if len < 1 {
		return ''
	}

	return text[start_index..end_index].bytestr()
}

[inline]
pub fn (node C.TSNode) sexpr_str() string {
	if node.is_null() {
		return '<null node>'
	}

	sexpr := C.ts_node_string(node)
	return unsafe { sexpr.vstring() }
}

pub fn (node C.TSNode) start_point() C.TSPoint {
	if node.is_null() {
		return C.TSPoint{0, 0}
	}

	return C.ts_node_start_point(node)
}

pub fn (node C.TSNode) end_point() C.TSPoint {
	if node.is_null() {
		return C.TSPoint{0, 0}
	}

	return C.ts_node_end_point(node)
}

pub fn (node C.TSNode) start_byte() u32 {
	if node.is_null() {
		return 0
	}

	return C.ts_node_start_byte(node)
}

pub fn (node C.TSNode) end_byte() u32 {
	if node.is_null() {
		return 0
	}

	return C.ts_node_end_byte(node)
}

[inline]
pub fn (node C.TSNode) range() C.TSRange {
	return C.TSRange{
		start_point: node.start_point()
		end_point: node.end_point()
		start_byte: node.start_byte()
		end_byte: node.end_byte()
	}
}

[inline]
pub fn (node C.TSNode) get_type() string {
	c := &char(C.ts_node_type(node))
	return unsafe { c.vstring() }
}

[inline]
pub fn (node C.TSNode) is_null() bool {
	return C.ts_node_is_null(node)
}

[inline]
pub fn (node C.TSNode) is_named() bool {
	return C.ts_node_is_named(node)
}

[inline]
pub fn (node C.TSNode) is_missing() bool {
	return C.ts_node_is_missing(node)
}

[inline]
pub fn (node C.TSNode) is_extra() bool {
	return C.ts_node_is_extra(node)
}

[inline]
pub fn (node C.TSNode) has_changes() bool {
	return C.ts_node_has_changes(node)
}

[inline]
pub fn (node C.TSNode) has_error() bool {
	return C.ts_node_has_error(node)
}

[inline]
pub fn (node C.TSNode) parent() C.TSNode {
	return C.ts_node_parent(node)
}

[inline]
pub fn (node C.TSNode) child(pos u32) C.TSNode {
	return C.ts_node_child(node, pos)
}

[inline]
pub fn (node C.TSNode) child_count() u32 {
	return C.ts_node_child_count(node)
}

[inline]
pub fn (node C.TSNode) named_child(pos u32) C.TSNode {
	return C.ts_node_named_child(node, pos)
}

[inline]
pub fn (node C.TSNode) named_child_count() u32 {
	return C.ts_node_named_child_count(node)
}

[inline]
pub fn (node C.TSNode) child_by_field_name(name string) C.TSNode {
	defer {
		unsafe { name.free() }
	}
	return C.ts_node_child_by_field_name(node, &char(name.str), u32(name.len))
}

[inline]
pub fn (node C.TSNode) next_sibling() C.TSNode {
	return C.ts_node_next_sibling(node)
}

[inline]
pub fn (node C.TSNode) prev_sibling() C.TSNode {
	return C.ts_node_prev_sibling(node)
}

[inline]
pub fn (node C.TSNode) next_named_sibling() C.TSNode {
	return C.ts_node_next_named_sibling(node)
}

[inline]
pub fn (node C.TSNode) prev_named_sibling() C.TSNode {
	return C.ts_node_prev_named_sibling(node)
}

[inline]
pub fn (node C.TSNode) first_child_for_byte(offset u32) C.TSNode {
	return C.ts_node_first_child_for_byte(node, offset)
}

[inline]
pub fn (node C.TSNode) first_named_child_for_byte(offset u32) C.TSNode {
	return C.ts_node_first_named_child_for_byte(node, offset)
}

[inline]
pub fn (node C.TSNode) descendant_for_byte_range(start_range u32, end_range u32) C.TSNode {
	return C.ts_node_descendant_for_byte_range(node, start_range, end_range)
}

[inline]
pub fn (node C.TSNode) descendant_for_point_range(start_point C.TSPoint, end_point C.TSPoint) C.TSNode {
	return C.ts_node_descendant_for_point_range(node, start_point, end_point)
}

[inline]
pub fn (node C.TSNode) named_descendant_for_byte_range(start_range u32, end_range u32) C.TSNode {
	return C.ts_node_named_descendant_for_byte_range(node, start_range, end_range)
}

[inline]
pub fn (node C.TSNode) named_descendant_for_point_range(start_point C.TSPoint, end_point C.TSPoint) C.TSNode {
	return C.ts_node_named_descendant_for_point_range(node, start_point, end_point)
}

[inline]
pub fn (node C.TSNode) == (other_node C.TSNode) bool {
	return C.ts_node_eq(node, other_node)
}

fn C.ts_tree_cursor_new(node C.TSNode) C.TSTreeCursor

[inline]
pub fn (node C.TSNode) tree_cursor() C.TSTreeCursor {
	return C.ts_tree_cursor_new(node)
}

[typedef]
pub struct C.TSTreeCursor {
	tree    voidptr
	id      voidptr
	context [2]u32
}

fn C.ts_tree_cursor_delete(cursor &C.TSTreeCursor)
fn C.ts_tree_cursor_reset(cursor &C.TSTreeCursor, node C.TSNode)
fn C.ts_tree_cursor_current_node(cursor &C.TSTreeCursor) C.TSNode
fn C.ts_tree_cursor_current_field_name(cursor &C.TSTreeCursor) &char
fn C.ts_tree_cursor_goto_parent(cursor &C.TSTreeCursor) bool
fn C.ts_tree_cursor_goto_next_sibling(cursor &C.TSTreeCursor) bool
fn C.ts_tree_cursor_goto_first_child(cursor &C.TSTreeCursor) bool
fn C.ts_tree_cursor_first_child_for_byte(cursor &C.TSTreeCursor, idx u32) i64
fn C.ts_tree_cursor_copy(cursor &C.TSTreeCursor) C.TSTreeCursor

[inline; unsafe]
pub fn (cursor &C.TSTreeCursor) free() {
	C.ts_tree_cursor_delete(cursor)
}

[inline]
pub fn (mut cursor C.TSTreeCursor) reset(node C.TSNode) {
	C.ts_tree_cursor_reset(cursor, node)
}

[inline]
pub fn (cursor &C.TSTreeCursor) current_node() C.TSNode {
	return C.ts_tree_cursor_current_node(cursor)
}

[inline]
pub fn (cursor &C.TSTreeCursor) current_field_name() string {
	c := &char(C.ts_tree_cursor_current_field_name(cursor))
	return unsafe { c.vstring() }
}

[inline]
pub fn (mut cursor C.TSTreeCursor) to_parent() bool {
	return C.ts_tree_cursor_goto_parent(cursor)
}

[inline]
pub fn (mut cursor C.TSTreeCursor) next() bool {
	return C.ts_tree_cursor_goto_next_sibling(cursor)
}

[inline]
pub fn (mut cursor C.TSTreeCursor) to_first_child() bool {
	return C.ts_tree_cursor_goto_first_child(cursor)
}

// [inline]
// pub fn (cursor &C.TSTreeCursor)

[typedef]
pub struct C.TSInputEdit {
	start_byte    u32
	old_end_byte  u32
	new_end_byte  u32
	start_point   C.TSPoint
	old_end_point C.TSPoint
	new_end_point C.TSPoint
}

[typedef]
pub struct C.TSPoint {
	row    u32
	column u32
}

pub fn (left_point C.TSPoint) eq(right_point C.TSPoint) bool {
	return left_point.row == right_point.row && left_point.column == right_point.column
}

[typedef]
pub struct C.TSRange {
	start_point C.TSPoint
	end_point   C.TSPoint
	start_byte  u32
	end_byte    u32
}

// change this later if V allows operator overloading on binded types
pub fn (left_range C.TSRange) eq(right_range C.TSRange) bool {
	return left_range.start_point.eq(right_range.start_point)
		&& left_range.end_point.eq(right_range.end_point)
		&& left_range.start_byte == right_range.start_byte
		&& left_range.end_byte == right_range.end_byte
}
