// Copyright (c) 2025 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

// Tests for the "Implement missing members" quick fix. Every helper below is
// named with an `impl_` prefix, because all `_test.v` files of this module share
// one namespace and a colliding name would break the build.

// ImplSpan is one edit, resolved to the byte range it applies to.
struct ImplSpan {
	start    int
	end      int
	new_text string
}

// impl_test_app returns an App that holds `content` as the open buffer of `uri`
// and has indexed it, which is the state the quick fix reads: the text the
// editor holds, and the declarations the index parses out of it.
fn impl_test_app(content string, uri string) App {
	mut app := App{}
	app.open_files[uri] = content
	app.symbol_index[uri] = build_index_entry(content, app.position_encoding)
	return app
}

// impl_position returns where the first `needle` of `content` sits, which is both
// where a cursor on it lands and where a range selecting it starts.
fn impl_position(content string, needle string) Position {
	for line, text in content.split_into_lines() {
		if col := text.index(needle) {
			return Position{
				line: line
				char: col
			}
		}
	}
	assert false, 'the fixture holds no ${needle}'
	return Position{}
}

// impl_cursor returns the empty range an editor reports for a cursor sitting on
// the first `needle` of `content`.
fn impl_cursor(content string, needle string) LSPRange {
	at := impl_position(content, needle)
	return LSPRange{
		start: at
		end:   at
	}
}

// impl_apply applies the edits an action carries to `content`, from the last one
// back, so a test can assert what the document looks like once the quick fix is
// taken. Every fixture here is ASCII, so a UTF-16 unit is a byte.
fn impl_apply(content string, action CodeAction) string {
	edit := action.edit or {
		assert false, 'the action must carry an edit'
		return content
	}
	starts := line_start_offsets(content)
	mut spans := []ImplSpan{}
	for _, edits in edit.changes {
		for one in edits {
			spans << ImplSpan{
				start:    position_to_byte_offset(content, starts, one.range.start.line, one.range.start.char, PositionEncoding.utf16)
				end:      position_to_byte_offset(content, starts, one.range.end.line, one.range.end.char, PositionEncoding.utf16)
				new_text: one.new_text
			}
		}
	}
	spans.sort_with_compare(fn (a &ImplSpan, b &ImplSpan) int {
		return b.start - a.start
	})
	mut out := content
	for span in spans {
		assert span.start >= 0 && span.start <= span.end, 'an edit must not end before it starts'
		assert span.end <= out.len, 'an edit must stay inside the document'
		out = out[..span.start] + span.new_text + out[span.end..]
	}
	return out
}

// --- Implement missing members ---

// The commonest case: the struct already has one of the two methods the only
// fitting interface declares, so only the missing one is written, and the
// receiver is named after the one the struct already uses.
fn test_implement_members_happy_path_inserts_one_stub_per_missing_member() {
	uri := 'file:///vls-impl-mod/main.v'
	content := "module main

interface Speaker {
	speak() string
	volume() int
}

struct Dog {
	name string
}

fn (d Dog) speak() string {
	return 'woof'
}
"
	mut app := impl_test_app(content, uri)
	action := app.build_implement_members_action(uri, content, impl_cursor(content, 'struct Dog')) or {
		assert false, 'a struct missing one member of exactly one interface must be offered the action'
		return
	}
	assert action.kind == code_action_kind_quickfix, 'the implement members action is a quick fix'
	assert action.title == 'Implement missing members of `Speaker`', 'the title names the interface the stubs come from'
	expected := "module main

interface Speaker {
	speak() string
	volume() int
}

struct Dog {
	name string
}

// volume does ...
fn (mut d Dog) volume() int {
	return 0
}

fn (d Dog) speak() string {
	return 'woof'
}
"
	assert impl_apply(content, action) == expected, 'the missing member is written after the body of the struct'
}

// A member that declares no return type is stubbed with an empty body, because
// there is no value to return.
fn test_implement_members_stubs_a_void_member_with_an_empty_body() {
	uri := 'file:///vls-impl-mod/main.v'
	content := 'module main

interface Barker {
	bark()
}

struct Puppy {
}
'
	mut app := impl_test_app(content, uri)
	action := app.build_implement_members_action(uri, content, impl_cursor(content, 'struct Puppy')) or {
		assert false, 'a struct missing a void member must be offered the action'
		return
	}
	expected := 'module main

interface Barker {
	bark()
}

struct Puppy {
}

// bark does ...
fn (mut s Puppy) bark() {
}
'
	assert impl_apply(content, action) == expected, 'a void member takes an empty body'
}

// Each declared return type has a zero value of its own shape, and the receiver
// falls back to `s` for a struct that declares no method of its own.
fn test_implement_members_zero_value_per_return_type() {
	uri := 'file:///vls-impl-mod/main.v'
	content := 'module main

interface Everything {
	text() string
	count() int
	ratio() f64
	flag() bool
	tags() []string
	scores() map[string]int
	point() Point
}

struct Sink {
}

struct Point {
	x int
}
'
	mut app := impl_test_app(content, uri)
	action := app.build_implement_members_action(uri, content, impl_cursor(content, 'struct Sink')) or {
		assert false, 'a struct missing every member of one interface must be offered the action'
		return
	}
	expected := "module main

interface Everything {
	text() string
	count() int
	ratio() f64
	flag() bool
	tags() []string
	scores() map[string]int
	point() Point
}

struct Sink {
}

// text does ...
fn (mut s Sink) text() string {
	return ''
}
// count does ...
fn (mut s Sink) count() int {
	return 0
}
// ratio does ...
fn (mut s Sink) ratio() f64 {
	return 0
}
// flag does ...
fn (mut s Sink) flag() bool {
	return false
}
// tags does ...
fn (mut s Sink) tags() []string {
	return []string{}
}
// scores does ...
fn (mut s Sink) scores() map[string]int {
	return map[string]int{}
}
// point does ...
fn (mut s Sink) point() Point {
	return Point{}
}

struct Point {
	x int
}
"
	assert impl_apply(content, action) == expected, 'every return type takes the zero value of its own shape'
}

// A document written with CRLF terminators gets stubs that end their lines the
// same way, so taking the quick fix never rewrites the line endings of the file.
fn test_implement_members_keeps_the_line_endings_of_the_document() {
	uri := 'file:///vls-impl-mod/main.v'
	content := 'module main\r\n\r\ninterface Speaker {\r\n\tspeak() string\r\n\tvolume() int\r\n}\r\n\r\nstruct Dog {\r\n}\r\n'
	mut app := impl_test_app(content, uri)
	action := app.build_implement_members_action(uri, content, impl_cursor(content, 'struct Dog')) or {
		assert false, 'a CRLF document missing one member must be offered the action'
		return
	}
	expected := "module main\r\n\r\ninterface Speaker {\r\n\tspeak() string\r\n\tvolume() int\r\n}\r\n\r\nstruct Dog {\r\n}\r\n\r\n// speak does ...\r\nfn (mut s Dog) speak() string {\r\n\treturn ''\r\n}\r\n// volume does ...\r\nfn (mut s Dog) volume() int {\r\n\treturn 0\r\n}\r\n"
	assert impl_apply(content, action) == expected, 'the stubs end their lines the way the document does'
}

// The interface usually lives in another file of the module, and the index is
// where it is found, so the modules that split a type from its interface are
// covered by the same offer.
fn test_implement_members_reads_the_interface_from_another_file_of_the_module() {
	uri := 'file:///vls-impl-mod/dog.v'
	other := 'file:///vls-impl-mod/speaker.v'
	dog := 'module main

struct Dog {
	name string
}
'
	speaker := 'module main

interface Speaker {
	speak() string
	volume() int
}
'
	mut app := impl_test_app(dog, uri)
	app.open_files[other] = speaker
	app.symbol_index[other] = build_index_entry(speaker, app.position_encoding)
	action := app.build_implement_members_action(uri, dog, impl_cursor(dog, 'struct Dog')) or {
		assert false, 'an interface in a sibling file of the module must be offered too'
		return
	}
	assert action.title == 'Implement missing members of `Speaker`', 'the title names the interface from the other file'
	expected := "module main

struct Dog {
	name string
}

// speak does ...
fn (mut s Dog) speak() string {
	return ''
}
// volume does ...
fn (mut s Dog) volume() int {
	return 0
}
"
	assert impl_apply(dog, action) == expected, 'both members come from the interface in the sibling file'
}

// A struct that already has every member of the one interface that fits is left
// alone: there is nothing to write.
fn test_implement_members_refuses_a_struct_that_already_implements() {
	uri := 'file:///vls-impl-mod/main.v'
	content := "module main

interface Speaker {
	speak() string
}

struct Dog {
}

fn (d Dog) speak() string {
	return 'woof'
}
"
	mut app := impl_test_app(content, uri)
	action := app.build_implement_members_action(uri, content, impl_cursor(content, 'struct Dog'))
	assert action == none, 'a struct that already implements the only fitting interface must be left alone'
}

// Nothing is offered when every interface of the program declares a method the
// struct does not have, and none is offered when the program declares no
// interface at all.
fn test_implement_members_refuses_when_no_interface_fits() {
	uri := 'file:///vls-impl-mod/main.v'
	mismatch := 'module main

interface Speaker {
	speak() string
}

struct Rock {
}

fn (r Rock) roll() int {
	return 0
}
'
	mut app := impl_test_app(mismatch, uri)
	action := app.build_implement_members_action(uri, mismatch, impl_cursor(mismatch, 'struct Rock'))
	assert action == none, 'an interface that does not name the method the struct has is not the one it implements'

	no_interface := 'module main

struct Rock {
}

fn (r Rock) roll() int {
	return 0
}
'
	mut bare_app := impl_test_app(no_interface, uri)
	bare_action := bare_app.build_implement_members_action(uri, no_interface, impl_cursor(no_interface,
		'struct Rock'))
	assert bare_action == none, 'a program that declares no interface has nothing to implement'
}

// Two interfaces that both fit are left alone: the names cannot say which one the
// author meant, and stubs for the wrong one are worse than none.
fn test_implement_members_refuses_when_two_interfaces_match() {
	uri := 'file:///vls-impl-mod/main.v'
	content := 'module main

interface Speaker {
	speak() string
}

interface Barker {
	speak() string
	bark()
}

struct Dog {
}
'
	mut app := impl_test_app(content, uri)
	action := app.build_implement_members_action(uri, content, impl_cursor(content, 'struct Dog'))
	assert action == none, 'two interfaces that both fit must not both be stubbed'
}

// The action is offered from the line that declares the struct, and from nowhere
// else in the file.
fn test_implement_members_refuses_a_cursor_that_is_not_on_the_struct_name_line() {
	uri := 'file:///vls-impl-mod/main.v'
	content := 'module main

interface Speaker {
	speak() string
}

struct Dog {
	name string
}
'
	mut app := impl_test_app(content, uri)
	for needle in ['module main', 'interface Speaker', 'name string'] {
		action := app.build_implement_members_action(uri, content, impl_cursor(content, needle))
		assert action == none, 'a cursor on `${needle}` is not on the name line of a struct'
	}
}

// An interface that declares something this cannot stub as a method — an
// embedded interface, or a field — is not a candidate however well the struct
// fits it, because writing a `fn` for one of those is not what it declares.
fn test_implement_members_refuses_an_interface_it_cannot_stub_every_member_of() {
	uri := 'file:///vls-impl-mod/main.v'
	embedded := 'module main

interface Animal {
	Named
	speak() string
}

struct Dog {
}
'
	mut embedded_app := impl_test_app(embedded, uri)
	embedded_action := embedded_app.build_implement_members_action(uri, embedded, impl_cursor(embedded,
		'struct Dog'))
	assert embedded_action == none, 'an interface that embeds another interface is not stubbed'

	field := 'module main

interface Sized {
	count int
	speak() string
}

struct Dog {
}
'
	mut field_app := impl_test_app(field, uri)
	field_action := field_app.build_implement_members_action(uri, field, impl_cursor(field, 'struct Dog'))
	assert field_action == none, 'an interface that declares a field is not stubbed'
}

// A generic struct is stubbed with its type parameters in the receiver, the way
// its own methods would declare them.
fn test_implement_members_stubs_a_generic_struct_with_its_type_parameters() {
	uri := 'file:///vls-impl-mod/main.v'
	content := 'module main

interface Getter {
	get() int
}

struct Crate[T] {
	item T
}
'
	mut app := impl_test_app(content, uri)
	action := app.build_implement_members_action(uri, content, impl_cursor(content, 'struct Crate')) or {
		assert false, 'a generic struct missing one member must be offered the action'
		return
	}
	expected := 'module main

interface Getter {
	get() int
}

struct Crate[T] {
	item T
}

// get does ...
fn (mut s Crate[T]) get() int {
	return 0
}
'
	assert impl_apply(content, action) == expected, 'the receiver repeats the type parameters of the struct'
}
