module analyzer

import tree_sitter
import tree_sitter_v.bindings.v
import os

const (
	sample_content = '
	import os
	import env
	'
	sample_content_bytes = sample_content.bytes()
	vexe_path = os.dir(os.getenv('VEXE'))
	// not a real path
	file_path = '@TEST/hello.v'
)

fn parse_content() &C.TSTree {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	return parser.parse_string(sample_content)
}

fn test_scan_imports() ? {
	tree := parse_content()
	mut store := Store{}

	store.set_active_file_path(file_path)
	imports := store.scan_imports(tree, sample_content_bytes)
	assert imports.len == 2
	assert imports[0].module_name == 'os'
	assert imports[1].module_name == 'env'
}

fn test_inject_paths_of_new_imports() ? {
	tree := parse_content()
	mut store := Store{}

	store.set_active_file_path(file_path)
	mut imports := store.scan_imports(tree, sample_content_bytes)
	assert imports.len == 2
	assert imports[0].module_name == 'os'
	assert imports[1].module_name == 'env'

	store.inject_paths_of_new_imports(mut imports, [
		os.join_path(vexe_path, 'vlib')
	])

	assert imports[0].resolved == true
	assert imports[0].path == os.join_path(vexe_path, 'vlib', 'os')
	assert imports[1].resolved == false
}

fn test_import_modules() ? {
	tree := parse_content()
	mut store := Store{}

	store.set_active_file_path(file_path)
	store.import_modules(tree, sample_content_bytes)

	println(store.imports)
	// println(store.dependency_tree.get_available_nodes())
	assert store.dependency_tree.get_nodes().len == 2
}