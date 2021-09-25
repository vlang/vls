module main

import os
import server
import lsp
import jsonrpc
import time
import strings

struct VlsHost {
mut:
	io server.ReceiveSender
	child &os.Process
	last_logger_len int
	logger strings.Builder = strings.new_builder(10)
}

fn (mut host VlsHost) run() {
	defer { host.child.close() }
	host.io.init() or { panic(err) }
	host.child.run()

	go host.listen_for_errors()
	go host.listen_for_output()

	for {
		if !host.child.is_alive() {
			break
		}

		content := host.io.receive() or { continue }
		host.child.stdin_write(make_lsp_payload(content))
	}

	host.handle_exit()
}

fn (mut host VlsHost) listen_for_errors() {
	for {
		if !host.child.is_alive() {
			break
		}

		err := host.child.stderr_read()
		if err.len == 0 {
			continue
		}

		host.logger.writeln('\n' + err)
		// + 1 includes the newline
		host.last_logger_len = err.len + 1
	}
}

fn (mut host VlsHost) listen_for_output() {
	for {
		if !host.child.is_alive() {
			break
		}

		mut out := host.child.stdout_read()
		if out.len == 0 {
			continue
		} else if out.len == 4096 {
			// 4096 is the maximum length for stdout_read
			out += host.child.stdout_read()
		}

		host.io.send(out)
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
				@type: .info
				message: 'VLS has encountered an error. The error report is saved in ${report_path}'
			}
		}

		host.io.send(prompt.json())
	} else {
		host.child.close()
	}

	ecode := if host.child.code > 0 { 1 } else { 0 }
	exit(ecode)
}

fn (mut host VlsHost) generate_report() ?string {
	report_file_name := 'vls_report_' + time.utc().unix.str() + '.md'
	report_file_path := os.join_path(os.temp_dir(), report_file_name)
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

	report_file.writeln('## System Information') ?
	report_file.writeln('### V doctor\n```\n${vdoctor_info}\n```\n') ?
	report_file.writeln('### VLS info \n```\n${vls_info}\n```\n') ?
	
	// Problem Description
	report_file.writeln('## Problem Description') ?
	report_file.writeln('<!-- Add your description. What did you do? What file did you open? -->') ?
	report_file.writeln('<!-- Images, videos, of the demo can be put here -->') ?
	
	// Expected Output
	report_file.writeln('## Expected Output') ?
	report_file.writeln('<!-- What is the expected output/behavior when executing an action? -->') ?
	
	// Actual Output
	report_file.writeln('## Actual Output\n```\n${host.stderr_logger.get_last_text()}\n```\n') ?
	report_file.writeln('## Steps to Reproduce') ?
	report_file.writeln('<!-- List the steps in order to reproduce the problem -->') ?

	return report_file_path
}