import analyzer { Store, Runes, Collector, Importer, import_modules_from_tree }
import tree_sitter
import tree_sitter_v as v
import ast
import os

const (
	sample_content = '
	import os
	import env
	'
	sample_content_bytes = Runes(sample_content.runes())
	vexe_path            = os.dir(os.getenv('VEXE'))
	// not a real path
	file_path            = '@TEST/hello.v'
	file_dir             = '@TEST'
	test_lookup_paths    = [
		os.join_path(vexe_path, 'vlib'),
	]
)

fn parse_content() &tree_sitter.Tree<v.NodeType> {
	mut p := ast.new_parser()
	return p.parse_string(source: sample_content)
}

fn test_scan_imports() ? {
	tree := parse_content()
	mut store := &Store{
		reporter: &Collector{}
	}

	mut imp := Importer{
		context: store.with(file_path: file_path, text: sample_content_bytes)
	}

	imports := imp.scan_imports(tree)
	assert imports.len == 2
	assert imports[0].absolute_module_name == 'os'
	assert imports[1].absolute_module_name == 'env'
}

fn test_inject_paths_of_new_imports() ? {
	tree := parse_content()
	mut store := &Store{
		reporter: &Collector{}
	}

	mut imp := Importer {
		context: store.with(file_path: file_path, text: sample_content_bytes)
	}

	mut imports := imp.scan_imports(tree)
	assert imports.len == 2
	assert imports[0].absolute_module_name == 'os'
	assert imports[1].absolute_module_name == 'env'

	imp.inject_paths_of_new_imports(mut imports, os.join_path(vexe_path, 'vlib'))

	assert imports[0].resolved == true
	assert imports[0].path == os.join_path(vexe_path, 'vlib', 'os')
	assert imports[1].resolved == false
}

fn test_import_modules_from_tree() ? {
	tree := parse_content()
	mut store := &Store{
		reporter: &Collector{}
		default_import_paths: test_lookup_paths
	}

	context := store.with(file_path: file_path, text: sample_content_bytes)
	import_modules_from_tree(context, tree)

	assert store.imports[file_dir].len == 2
	assert store.imports[file_dir][0].absolute_module_name == 'os'
	assert store.imports[file_dir][0].resolved == true
	assert store.imports[file_dir][0].imported == true
	assert store.imports[file_dir][1].absolute_module_name == 'env'
	assert store.imports[file_dir][1].resolved == false

	eprintln(store.dependency_tree)
	$if !windows {
		assert store.dependency_tree.size() == 4
	} $else {
		assert store.dependency_tree.size() == 5
	}
}

fn test_import_modules_with_edits() ? {
	mut p := ast.new_parser()
	sample_content2 := '
	import os
	'

	mut tree := p.parse_string(source: sample_content2)
	mut store := &Store{
		reporter: &Collector{}
		default_import_paths: test_lookup_paths
	}

	mut context := store.with(file_path: file_path, text: Runes(sample_content2.runes()))
	import_modules_from_tree(context, tree)
	store.cleanup_imports(file_dir)

	assert store.imports[file_dir].len == 1
	assert store.imports[file_dir][0].absolute_module_name == 'os'
	assert store.imports[file_dir][0].resolved == true
	assert store.imports[file_dir][0].imported == true
	$if !windows {
		assert store.dependency_tree.size() == 4
	} $else {
		assert store.dependency_tree.size() == 5
	}
	assert store.dependency_tree.has(os.join_path(vexe_path, 'vlib', 'os')) == true

	new_content := '
	import osx
	'

	// conform the tree to the new content
	tree.raw_tree.edit(
		start_byte: u32(10)
		old_end_byte: u32(10)
		new_end_byte: u32(11)
		start_point: C.TSPoint{u32(1), u32(8)}
		old_end_point: C.TSPoint{u32(1), u32(8)}
		new_end_point: C.TSPoint{u32(1), u32(9)}
	)

	new_tree := p.parse_string(source: new_content, tree: tree.raw_tree)
	context.text = Runes(new_content.runes())
	import_modules_from_tree(context, new_tree)
	store.cleanup_imports(file_dir)

	assert store.imports[file_dir].len == 0
	assert store.dependency_tree.size() == 1
	assert store.dependency_tree.has(os.join_path(vexe_path, 'vlib', 'os')) == false

	// go back to old
	new_tree.raw_tree.edit(
		start_byte: u32(10)
		old_end_byte: u32(10)
		new_end_byte: u32(10)
		start_point: C.TSPoint{u32(1), u32(8)}
		old_end_point: C.TSPoint{u32(1), u32(9)}
		new_end_point: C.TSPoint{u32(1), u32(8)}
	)

	new_new_tree := p.parse_string(source: sample_content2, tree: new_tree.raw_tree)
	context.text = Runes(sample_content2.runes())

	import_modules_from_tree(context, new_new_tree)
	store.cleanup_imports(file_dir)

	assert store.imports[file_dir].len == 1
	assert store.imports[file_dir][0].absolute_module_name == 'os'
	assert store.imports[file_dir][0].path.len != 0
	assert store.imports[file_dir][0].resolved == true
	assert store.imports[file_dir][0].imported == true
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
