module analyzer

import os
import tree_sitter
import tree_sitter_v as v
import test_utils
import benchmark

fn test_symbol_registration() ? {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)

	mut bench := benchmark.new_benchmark()
	mut store := &Store{}
	mut builtin_import, _ := store.add_import(
		resolved: true
		module_name: 'builtin'
		path: os.join_path(os.dir(os.getenv('VEXE')), 'vlib', 'builtin')
	)
	mut imports := [builtin_import]
	store.register_auto_import(builtin_import, '')
	register_builtin_symbols(mut store, builtin_import)
	store.import_modules(mut imports)

	mut sym_analyzer := SymbolAnalyzer{
		store: store
		is_test: true
	}

	test_files_dir := test_utils.get_test_files_path(@FILE)
	test_files := test_utils.load_test_file_paths(test_files_dir, 'symbol_registration') or {
		bench.fail()
		eprintln(bench.step_message_fail(err.msg))
		assert false
		return
	}

	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
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
		sym_analyzer.src_text = src.bytes()
		sym_analyzer.cursor = new_tree_cursor(tree.root_node())

		symbols, _ := sym_analyzer.analyze()
		result := symbols.sexpr_str()
		assert result == expected
		println(bench.step_message_ok(test_name))

		unsafe {
			sym_analyzer.src_text.free()
		}
	}
	assert bench.nfail == 0
	bench.stop()
}
