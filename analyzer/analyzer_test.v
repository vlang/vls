module analyzer

import os
import tree_sitter
import tree_sitter_v as v
import benchmark
import v.util
import v.token
import term

fn parse_content(content string) &C.TSTree {
	mut parser := tree_sitter.new_parser()
	parser.set_language(v.language)
	return parser.parse_string(content)
}

fn clean_line_endings(s string) string {
	mut res := s.trim_space()
	res = res.replace(' \n', '\n')
	res = res.replace(' \r\n', '\n')
	res = res.replace('\r\n', '\n')
	res = res.trim('\n')
	return res
}

fn inject_builtin(mut store Store) {
	builtin_path := os.real_path(os.join_path('.', 'vlib', 'builtin'))
	mut builtin_import, _ := store.add_import(
		resolved: true
		module_name: 'builtin'
		path: builtin_path
	)

	store.register_auto_import(builtin_import, '')
	analyzer.register_builtin_symbols(mut store, builtin_import)

	mut imports := [builtin_import]
	store.import_modules(mut imports)
}

const skipped_tests = [
	'vlib/v/checker/tests/a_test_file_with_0_test_fns_test.vv',
	'vlib/v/checker/tests/ambiguous_field_method_err.vv',
	'vlib/v/checker/tests/any_int_float_ban_err.vv',
	'vlib/v/checker/tests/array_builtin_redefinition.vv',
	'vlib/v/checker/tests/array_cmp_err.vv',
	'vlib/v/checker/tests/array_declare_element_a.vv'
	'vlib/v/checker/tests/array_declare_element_b.vv'
	'vlib/v/checker/tests/array_declare_element_c.vv'
	'vlib/v/checker/tests/array_element_type.vv'
	'vlib/v/checker/tests/array_filter_fn_err.vv'
	'vlib/v/checker/tests/array_index.vv'
]

// test_analyzer_from_v compares the output from V's checker to VLS' analyzer
fn test_analyzer_from_v() ? {
	os.chdir(os.dir(@VEXE)) ?

	input_file_paths := os.glob('vlib/v/checker/tests/*.vv') ?
	out_file_paths := os.glob('vlib/v/checker/tests/*.out') ?

	mut store := Store{
		default_import_paths: [os.join_path(os.getwd(), 'vlib'), os.vmodules_dir()]
	}

	inject_builtin(mut store)

	mut bmark := benchmark.new_benchmark()
	bmark.set_total_expected_steps(input_file_paths.len)

	vv_ext_len := '.vv'.len
	out_ext_len := '.out'.len

	for i in 0 .. input_file_paths.len {
		bmark.step()

		input_file_path := input_file_paths[i]
		out_file_path := out_file_paths[i]
		if input_file_path in skipped_tests {
			bmark.skip()
			println(bmark.step_message_skip(input_file_path))
			continue
		}

		if input_file_path[.. input_file_path.len - vv_ext_len] != out_file_path[.. out_file_path.len - out_ext_len] {
			eprintln(bmark.step_message_fail('file $input_file_path does not have a corresponding output file'))
			bmark.fail()
			break
		}

		modules_dir := os.join_path(os.dir(input_file_path), 'modules')
		input_file_content := os.read_file(input_file_path) ?
		out_file_content := clean_line_endings(os.read_file(out_file_path) ?)

		input_file_bytes := input_file_content.bytes()
		tree := parse_content(input_file_content)

		store.set_active_file_path(input_file_path, 1)
		store.import_modules_from_tree(tree, input_file_bytes, modules_dir)
		store.register_symbols_from_tree(tree, input_file_bytes)
		store.cleanup_imports()
		store.analyze(tree, input_file_bytes)

		formatted_messages := clean_line_endings(store.messages.map(
			term.strip_ansi(util.formatted_error('error:', it.content, it.file_path, token.Position{
				len: int(it.range.end_byte - it.range.start_byte)
				line_nr: int(it.range.start_point.row)
				col: int(it.range.start_point.column)
			}))
		).join('\n'))

		if out_file_content != formatted_messages {
			eprintln(bmark.step_message_fail(input_file_path))
		}

		assert out_file_content == formatted_messages
		bmark.ok()
		println(bmark.step_message_ok(input_file_path))

		store.clear_messages()
		unsafe {
			input_file_content.free()
			tree.free()
			store.opened_scopes[input_file_path].free()
		}
		store.opened_scopes.delete(input_file_path)
		store.delete(os.dir(input_file_path))
	}

	bmark.stop()
	assert bmark.nfail == 0
}