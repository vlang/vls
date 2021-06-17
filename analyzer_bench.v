import tree_sitter
import analyzer
import tree_sitter_v.bindings.v

import os

fn filter_v_files(mut files []string) {
	files.sort()

	for i := 0; i < files.len; {
		file := files[i]
		ends_with_v := file.ends_with('.v')
		is_test_file := file.ends_with('_test.v')

		if !ends_with_v || is_test_file || file.starts_with('.#') {
			unsafe { files[i].free() }
			files.delete(i)
			continue
		}

		i++
	}
}

fn import_builtin(mut store analyzer.Store) {
	vexe_path := os.getenv('VEXE')
	builtin_path := os.join_path(os.dir(vexe_path), 'vlib', 'builtin')
	mut files := os.ls(builtin_path) or { []string{} }
	filter_v_files(mut files)
	
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)

	mut an := analyzer.Analyzer{ is_import: true }
	for file_name in files {
		path := os.join_path(builtin_path, file_name)
		store.set_active_file_path(path)

		src_text := os.read_bytes(path) or { []byte{} }
		tree := parser.parse_string(src_text.bytestr())
		root_node := tree.root_node()
		an.analyze(root_node, src_text, mut store)
		unsafe { tree.free() }
	}
}

fn main() {
// 	mut parser := tree_sitter.new_parser()
// 	parser.set_language(v.language)
	
// 	src := '
// module main

// struct Hello {}
// '
// 	tree := parser.parse_string(src)
	mut store := analyzer.Store{}
// 	store.set_active_file_path('foo/bar')
// 	// println(tree.root_node().sexpr_str())
// 	// analyzer.analyze(tree, src.bytes(), mut store)
// 	println(store.imports)

	import_builtin(mut store)
	for dir, syms in store.symbols {
		println('=== $dir ===')
		for _, sym in syms {
			if isnil(sym) {
				continue
			}
		}
	}
}