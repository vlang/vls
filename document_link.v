// Links a client can click: one per `import` statement, pointing at the module
// file V compiles for it, and one per absolute URL the file's comments hold.
// Nothing is invented here — a link exists only where its target does — and
// nothing is asked of the compiler: the text and the indexed module resolution
// are enough, so the request never waits for a build.
module main

import os
import json2

// document_link_c_imports are the imports that name no module folder, so they
// have no file to link to: `C` is C interop and `JS` the JavaScript backend's.
const document_link_c_imports = ['C', 'JS']

// document_link_schemes are the absolute URL prefixes a comment may hold.
const document_link_schemes = ['https://', 'http://']

// document_link_url_cap is how many comment URLs one file is scanned for. A file
// with more than that keeps the first `document_link_url_cap` links and drops the
// rest, so one request over a generated or minified file cannot become an
// unbounded scan.
const document_link_url_cap = 500

// handle_document_link handles textDocument/documentLink: the modules the file
// imports and the URLs its comments hold, each as a clickable range.
fn (mut app App) handle_document_link(request Request) Response {
	params := json2.decode[DocumentLinkParams](request.params) or {
		log('Failed to decode DocumentLinkParams: ${err.msg()}')
		return Response{
			id:     request.id
			result: []DocumentLink{}
		}
	}
	return Response{
		id:     request.id
		result: app.build_document_links(params.text_document.uri)
	}
}

// build_document_links returns the links of the file at `uri`, ordered by
// position: one per `import` statement that resolves to a module file, and one
// per absolute URL in a `//` comment. An import that resolves to no file is not a
// link, so a client is never sent a target that is not there.
fn (mut app App) build_document_links(uri string) []DocumentLink {
	content := app.open_files[uri] or {
		os.read_file(uri_to_path(uri)) or { return []DocumentLink{} }
	}
	lines := content.split_into_lines()
	mut links := []DocumentLink{}
	links << document_link_import_links(app, uri, content, lines)
	links << document_link_comment_url_links(content, lines, app.position_encoding)
	links.sort_with_compare(fn (a &DocumentLink, b &DocumentLink) int {
		if a.range.start.line != b.range.start.line {
			return a.range.start.line - b.range.start.line
		}
		return a.range.start.char - b.range.start.char
	})
	return links
}

// document_link_import_links resolves each import of `content` to the module file
// V compiles for it. The position of the module path comes from the file's own
// import scan, so a grouped import or one with an alias is where that scan says
// it is.
fn document_link_import_links(app &App, uri string, content string, lines []string) []DocumentLink {
	mut links := []DocumentLink{}
	work_dir := os.dir(uri_to_path(uri))
	for ref in parse_import_refs(content) {
		if ref.path in document_link_c_imports || ref.line < 0 || ref.line >= lines.len {
			continue
		}
		line := lines[ref.line]
		if ref.col < 0 || ref.col + ref.path.len > line.len {
			continue
		}
		module_dir := app.resolve_indexed_import_module_dir(ref.path, work_dir)
		if module_dir == '' {
			continue
		}
		// A module folder is named after the module and holds the file V compiles
		// first, `<module>.v`. Without that file there is no link: the target a
		// client would open has to exist.
		module_name := ref.path.all_after_last('.')
		module_file := os.join_path(module_dir, '${module_name}.v')
		if !os.is_file(module_file) {
			continue
		}
		links << DocumentLink{
			range:  document_link_range(line, ref.line, ref.col, ref.col + ref.path.len, app.position_encoding)
			target: path_to_uri(module_file)
		}
	}
	return links
}

// document_link_comment_url_links returns one link per absolute URL in a `//`
// comment of `content`, doc comments included. The ranges come from the file's
// own tokenizer, so a URL inside a string literal is never one of them, and a
// `/* */` block comment is not either: V's doc comments are `//`.
fn document_link_comment_url_links(content string, lines []string, enc PositionEncoding) []DocumentLink {
	mut links := []DocumentLink{}
	for token in tokenize_v_source(content) {
		if token.type_idx != sem_tok_comment || token.line < 0 || token.line >= lines.len {
			continue
		}
		line := lines[token.line]
		if token.start < 0 || token.start + token.length > line.len {
			continue
		}
		text := line[token.start..token.start + token.length]
		if !text.starts_with('//') {
			continue
		}
		for span in document_link_url_spans(text) {
			if links.len >= document_link_url_cap {
				break
			}
			links << DocumentLink{
				range:  document_link_range(line, token.line, token.start + span[0], token.start + span[1], enc)
				target: text[span[0]..span[1]]
			}
		}
	}
	return links
}

// document_link_url_spans returns the byte spans of the absolute URLs in `text`.
// A URL runs from the first byte of its scheme to the first whitespace or `)`
// after it, and has to hold something past the scheme to be a link at all.
fn document_link_url_spans(text string) [][2]int {
	mut spans := [][2]int{}
	mut at := 0
	for at < text.len {
		scheme_len := document_link_scheme_len(text, at)
		if scheme_len == 0 {
			at++
			continue
		}
		start := at
		at += scheme_len
		mut end := at
		for end < text.len && !document_link_url_ends_at(text[end]) {
			end++
		}
		if end > at {
			spans << [start, end]!
		}
		at = end
	}
	return spans
}

// document_link_scheme_len returns the length of the `https://` or `http://`
// scheme starting at `text[at]`, or 0 when no absolute URL starts there.
fn document_link_scheme_len(text string, at int) int {
	for scheme in document_link_schemes {
		if document_link_text_matches(text, at, scheme) {
			return scheme.len
		}
	}
	return 0
}

fn document_link_text_matches(text string, at int, needle string) bool {
	if at < 0 || at + needle.len > text.len {
		return false
	}
	for i in 0 .. needle.len {
		if text[at + i] != needle[i] {
			return false
		}
	}
	return true
}

// document_link_url_ends_at reports whether `c` terminates a URL written in a
// comment: whitespace, or a `)` closing the parenthesis the URL sits in.
fn document_link_url_ends_at(c u8) bool {
	return c == ` ` || c == `\t` || c == `\r` || c == `)`
}

// document_link_range builds the range of `line[from..to]` in the encoding the
// client negotiated, so the bytes this scan works in are never reported as
// characters.
fn document_link_range(line string, line_idx int, from int, to int, enc PositionEncoding) LSPRange {
	start := byte_to_encoded_col(line, from, enc)
	end := byte_to_encoded_col(line, to, enc)
	return LSPRange{
		start: Position{
			line: line_idx
			char: start
		}
		end:   Position{
			line: line_idx
			char: end
		}
	}
}
