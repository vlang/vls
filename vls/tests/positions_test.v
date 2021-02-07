import os
import vls
import vls.testing
import v.token
import benchmark
import lsp

const compute_offset_inputs = {
	'crlf.crlf.vv': [3, 22]
	'lf.vv':   [2, 14]
}

const compute_offset_results = {
	'crlf.crlf.vv': 55
	'lf.vv':   41
}

fn test_compute_offset() {
	mut bench := benchmark.new_benchmark()
	test_files := testing.load_test_file_paths('pos_compute_offset') or {
		bench.fail()
		eprintln(bench.step_message_fail(err))
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
		content := os.read_bytes(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		input := compute_offset_inputs[test_name]
		expected := compute_offset_results[test_name]
		result := vls.compute_offset(content, input[0], input[1])
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

const position_to_lsp_pos_inputs = {
	'simple.vv': token.Position{
		line_nr: 2
		pos: 13
	}
}

const position_to_lsp_pos_results = {
	'simple.vv': lsp.Position{
		line: 2
		character: 0
	}
}

fn test_position_to_lsp_pos() {
	mut bench := benchmark.new_benchmark()
	test_files := testing.load_test_file_paths('pos_to_lsp_pos') or {
		bench.fail()
		eprintln(bench.step_message_fail(err))
		assert false
		return
	}

	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in position_to_lsp_pos_inputs {
			'missing results for $test_name'
		} else if test_name !in position_to_lsp_pos_results {
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
		content := os.read_bytes(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		input := position_to_lsp_pos_inputs[test_name]
		expected := position_to_lsp_pos_results[test_name]
		result := vls.position_to_lsp_pos(content, input)
		assert result == expected
		bench.ok()
		println(bench.step_message_ok(test_name))
	}
	assert bench.nfail == 0
	bench.stop()
}

const position_to_lsp_range_inputs = {
		'simple.vv':         token.Position{
			line_nr: 2
			pos: 13
			len: 29
		}
		'with_last_line.vv': token.Position{
			line_nr: 0
			pos: 0
			len: 55
			last_line: 4
		}
	}

const position_to_lsp_range_results = {
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

fn test_position_to_lsp_range() {
	mut bench := benchmark.new_benchmark()
	test_files := testing.load_test_file_paths('pos_to_lsp_range') or {
		bench.fail()
		eprintln(bench.step_message_fail(err))
		assert false
		return
	}

	bench.set_total_expected_steps(test_files.len)
	for test_file_path in test_files {
		bench.step()
		test_name := os.base(test_file_path)
		err_msg := if test_name !in position_to_lsp_range_inputs {
			'missing results for $test_name'
		} else if test_name !in position_to_lsp_range_results {
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
		content := os.read_bytes(test_file_path) or {
			bench.fail()
			eprintln(bench.step_message_fail('file $test_file_path is missing'))
			continue
		}
		input := position_to_lsp_pos_inputs[test_name]
		expected := position_to_lsp_pos_results[test_name]
		result := vls.position_to_lsp_pos(content, input)
		assert result == expected
		bench.ok()
		println(bench.step_message_ok(test_name))
	}
	assert bench.nfail == 0
	bench.stop()
}
