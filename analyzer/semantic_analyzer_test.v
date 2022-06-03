import os
import tree_sitter
import tree_sitter_v as v
import test_utils
import benchmark
import analyzer { Collector, SemanticAnalyzer, Store, SymbolAnalyzer, new_tree_cursor, register_builtin_symbols }
import analyzer.an_test_utils

fn test_semantic_analysis() ? {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)

	vlib_path := os.join_path(os.dir(os.getenv('VEXE')), 'vlib')

	mut bench := benchmark.new_benchmark()
	mut reporter := &Collector{}
	mut store := &Store{
		reporter: reporter
		default_import_paths: [vlib_path]
	}
	mut builtin_import, _ := store.add_import(
		resolved: true
		module_name: 'builtin'
		path: os.join_path(vlib_path, 'builtin')
	)
	mut imports := [builtin_import]
	store.register_auto_import(builtin_import, '')
	register_builtin_symbols(mut store, builtin_import)
	store.import_modules(mut imports)

	mut sym_analyzer := SymbolAnalyzer{
		store: store
		is_test: true
	}

	mut semantic_analyzer := SemanticAnalyzer{
		store: store
	}

	test_files_dir := test_utils.get_test_files_path(@FILE)
	test_files := test_utils.load_test_file_paths(test_files_dir, 'semantic_analyzer') or {
		bench.fail()
		eprintln(bench.step_message_fail(err.msg()))
		return err
	}

	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		store.set_active_file_path(test_file_path, 1)

		bench.step()
		test_name := os.base(test_file_path)
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			continue
		}

		src, expected := test_utils.parse_test_file_content(content)
		err_msg := if src.len == 0 || content.len == 0 {
			'file $test_name has empty content'
		} else {
			''
		}

		if err_msg.len != 0 || src.len == 0 {
			bench.fail()
			eprintln(bench.step_message_fail(err_msg))
			continue
		}

		println(bench.step_message('Testing $test_name'))
		tree := parser.parse_string(src)

		src_runes := src.runes()
		cursor := new_tree_cursor(tree.root_node())
		store.import_modules_from_tree(tree, src_runes, vlib_path)

		sym_analyzer.src_text = src_runes
		sym_analyzer.cursor = cursor

		semantic_analyzer.src_text = src_runes
		semantic_analyzer.cursor = cursor

		symbols := sym_analyzer.analyze()
		semantic_analyzer.analyze()
		result := an_test_utils.sexpr_str_reporter(reporter)

		assert result == test_utils.newlines_to_spaces(expected)
		println(bench.step_message_ok(test_name))

		unsafe {
			sym_analyzer.src_text.free()
		}

		store.delete(store.cur_dir)
	}
	assert bench.nfail == 0
	bench.stop()
}
