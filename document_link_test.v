// Tests for textDocument/documentLink: one link per import that resolves to a
// module file, and one per absolute URL in a `//` comment.

module main

import os
import json2

fn dl_app() &App {
	temp_dir := os.join_path(os.temp_dir(), 'vls_doclink_test')
	os.mkdir_all(temp_dir) or {
		assert false, 'Failed to create test temp dir: ${err}'
		return &App{
			text:       ''
			open_files: map[string]string{}
			temp_dir:   temp_dir
		}
	}
	return &App{
		text:       ''
		open_files: map[string]string{}
		temp_dir:   temp_dir
	}
}

fn dl_mkdir(path string) {
	os.mkdir_all(path) or {
		assert false, 'Failed to create directory ${path}: ${err}'
		return
	}
}

fn dl_write(path string, content string) {
	os.write_file(path, content) or {
		assert false, 'Failed to write file ${path}: ${err}'
		return
	}
}

fn dl_uri(path string) string {
	return path_to_uri(path)
}

fn dl_cleanup(app &App) {
	os.rmdir_all(app.temp_dir) or {}
}

// dl_project writes `content` as main.v in a fresh folder of the app's temp dir
// and returns its path.
fn dl_project(app &App, name string, content string) string {
	root := os.join_path(app.temp_dir, name)
	dl_mkdir(root)
	path := os.join_path(root, 'main.v')
	dl_write(path, content)
	return path
}

fn test_document_link_a_resolved_import_links_to_the_module_file() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	root := os.join_path(app.temp_dir, 'dl_resolved')
	dl_mkdir(os.join_path(root, 'shapes'))
	dl_write(os.join_path(root, 'shapes', 'shapes.v'), 'module shapes\n\npub fn render() {}\n')
	main_path := dl_project(app, 'dl_resolved', 'module main\n\nimport shapes\n\nfn main() {\n\tshapes.render()\n}\n')

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 1
	assert links[0].target == dl_uri(os.join_path(root, 'shapes', 'shapes.v'))
	assert links[0].range.start.line == 2
	assert links[0].range.start.char == 7
	assert links[0].range.end.line == 2
	assert links[0].range.end.char == 13
}

fn test_document_link_a_submodule_import_links_into_the_subdirectory() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	root := os.join_path(app.temp_dir, 'dl_submodule')
	dl_mkdir(os.join_path(root, 'utils', 'parse'))
	dl_write(os.join_path(root, 'utils', 'parse', 'parse.v'), "module parse\n\npub fn line() string {\n\treturn ''\n}\n")
	main_path := dl_project(app, 'dl_submodule', 'module main\n\nimport utils.parse\n\nfn main() {\n\tparse.line()\n}\n')

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 1
	assert links[0].target == dl_uri(os.join_path(root, 'utils', 'parse', 'parse.v'))
	assert links[0].range.start.line == 2
	assert links[0].range.start.char == 7
	assert links[0].range.end.char == 18
}

fn test_document_link_a_grouped_import_links_every_module_it_names() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	root := os.join_path(app.temp_dir, 'dl_grouped')
	dl_mkdir(os.join_path(root, 'shapes'))
	dl_write(os.join_path(root, 'shapes', 'shapes.v'), 'module shapes\n\npub fn render() {}\n')
	dl_mkdir(os.join_path(root, 'utils', 'parse'))
	dl_write(os.join_path(root, 'utils', 'parse', 'parse.v'), "module parse\n\npub fn line() string {\n\treturn ''\n}\n")
	main_path := dl_project(app, 'dl_grouped', 'module main\n\nimport (\n\tshapes\n\tutils.parse\n)\n\nfn main() {\n\tshapes.render()\n\tparse.line()\n}\n')

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 2
	assert links[0].target == dl_uri(os.join_path(root, 'shapes', 'shapes.v'))
	assert links[0].range.start.line == 3
	assert links[0].range.start.char == 1
	assert links[0].range.end.char == 7
	assert links[1].target == dl_uri(os.join_path(root, 'utils', 'parse', 'parse.v'))
	assert links[1].range.start.line == 4
	assert links[1].range.start.char == 1
	assert links[1].range.end.char == 12
}

fn test_document_link_c_import_is_not_a_link() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	root := os.join_path(app.temp_dir, 'dl_c_import')
	dl_mkdir(os.join_path(root, 'C'))
	dl_write(os.join_path(root, 'C', 'C.v'), 'module C\n')
	main_path := dl_project(app, 'dl_c_import', 'module main\n\nimport C\n\nfn main() {}\n')

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 0, 'C interop has no module folder to link to, even one named C'
}

fn test_document_link_an_import_that_resolves_to_no_file_is_not_a_link() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	root := os.join_path(app.temp_dir, 'dl_unresolved')
	dl_mkdir(os.join_path(root, 'notes'))
	dl_write(os.join_path(root, 'notes', 'README.md'), 'not a module\n')
	main_path := dl_project(app, 'dl_unresolved', 'module main\n\nimport nowhere.at.all\nimport notes\n\nfn main() {}\n')

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 0, 'no link may name a file the client cannot open'
}

fn test_document_link_a_doc_comment_url_is_a_link_with_its_own_range() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	main_path := dl_project(app, 'dl_doc_url', 'module main\n\n// Docs: https://example.com/guide\nfn main() {}\n')

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 1
	assert links[0].target == 'https://example.com/guide'
	assert links[0].range.start.line == 2
	assert links[0].range.start.char == 9
	assert links[0].range.end.line == 2
	assert links[0].range.end.char == 34
}

fn test_document_link_a_url_in_a_string_literal_is_not_a_link() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	main_path := dl_project(app, 'dl_string_url', "module main\n\nfn main() {\n\turl := 'https://example.com/literal'\n\t// kept: https://example.com/comment\n\tprintln(url)\n}\n")

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 1
	assert links[0].target == 'https://example.com/comment'
	assert links[0].range.start.line == 4
}

fn test_document_link_http_and_https_urls_are_both_found() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	main_path := dl_project(app, 'dl_two_schemes', 'module main\n\n// Docs at https://example.com and mirror at http://example.org\nfn main() {}\n')

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 2
	assert links[0].target == 'https://example.com'
	assert links[1].target == 'http://example.org'
}

fn test_document_link_a_url_ends_at_whitespace_and_at_a_parenthesis() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	main_path := dl_project(app, 'dl_url_end', 'module main\n\n// (see https://example.com/parens) and https://example.com/plain\nfn main() {}\n')

	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 2
	assert links[0].target == 'https://example.com/parens'
	assert links[1].target == 'https://example.com/plain'
}

fn test_document_link_ranges_use_the_negotiated_encoding() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	main_path := dl_project(app, 'dl_encoding', 'module main\n\n// Дока https://example.com/x\nfn main() {}\n')

	app.position_encoding = .utf8
	links := app.build_document_links(dl_uri(main_path))

	assert links.len == 1
	assert links[0].target == 'https://example.com/x'
	assert links[0].range.start.line == 2
	assert links[0].range.start.char == 12
	assert links[0].range.end.char == 33

	app.position_encoding = .utf16
	utf16_links := app.build_document_links(dl_uri(main_path))

	assert utf16_links[0].range.start.char == 8
	assert utf16_links[0].range.end.char == 29
}

fn test_document_link_handler_answers_with_the_links_of_the_document() {
	mut app := dl_app()
	defer {
		dl_cleanup(app)
	}
	root := os.join_path(app.temp_dir, 'dl_handler')
	dl_mkdir(os.join_path(root, 'shapes'))
	dl_write(os.join_path(root, 'shapes', 'shapes.v'), 'module shapes\n\npub fn render() {}\n')
	main_path := dl_project(app, 'dl_handler', 'module main\n\nimport shapes\n\n// see https://example.com/handler\nfn main() {\n\tshapes.render()\n}\n')

	response := app.handle_document_link(Request{
		id:     4242
		method: 'textDocument/documentLink'
		params: json2.encode(DocumentLinkParams{
			text_document: TextDocumentIdentifier{
				uri: dl_uri(main_path)
			}
		},
			escape_unicode: true
		)
	})

	assert response.id == 4242
	assert response.result is []DocumentLink
	links := response.result as []DocumentLink
	assert links.len == 2
	assert links[0].target == dl_uri(os.join_path(root, 'shapes', 'shapes.v'))
	assert links[1].target == 'https://example.com/handler'
}
