import os
import server
import test_utils
import benchmark
import lsp

// import tree_sitter

const compute_offset_inputs = {
	'crlf.vv': [3, 22]
	'lf.vv':   [2, 14]
}

const compute_offset_results = {
	'crlf.vv': 55
	'lf.vv':   41
}

fn test_compute_offset() {
	mut bench := benchmark.new_benchmark()
	test_files := test_utils.load_test_file_paths(test_utils.get_test_files_path(@FILE),
		'pos_compute_offset') or {
		bench.fail()
		eprintln(bench.step_message_fail(err.msg()))
		assert false
		return
	}

	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in compute_offset_results {
			'missing results for $test_name'
		} else if test_name !in compute_offset_inputs {
			'missing input data for $test_name'
		} else {
			''
		}
		if err_msg.len != 0 {
			bench.fail()
			eprintln(bench.step_message_fail(err_msg))
			continue
		}
		println(bench.step_message('Testing $test_name'))
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		input := compute_offset_inputs[test_name]
		expected := compute_offset_results[test_name]
		result := server.compute_offset(content.runes(), input[0], input[1])
		if result != expected {
			println('content (for debugging):' + content[..result].str())
		}
		assert result == expected
		bench.ok()
		println(bench.step_message_ok(test_name))
	}
	assert bench.nfail == 0
	bench.stop()
}

const compute_position_inputs = {
	'crlf.vv': 55
	'lf.vv':   41
}

const compute_position_results = {
	'crlf.vv': lsp.Position{3, 22}
	'lf.vv':   lsp.Position{2, 14}
}

fn test_compute_position() {
	mut bench := benchmark.new_benchmark()
	// TODO:
	test_files := test_utils.load_test_file_paths(test_utils.get_test_files_path(@FILE),
		'pos_compute_offset') or {
		bench.fail()
		eprintln(bench.step_message_fail(err.msg()))
		assert false
		return
	}

	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in compute_offset_results {
			'missing results for $test_name'
		} else if test_name !in compute_offset_inputs {
			'missing input data for $test_name'
		} else {
			''
		}
		if err_msg.len != 0 {
			bench.fail()
			eprintln(bench.step_message_fail(err_msg))
			continue
		}
		println(bench.step_message('Testing $test_name'))
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		input := compute_position_inputs[test_name]
		expected := compute_position_results[test_name]
		result := server.compute_position(content.runes(), input)
		assert result == expected
		bench.ok()
		println(bench.step_message_ok(test_name))
	}
	assert bench.nfail == 0
	bench.stop()
}

const tspoint_to_lsp_pos_inputs = {
	'simple.vv': C.TSPoint{
		row: 2
		column: 0
	}
}

const tspoint_to_lsp_pos_results = {
	'simple.vv': lsp.Position{
		line: 2
		character: 0
	}
}

fn test_tspoint_to_lsp_pos() {
	mut bench := benchmark.new_benchmark()
	test_files := test_utils.load_test_file_paths(test_utils.get_test_files_path(@FILE),
		'pos_to_lsp_pos') or {
		bench.fail()
		eprintln(bench.step_message_fail(err.msg()))
		assert false
		return
	}

	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in tspoint_to_lsp_pos_inputs {
			'missing results for $test_name'
		} else if test_name !in tspoint_to_lsp_pos_results {
			'missing input data for $test_name'
		} else {
			''
		}
		if err_msg.len != 0 {
			bench.fail()
			eprintln(bench.step_message_fail(err_msg))
			continue
		}
		println(bench.step_message('Testing $test_name'))
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		input := tspoint_to_lsp_pos_inputs[test_name]
		expected := tspoint_to_lsp_pos_results[test_name]
		result := server.tspoint_to_lsp_pos(input)
		assert result == expected
		bench.ok()
		println(bench.step_message_ok(test_name))
	}
	assert bench.nfail == 0
	bench.stop()
}

const tsrange_to_lsp_range_inputs = {
	'simple.vv':         C.TSRange{
		start_point: C.TSPoint{2, 0}
		end_point: C.TSPoint{2, 29}
	}
	'with_last_line.vv': C.TSRange{
		start_point: C.TSPoint{0, 0}
		end_point: C.TSPoint{3, 1}
	}
}

const tsrange_to_lsp_range_results = {
	'simple.vv':         lsp.Range{
		start: lsp.Position{
			line: 2
			character: 0
		}
		end: lsp.Position{
			line: 2
			character: 29
		}
	}
	'with_last_line.vv': lsp.Range{
		start: lsp.Position{
			line: 0
			character: 0
		}
		end: lsp.Position{
			line: 3
			character: 1
		}
	}
}

fn test_tsrange_to_lsp_range() {
	mut bench := benchmark.new_benchmark()
	test_files := test_utils.load_test_file_paths(test_utils.get_test_files_path(@FILE),
		'pos_to_lsp_range') or {
		bench.fail()
		eprintln(bench.step_message_fail(err.msg()))
		assert false
		return
	}

	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in tsrange_to_lsp_range_inputs {
			'missing results for $test_name'
		} else if test_name !in tsrange_to_lsp_range_results {
			'missing input data for $test_name'
		} else {
			''
		}
		if err_msg.len != 0 {
			bench.fail()
			eprintln(bench.step_message_fail(err_msg))
			continue
		}
		println(bench.step_message('Testing $test_name'))
		content := os.read_file(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		input := tspoint_to_lsp_pos_inputs[test_name]
		expected := tspoint_to_lsp_pos_results[test_name]
		result := server.tspoint_to_lsp_pos(input)
		assert result == expected
		bench.ok()
		println(bench.step_message_ok(test_name))
	}
	assert bench.nfail == 0
	bench.stop()
}
