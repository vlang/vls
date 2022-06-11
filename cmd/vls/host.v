module main

import os
import server
import jsonrpc
import time
import strings
import io

const max_stdio_logging_count = 15
const start_template_marker = '<!-- If you have a report file, copy and replace the entire contents of the file here. -->\n'
const bug_issue_template = $embed_file('../../.github/ISSUE_TEMPLATE/bug_report.md').to_string().all_after_last(start_template_marker)

struct Logger {
mut:
	max_log_count              int  = max_stdio_logging_count
	with_timestamp             bool = true
	reset_builder_on_max_count bool
	log_count                  int
	builder                    strings.Builder = strings.new_builder(10)
}

fn (mut lg Logger) writeln(content string) int {
	defer {
		if lg.max_log_count > 0 {
			lg.log_count++
		}
	}

	if lg.max_log_count > 0 && lg.log_count == lg.max_log_count {
		lg.log_count = 0

		if lg.reset_builder_on_max_count {
			lg.builder.go_back_to(0)
		}
	}

	if content.starts_with(content_length) {
		mut carr_idx := content.index('\r\n\r\n') or { -1 }
		if carr_idx != -1 {
			carr_idx += 4
		}
		final_con := if lg.with_timestamp {
			'[$time.utc()] ${content[carr_idx..].trim_space()}\n'
		} else {
			content[carr_idx..].trim_space()
		}
		lg.builder.writeln(final_con)
		return final_con.len
	} else {
		final_con := if lg.with_timestamp {
			'[$time.utc()] $content.trim_space()'
		} else {
			content.trim_space()
		}
		lg.builder.writeln(final_con)
		return final_con.len
	}
}

fn (mut lg Logger) get_text() string {
	return lg.builder.str().trim_space()
}

struct VlsHost {
mut:
	server        &jsonrpc.Server
	writer        &server.ResponseWriter
	child         &os.Process
	client        io.ReaderWriter
	client_port   int
	stderr_logger Logger = Logger{
		max_log_count: 0
		with_timestamp: false
	}
	stdin_logger Logger = Logger{
		reset_builder_on_max_count: true
	}
	stdout_logger Logger = Logger{
		reset_builder_on_max_count: true
	}
	generate_report bool
	stdin_chan      chan []u8
	stdout_chan     chan []u8
	stderr_chan     chan string
}

fn (mut host VlsHost) has_child_exited() bool {
	return !host.child.is_alive() || host.child.status in [.exited, .aborted, .closed]
}

fn (mut host VlsHost) listen() {
	host.child.run()
	defer {
		host.child.wait()
		host.child.close()
		host.handle_exit()
	}

	time.sleep(100 * time.millisecond)
	host.client = new_socket_stream_client(host.client_port) or { panic(err) }
	if host.generate_report {
		host.writer.show_message('VLS: --generate-report has been enabled. The report file will be generated upon exit.', .info)
	}

	go host.listen_for_errors()
	go host.listen_for_output()
	go host.listen_for_input()
	host.receive_data()
}

fn (mut host VlsHost) receive_data() {
	// mut stdout_buffer := strings.new_builder(4096)
	for !host.has_child_exited() {
		select {
			incoming_stderr := <-host.stderr_chan {
				// Set the last_len to the length of the latest entry so that
				// the last stderr output will be logged into the error report.
				host.stderr_logger.writeln(incoming_stderr)
			}
		}
	}
}


fn (mut host VlsHost) listen_for_input() {
	mut buf := strings.new_builder(1024 * 1024)
	for !host.has_child_exited() {
		// STDIN
		if _ := host.server.stream.read(mut buf) {
			host.client.write(buf) or {}
			host.server.intercept_raw_request(buf) or {
				host.writer.log_message('[$err.code()] $err.msg()', .error)
				// do nothing
			}
			// TODO: move as interceptor
			host.stdin_logger.writeln(buf.bytestr())
		}
		buf.go_back_to(0)
	}
}

fn (mut host VlsHost) listen_for_errors() {
	for !host.has_child_exited() {
		host.stderr_chan <- host.child.stderr_read()
	}
}

fn (mut host VlsHost) listen_for_output() {
	mut buf := strings.new_builder(1024 * 1024)
	for !host.has_child_exited() {
		if _ := host.client.read(mut buf) {
			host.server.stream.write(buf) or {}
			host.server.intercept_encoded_response(buf)
			host.stdout_logger.writeln(buf.bytestr())
		}
		buf.go_back_to(0)
	}
}

fn (mut host VlsHost) handle_exit() {
	if !host.generate_report && host.child.code > 0 {
		host.generate_report = true
	}

	if host.generate_report {
		report_path := host.generate_report() or {
			// should not happen
			panic(err)
		}

		host.writer.show_message('VLS has encountered an error. The error report is saved in $report_path', .error)
	}

	ecode := if host.child.code > 0 { 1 } else { 0 }
	exit(ecode)
}

fn (mut host VlsHost) generate_report() ?string {
	reports_dir_path := os.join_path(server.get_folder_path(), 'reports')
	if !os.exists(reports_dir_path) {
		os.mkdir(reports_dir_path)?
	}

	report_file_name := 'vls_report_' + time.utc().unix.str() + '.md'
	report_file_path := os.join_path(reports_dir_path, report_file_name)
	mut report_file := os.create(report_file_path) ?
	defer {
		report_file.close()
	}

	// Get system info first
	mut vdoctor := launch_v_tool('doctor') ?
	defer {
		vdoctor.close()
	}
	vdoctor.run()
	vdoctor.wait()
	vdoctor_info := vdoctor.stdout_slurp().trim_space()

	// Actual Output
	actual_out := host.stderr_logger.get_text()
	final_err_out := if actual_out.len != 0 {
		'```\n$actual_out\n```'
	} else {
		'N/A'
	}

	// Last LSP Requests
	mut lsp_logs_section := ''
	lsp_logs_section += '### Request\n```\n$host.stdin_logger.get_text()\n```\n'
	lsp_logs_section += '### Response\n```\n$host.stdout_logger.get_text()\n```\n'

	// Final output
	final_output := bug_issue_template
		.replace("Paste the output of 'v doctor' here", vdoctor_info)
		.replace("Paste the output of 'vls --version' here", 'vls version: $server.meta.version\nvls server arguments: ${host.child.args.join(' ')}')
		.replace('<!-- What is the actual output displayed in the console/editor? -->', final_err_out)
		.replace('<!-- If you have a copy vls.log, you can drag them here. -->', lsp_logs_section)

	report_file.writeln(final_output) ?
	return report_file_path
}
