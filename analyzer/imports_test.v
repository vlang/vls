module analyzer

import tree_sitter
import tree_sitter_v as v
import os

const (
	sample_content = '
	import os
	import env
	'
	sample_content_bytes = sample_content.runes()
	vexe_path            = os.dir(os.getenv('VEXE'))
	// not a real path
	file_path            = '@TEST/hello.v'
	test_lookup_paths    = [
		os.join_path(vexe_path, 'vlib'),
	]
)

fn parse_content() &C.TSTree {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	return parser.parse_string(analyzer.sample_content)
}

fn test_scan_imports() ? {
	tree := parse_content()
	mut store := &Store{
		reporter: &Collector{}
	}

	store.set_active_file_path(analyzer.file_path, 1)
	imports := store.scan_imports(tree, analyzer.sample_content_bytes)
	assert imports.len == 2
	assert imports[0].absolute_module_name == 'os'
	assert imports[1].absolute_module_name == 'env'
}

fn test_inject_paths_of_new_imports() ? {
	tree := parse_content()
	mut store := &Store{
		reporter: &Collector{}
	}

	store.set_active_file_path(analyzer.file_path, 1)
	mut imports := store.scan_imports(tree, analyzer.sample_content_bytes)
	assert imports.len == 2
	assert imports[0].absolute_module_name == 'os'
	assert imports[1].absolute_module_name == 'env'

	store.inject_paths_of_new_imports(mut imports, os.join_path(analyzer.vexe_path, 'vlib'))

	assert imports[0].resolved == true
	assert imports[0].path == os.join_path(analyzer.vexe_path, 'vlib', 'os')
	assert imports[1].resolved == false
}

fn test_import_modules_from_tree() ? {
	tree := parse_content()
	mut store := &Store{
		reporter: &Collector{}
		default_import_paths: analyzer.test_lookup_paths
	}

	store.set_active_file_path(analyzer.file_path, 1)
	store.import_modules_from_tree(tree, analyzer.sample_content_bytes)

	assert store.imports[store.cur_dir].len == 2
	assert store.imports[store.cur_dir][0].absolute_module_name == 'os'
	assert store.imports[store.cur_dir][0].resolved == true
	assert store.imports[store.cur_dir][0].imported == true
	assert store.imports[store.cur_dir][1].absolute_module_name == 'env'
	assert store.imports[store.cur_dir][1].resolved == false

	eprintln(store.dependency_tree)
	$if !windows {
		assert store.dependency_tree.size() == 4
	} $else {
		assert store.dependency_tree.size() == 5
	}
}

fn test_import_modules_with_edits() ? {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	sample_content2 := '
	import os
	'

	mut tree := parser.parse_string(sample_content2)
	mut store := &Store{
		reporter: &Collector{}
		default_import_paths: analyzer.test_lookup_paths
	}
	store.set_active_file_path(analyzer.file_path, 1)
	store.import_modules_from_tree(tree, sample_content2.runes())
	store.cleanup_imports()

	assert store.imports[store.cur_dir].len == 1
	assert store.imports[store.cur_dir][0].absolute_module_name == 'os'
	assert store.imports[store.cur_dir][0].resolved == true
	assert store.imports[store.cur_dir][0].imported == true
	$if !windows {
		assert store.dependency_tree.size() == 4
	} $else {
		assert store.dependency_tree.size() == 5
	}
	assert store.dependency_tree.has(os.join_path(analyzer.vexe_path, 'vlib', 'os')) == true

	new_content := '
	import osx
	'

	// conform the tree to the new content
	tree.edit(
		start_byte: u32(10)
		old_end_byte: u32(10)
		new_end_byte: u32(11)
		start_point: C.TSPoint{u32(1), u32(8)}
		old_end_point: C.TSPoint{u32(1), u32(8)}
		new_end_point: C.TSPoint{u32(1), u32(9)}
	)

	new_tree := parser.parse_string_with_old_tree(new_content, tree)
	store.import_modules_from_tree(new_tree, new_content.runes())
	store.cleanup_imports()

	assert store.imports[store.cur_dir].len == 0
	assert store.dependency_tree.size() == 1
	assert store.dependency_tree.has(os.join_path(analyzer.vexe_path, 'vlib', 'os')) == false

	// go back to old
	new_tree.edit(
		start_byte: u32(10)
		old_end_byte: u32(10)
		new_end_byte: u32(10)
		start_point: C.TSPoint{u32(1), u32(8)}
		old_end_point: C.TSPoint{u32(1), u32(9)}
		new_end_point: C.TSPoint{u32(1), u32(8)}
	)

	new_new_tree := parser.parse_string_with_old_tree(sample_content2, new_tree)
	store.import_modules_from_tree(new_new_tree, sample_content2.runes())
	store.cleanup_imports()

	assert store.imports[store.cur_dir].len == 1
	assert store.imports[store.cur_dir][0].absolute_module_name == 'os'
	assert store.imports[store.cur_dir][0].path.len != 0
	assert store.imports[store.cur_dir][0].resolved == true
	assert store.imports[store.cur_dir][0].imported == true
	$if !windows {
		assert store.dependency_tree.size() == 4
	} $else {
		assert store.dependency_tree.size() == 5
	}
	// for name, _ in store.dependency_tree.get_nodes() {
	// 	eprintln('Checking: $name')
	// 	assert (name in store.imports) == true
	// }
}
