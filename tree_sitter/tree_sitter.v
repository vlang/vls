module tree_sitter

#include "@VMODROOT/tree_sitter/lib/api.h"
#flag -I@VMODROOT/tree_sitter/lib
#flag @VMODROOT/tree_sitter/lib/lib.o

// Input
enum TSVInputEncoding {
	utf8
	utf16
}

[typedef]
struct C.TSInput {
mut:
	payload  voidptr
	read     fn (payload voidptr, byte_index u32, position C.TSPoint, bytes_read &u32) &char
	encoding TSVInputEncoding
}

[typedef]
struct C.TSParser {}

// Parser
fn C.ts_parser_new() &C.TSParser
fn C.ts_parser_set_language(parser &C.TSParser, language &C.TSLanguage) bool
fn C.ts_parser_parse_string(parser &C.TSParser, old_tree &C.TSTree, str &char, len u32) &C.TSTree
fn C.ts_parser_parse(parser &C.TSParser, old_tree &C.TSTree, input C.TSInput) &C.TSTree
fn C.ts_parser_delete(tree &C.TSParser)
fn C.ts_parser_reset(parser &C.TSParser)

[inline]
pub fn new_ts_parser() &C.TSParser {
	return C.ts_parser_new()
}

[inline]
pub fn (mut parser C.TSParser) parse(old_tree &C.TSTree, input C.TSInput) &C.TSTree {
	return C.ts_parser_parse(parser, old_tree, input)
}

[inline]
pub fn (mut parser C.TSParser) reset() {
	C.ts_parser_reset(parser)
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
	return parser.parse_string_with_old_tree_and_len(content, old_tree, u32(content.len))
}

[inline]
pub fn (mut parser C.TSParser) parse_string_with_old_tree_and_len(content string, old_tree &C.TSTree, len u32) &C.TSTree {
	return C.ts_parser_parse_string(parser, old_tree, &char(content.str), len)
}

[inline]
pub fn (mut parser C.TSParser) parse_bytes(content []u8) &C.TSTree {
	return parser.parse_bytes_with_old_tree(content, &C.TSTree(0))
}

fn v_byte_array_input_read(pl voidptr, byte_index u32, position C.TSPoint, bytes_read &u32) &char {
	payload := *(&[]u8(pl))
	if byte_index >= u32(payload.len) {
		unsafe {
			*bytes_read = 0
		}
		return c''
	} else {
		unsafe {
			*bytes_read = u32(payload.len) - byte_index
		}
		return unsafe { &char(payload.data) + byte_index }
	}
}

pub fn (mut parser C.TSParser) parse_bytes_with_old_tree(content []u8, old_tree &C.TSTree) &C.TSTree {
	return parser.parse(old_tree,
		payload: &content
		read: v_byte_array_input_read
		encoding: .utf8
	)
}

[inline; unsafe]
pub fn (parser &C.TSParser) free() {
	unsafe {
		C.ts_parser_delete(parser)
	}
}

[typedef]
pub struct C.TSLanguage {}

[typedef]
pub struct C.TSTree {}

// Tree
fn C.ts_tree_copy(tree &C.TSTree) &C.TSTree
fn C.ts_tree_root_node(tree &C.TSTree) C.TSNode
fn C.ts_tree_delete(tree &C.TSTree)
fn C.ts_tree_edit(tree &C.TSTree, edit &C.TSInputEdit)
fn C.ts_tree_get_changed_ranges(old_tree &C.TSTree, new_tree &C.TSTree, count &u32) &C.TSRange

[inline]
pub fn (tree &C.TSTree) copy() &C.TSTree {
	return C.ts_tree_copy(tree)
}

[inline]
pub fn (tree &C.TSTree) root_node() C.TSNode {
	return C.ts_tree_root_node(tree)
}

[inline]
pub fn (tree &C.TSTree) edit(input_edit &C.TSInputEdit) {
	C.ts_tree_edit(tree, input_edit)
}

pub fn (old_tree &C.TSTree) get_changed_ranges(new_tree &C.TSTree) []C.TSRange {
	mut len := u32(0)
	buf := C.ts_tree_get_changed_ranges(old_tree, new_tree, &len)
	e_size := int(sizeof(C.TSRange))

	return unsafe {
		array{
			element_size: e_size
			len: int(len)
			cap: int(len)
			data: buf
		}
	}
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

struct NodeError {
	Error
	msg  string
	node C.TSNode
}

pub fn (err NodeError) msg() string {
	return '$err.msg: ${voidptr(err.node.tree)}'
}

[unsafe]
pub fn unwrap_null_node<T>(factory NodeTypeFactory<T>, err IError) ?Node<T> {
	if err is NodeError {
		return new_node<T>(factory, err.node)
	}
	return none
}

pub fn check_tsnode(node C.TSNode) ? {
	if node.is_null() {
		return IError(NodeError{
			node: node
			msg: 'Node is null'
		})
	}
}

pub fn (node C.TSNode) text(text SourceText) string {
	start_index := node.start_byte()
	end_index := node.end_byte()
	if start_index >= end_index || start_index >= u32(text.len()) || end_index > u32(text.len()) {
		return ''
	}
	return text.substr(int(start_index), int(end_index))
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

pub fn (node C.TSNode) type_name() string {
	if node.is_null() {
		return '<null node>'
	}
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

pub fn (node C.TSNode) is_error() bool {
	if node.is_null() {
		return true
	}
	return C.ts_node_has_error(node)
}

pub fn (node C.TSNode) parent() ?C.TSNode {
	check_tsnode(node) ?
	parent := C.ts_node_parent(node)
	check_tsnode(parent) ?
	return parent
}

pub fn (node C.TSNode) child(pos u32) ?C.TSNode {
	check_tsnode(node) ?
	child := C.ts_node_child(node, pos)
	check_tsnode(child) ?
	return child
}

[inline]
pub fn (node C.TSNode) child_count() u32 {
	return C.ts_node_child_count(node)
}

pub fn (node C.TSNode) named_child(pos u32) ?C.TSNode {
	check_tsnode(node) ?
	child := C.ts_node_named_child(node, pos)
	check_tsnode(child) ?
	return child
}

pub fn (node C.TSNode) named_child_count() u32 {
	if node.is_null() {
		return 0
	}
	return C.ts_node_named_child_count(node)
}

pub fn (node C.TSNode) child_by_field_name(name string) ?C.TSNode {
	// defer {
	// 	unsafe { name.free() }
	// }
	check_tsnode(node) ?
	child := C.ts_node_child_by_field_name(node, &char(name.str), u32(name.len))
	check_tsnode(child) ?
	return child
}

pub fn (node C.TSNode) next_sibling() ?C.TSNode {
	check_tsnode(node) ?
	sibling := C.ts_node_next_sibling(node)
	check_tsnode(sibling) ?
	return sibling
}

pub fn (node C.TSNode) prev_sibling() ?C.TSNode {
	check_tsnode(node) ?
	sibling := C.ts_node_prev_sibling(node)
	check_tsnode(sibling) ?
	return sibling
}

pub fn (node C.TSNode) next_named_sibling() ?C.TSNode {
	check_tsnode(node) ?
	sibling := C.ts_node_next_named_sibling(node)
	check_tsnode(sibling) ?
	return sibling
}

pub fn (node C.TSNode) prev_named_sibling() ?C.TSNode {
	check_tsnode(node) ?
	sibling := C.ts_node_prev_named_sibling(node)
	check_tsnode(sibling) ?
	return sibling
}

pub fn (node C.TSNode) first_child_for_byte(offset u32) ?C.TSNode {
	check_tsnode(node) ?
	got_node := C.ts_node_first_child_for_byte(node, offset)
	check_tsnode(got_node) ?
	return got_node
}

pub fn (node C.TSNode) first_named_child_for_byte(offset u32) ?C.TSNode {
	check_tsnode(node) ?
	got_node := C.ts_node_first_named_child_for_byte(node, offset)
	check_tsnode(got_node) ?
	return got_node
}

pub fn (node C.TSNode) descendant_for_byte_range(start_range u32, end_range u32) ?C.TSNode {
	check_tsnode(node) ?
	got_node := C.ts_node_descendant_for_byte_range(node, start_range, end_range)
	check_tsnode(got_node) ?
	return got_node
}

pub fn (node C.TSNode) descendant_for_point_range(start_point C.TSPoint, end_point C.TSPoint) ?C.TSNode {
	check_tsnode(node) ?
	got_node := C.ts_node_descendant_for_point_range(node, start_point, end_point)
	check_tsnode(got_node) ?
	return got_node
}

pub fn (node C.TSNode) named_descendant_for_byte_range(start_range u32, end_range u32) ?C.TSNode {
	check_tsnode(node) ?
	got_node := C.ts_node_named_descendant_for_byte_range(node, start_range, end_range)
	check_tsnode(got_node) ?
	return got_node
}

pub fn (node C.TSNode) named_descendant_for_point_range(start_point C.TSPoint, end_point C.TSPoint) ?C.TSNode {
	check_tsnode(node) ?
	got_node := C.ts_node_named_descendant_for_point_range(node, start_point, end_point)
	check_tsnode(got_node) ?
	return got_node
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
pub fn (cursor &C.TSTreeCursor) current_node() ?C.TSNode {
	got_node := C.ts_tree_cursor_current_node(cursor)
	check_tsnode(got_node) ?
	return got_node
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

// V Types
pub struct Parser<T> {
mut:
	raw_parser   &C.TSParser [required]
	type_factory NodeTypeFactory<T> [required]
}

[inline]
pub fn (mut p Parser<T>) reset() {
	p.raw_parser.reset()
}

[params]
pub struct ParserParseConfig {
	source string [required]
	tree   &C.TSTree = &C.TSTree(0)
}

pub fn (mut p Parser<T>) parse_string(cfg ParserParseConfig) &Tree<T> {
	tree := p.raw_parser.parse_string_with_old_tree(cfg.source, cfg.tree)
	return &Tree<T>{
		raw_tree: tree
		type_factory: p.type_factory
	}
}

pub fn new_parser<T>(language &C.TSLanguage, type_factory NodeTypeFactory<T>) &Parser<T> {
	mut parser := new_ts_parser()
	parser.set_language(language)

	return &Parser<T>{
		raw_parser: parser
		type_factory: type_factory
	}
}

pub interface NodeTypeFactory<T> {
	get_type(type_name string) T
}

pub struct Tree<T> {
	type_factory   NodeTypeFactory<T> [required]
pub:
	raw_tree       &C.TSTree [required]
}

pub fn (tree Tree<T>) root_node() Node<T> {
	return new_node<T>(tree.type_factory, tree.raw_tree.root_node())
}

fn new_node<T>(factory NodeTypeFactory<T>, node C.TSNode) Node<T> {
	return Node<T>{
		raw_node: node
		type_factory: factory
		type_name: factory.get_type(node.type_name())
	}
}

pub struct Node<T> {
	type_factory NodeTypeFactory<T> [required]
pub:
	raw_node     C.TSNode           [required]
	type_name    T                  [required]
}

pub fn (node Node<T>) text(text SourceText) string {
	return node.raw_node.text(text)
}

[inline]
pub fn (node Node<T>) str() string {
	return node.raw_node.sexpr_str()
}

[inline]
pub fn (node Node<T>) start_point() C.TSPoint {
	return node.raw_node.start_point()
}

[inline]
pub fn (node Node<T>) end_point() C.TSPoint {
	return node.raw_node.end_point()
}

[inline]
pub fn (node Node<T>) start_byte() u32 {
	return node.raw_node.start_byte()
}

[inline]
pub fn (node Node<T>) end_byte() u32 {
	return node.raw_node.end_byte()
}

[inline]
pub fn (node Node<T>) range() C.TSRange {
	return node.raw_node.range()
}

[inline]
pub fn (node Node<T>) is_null() bool {
	return node.raw_node.is_null()
}

[inline]
pub fn (node Node<T>) is_named() bool {
	return node.raw_node.is_named()
}

[inline]
pub fn (node Node<T>) is_missing() bool {
	return node.raw_node.is_missing()
}

[inline]
pub fn (node Node<T>) is_extra() bool {
	return node.raw_node.is_extra()
}

[inline]
pub fn (node Node<T>) has_changes() bool {
	return node.raw_node.has_changes()
}

[inline]
pub fn (node Node<T>) is_error() bool {
	return node.raw_node.is_error()
}

pub fn (node Node<T>) parent() ?Node<T> {
	parent := node.raw_node.parent()?
	return new_node<T>(node.type_factory, parent)
}

pub fn (node Node<T>) child(pos u32) ?Node<T> {
	child := node.raw_node.child(pos)?
	return new_node<T>(node.type_factory, child)
}

[inline]
pub fn (node Node<T>) child_count() u32 {
	return node.raw_node.child_count()
}

pub fn (node Node<T>) named_child(pos u32) ?Node<T> {
	child := node.raw_node.named_child(pos)?
	return new_node<T>(node.type_factory, child)
}

[inline]
pub fn (node Node<T>) named_child_count() u32 {
	return node.raw_node.named_child_count()
}

pub fn (node Node<T>) child_by_field_name(name string) ?Node<T> {
	child := node.raw_node.child_by_field_name(name)?
	return new_node<T>(node.type_factory, child)
}

pub fn (node Node<T>) next_sibling() ?Node<T> {
	sibling := node.raw_node.next_sibling()?
	return new_node<T>(node.type_factory, sibling)
}

pub fn (node Node<T>) prev_sibling() ?Node<T> {
	sibling := node.raw_node.prev_sibling()?
	return new_node<T>(node.type_factory, sibling)
}

pub fn (node Node<T>) next_named_sibling() ?Node<T> {
	sibling := node.raw_node.next_named_sibling()?
	return new_node<T>(node.type_factory, sibling)
}

pub fn (node Node<T>) prev_named_sibling() ?Node<T> {
	sibling := node.raw_node.prev_named_sibling()?
	return new_node<T>(node.type_factory, sibling)
}

pub fn (node Node<T>) first_child_for_byte(offset u32) ?Node<T> {
	child := node.raw_node.first_child_for_byte(offset)?
	return new_node<T>(node.type_factory, child)
}

pub fn (node Node<T>) first_named_child_for_byte(offset u32) ?Node<T> {
	child := node.raw_node.first_named_child_for_byte(offset)?
	return new_node<T>(node.type_factory, child)
}

pub fn (node Node<T>) descendant_for_byte_range(start_range u32, end_range u32) ?Node<T> {
	desc := node.raw_node.descendant_for_byte_range(start_range, end_range)?
	return new_node<T>(node.type_factory, desc)
}

pub fn (node Node<T>) descendant_for_point_range(start_point C.TSPoint, end_point C.TSPoint) ?Node<T> {
	desc := node.raw_node.descendant_for_point_range(start_point, end_point)?
	return new_node<T>(node.type_factory, desc)
}

pub fn (node Node<T>) named_descendant_for_byte_range(start_range u32, end_range u32) ?Node<T> {
	desc := node.raw_node.named_descendant_for_byte_range(start_range, end_range)?
	return new_node<T>(node.type_factory, desc)
}

pub fn (node Node<T>) named_descendant_for_point_range(start_point C.TSPoint, end_point C.TSPoint) ?Node<T> {
	desc := node.raw_node.named_descendant_for_point_range(start_point, end_point)?
	return new_node<T>(node.type_factory, desc)
}

pub fn (node Node<T>) last_node_by_type(type_name T) ?Node<T> {
	len := node.named_child_count()
	mut named_child := node.named_child(len - 1)?
	for i := int(len - 1); i >= 0; i-- {
		if named_child.type_name == type_name {
			return named_child
		}
		named_child = named_child.prev_named_sibling() or {
			continue
		}
	}
	return none
}

[inline]
pub fn (node Node<T>) == (other_node Node<T>) bool {
	return C.ts_node_eq(node.raw_node, other_node.raw_node)
}

[inline]
pub fn (node Node<T>) tree_cursor() TreeCursor<T> {
	return TreeCursor<T>{
		type_factory: node.type_factory
		raw_cursor: node.raw_node.tree_cursor()
	}
}

pub struct TreeCursor<T> {
	type_factory NodeTypeFactory<T> [required]
pub mut:
	raw_cursor   C.TSTreeCursor     [required]
}

[inline]
pub fn (mut cursor TreeCursor<T>) reset(node Node<T>) {
	cursor.raw_cursor.reset(node.raw_node)
}

[inline]
pub fn (cursor TreeCursor<T>) current_node() ?Node<T> {
	got_node := cursor.raw_cursor.current_node()?
	return new_node<T>(cursor.type_factory, got_node)
}

[inline]
pub fn (cursor TreeCursor<T>) current_field_name() string {
	return cursor.raw_cursor.current_field_name()
}

[inline]
pub fn (mut cursor TreeCursor<T>) to_parent() bool {
	return cursor.raw_cursor.to_parent()
}

[inline]
pub fn (mut cursor TreeCursor<T>) next() bool {
	return cursor.raw_cursor.next()
}

[inline]
pub fn (mut cursor TreeCursor<T>) to_first_child() bool {
	return cursor.raw_cursor.to_first_child()
}

pub interface SourceText {
	len() int
	at(idx int) rune
	substr(start int, end int) string
}