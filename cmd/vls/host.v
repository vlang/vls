module main

import os
import server
import lsp
import jsonrpc
import time
import strings

const max_stdio_logging_count = 15

struct Logger {
mut:
	max_log_count int = max_stdio_logging_count
	with_timestamp bool = true
	reset_builder_on_max_count bool
	log_count int
	builder strings.Builder = strings.new_builder(10)
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
			'[${time.utc()}] ${content[carr_idx..].trim_space()}\n' 
		} else {
			content[carr_idx..].trim_space()
		}
		lg.builder.writeln(final_con)
		return final_con.len
	} else {
		final_con := if lg.with_timestamp {
			'[${time.utc()}] ${content.trim_space()}'
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
	io server.ReceiveSender
	child &os.Process
	stderr_logger Logger = Logger{max_log_count: 0, with_timestamp: false}
	stdin_logger Logger = Logger{reset_builder_on_max_count: true}
	stdout_logger Logger = Logger{reset_builder_on_max_count: true}
}

fn (mut host VlsHost) has_child_exited() bool {
	return !host.child.is_alive() || host.child.status in [.exited, .aborted, .closed]
}

fn (mut host VlsHost) run() {
	host.io.init() or { panic(err) }
	host.child.run()

	go host.listen_for_errors()
	go host.listen_for_output()
	go host.listen_for_input()
	
	host.child.wait()
	host.child.close()
	host.handle_exit()
}

fn (mut host VlsHost) listen_for_input() {
	for {
		if host.has_child_exited() {
			break
		}

		// STDIN
		content := host.io.receive() or {
			continue
		}

		final_payload := make_lsp_payload(content)
		host.child.stdin_write(final_payload)
		host.stdin_logger.writeln(final_payload)
	}
}

fn (mut host VlsHost) listen_for_errors() {
	for {
		if host.has_child_exited() {
			break
		}

		err := host.child.stderr_read()
		if err.len == 0 {
			continue
		}

		// Set the last_len to the length of the latest entry so that
		// the last stderr output will be logged into the error report.
		host.stderr_logger.writeln(err)
	}
}

fn (mut host VlsHost) listen_for_output() {
	for {
		if host.has_child_exited() {
			break
		}

		mut out := host.child.stdout_read()
		if out.len == 0 {
			continue
		} 
		
		// 4096 is the maximum length for stdout_read
		for last_out_len := out.len; last_out_len == 4096; {
			got := host.child.stdout_read()
			out += got
			last_out_len = got.len 
		}

		host.io.send(out)
		host.stdout_logger.writeln(out)
	}
}

fn (mut host VlsHost) handle_exit() {
	if host.child.code > 0 {
		report_path := host.generate_report() or {
			// should not happen
			panic(err)
		}

		prompt := jsonrpc.NotificationMessage<lsp.ShowMessageParams>{
			method: 'window/showMessage'
			params: lsp.ShowMessageParams{
				@type: .error
				message: 'VLS has encountered an error. The error report is saved in ${report_path}'
			}
		}

		host.io.send(prompt.json())
	}

	ecode := if host.child.code > 0 { 1 } else { 0 }
	exit(ecode)
}

fn (mut host VlsHost) generate_report() ?string {
	report_file_name := 'vls_report_' + time.utc().unix.str() + '.md'
	report_file_path := os.join_path(os.home_dir(), report_file_name)
	mut report_file := os.create(report_file_path) ?
	defer { report_file.close() }

	// Get system info first
	mut vdoctor := launch_v_tool('doctor') ?
	defer { vdoctor.close() }
	vdoctor.run()
	vdoctor.wait()
	vdoctor_info := vdoctor.stdout_slurp().trim_space()

	mut vls_info_proc := new_vls_process('--version')
	defer { vls_info_proc.close() }
	vls_info_proc.run()
	vls_info_proc.wait()
	vls_info := vls_info_proc.stdout_slurp().trim_space()

	report_file.writeln('<!-- Copy and paste the contents of this file to https://github.com/vlang/vls/issues/new -->') ?
	report_file.writeln('## System Information') ?
	report_file.writeln('### V doctor\n```\n${vdoctor_info}\n```\n') ?
	report_file.writeln('### VLS info \n```\n${vls_info}\n```\n') ?
	
	// Problem Description
	report_file.writeln('## Problem Description') ?
	report_file.writeln('<!-- Add your description. What did you do? What file did you open? -->') ?
	report_file.writeln('<!-- Images, videos, of the demo can be put here -->\n') ?
	
	// Expected Output
	report_file.writeln('## Expected Output') ?
	report_file.writeln('<!-- What is the expected output/behavior when executing an action? -->\n') ?

	// Actual Output
	report_file.writeln('## Actual Output\n```\n${host.stderr_logger.get_text()}\n```\n') ?
	report_file.writeln('## Steps to Reproduce') ?
	report_file.writeln('<!-- List the steps in order to reproduce the problem -->\n') ?

	// Last LSP Requests
	report_file.writeln('## Last Recorded LSP Requests') ?
	report_file.writeln('### Request\n```\n${host.stdin_logger.get_text()}\n```\n') ?
	report_file.writeln('### Response\n```\n${host.stdout_logger.get_text()}\n```\n') ?
	return report_file_path
}