module main

import cli
import server
import os
import io
import jsonrpc

fn run_cli(cmd cli.Command) ? {
	// mut run_as_child := cmd.flags.get_bool('child') or { false }
	mut run_as_child := true
	$if windows {
		run_as_child = true
	}
	if run_as_child {
		run_server(cmd) ?
	} else {
		// TODO: make vlshost a jsonrpc handler
		// should_generate_report := cmd.flags.get_bool('generate-report') or { false }
		// flag_discriminator := if cmd.posix_mode { '--' } else { '-' }
		// mut server_args := [flag_discriminator + 'child']
		// for flag in cmd.flags {
		// 	match flag.name {
		// 		'enable', 'disable', 'vroot' {
		// 			flag_value := cmd.flags.get_string(flag.name) or { continue }
		// 			if flag_value.len == 0 {
		// 				continue
		// 			}
		// 			server_args << flag_discriminator + flag.name
		// 			server_args << flag_value
		// 		}
		// 		'debug' {
		// 			flag_value := cmd.flags.get_bool(flag.name) or { continue }
		// 			if !flag_value {
		// 				continue
		// 			}
		// 			server_args << flag_discriminator + flag.name
		// 		}
		// 		'timeout' {
		// 			flag_value := cmd.flags.get_int(flag.name) or { continue }
		// 			if flag_value == 0 {
		// 				continue
		// 			}
		// 			server_args << flag_discriminator + flag.name
		// 			server_args << flag_value.str()
		// 		}
		// 		else {}
		// 	}
		// }

		// io := setup_and_configure_io(cmd) ?

		// mut host := VlsHost{
		// 	io: io
		// 	child: new_vls_process(...server_args)
		// 	generate_report: should_generate_report
		// }

		// host.run()
	}
}

fn setup_and_configure_io(cmd cli.Command) ?io.ReaderWriter {
	socket_mode := cmd.flags.get_bool('socket') or { false }
	// debug_mode := cmd.flags.get_bool('debug') or { false }
	if socket_mode {
		socket_port := cmd.flags.get_int('port') or { 5007 }
		return new_socket_stream(socket_port)
	} else {
		return new_stdio_stream()
	}
}

fn run_server(cmd cli.Command) ? {
	// Fetch the command-line options.
	enable_flag_raw := cmd.flags.get_string('enable') or { '' }
	disable_flag_raw := cmd.flags.get_string('disable') or { '' }
	enable_features := if enable_flag_raw.len > 0 { enable_flag_raw.split(',') } else { []string{} }
	disable_features := if disable_flag_raw.len > 0 {
		disable_flag_raw.split(',')
	} else {
		[]string{}
	}

	custom_vroot_path := cmd.flags.get_string('vroot') or { '' }

	// Setup the comm method and build the language server.
	mut io := setup_and_configure_io(cmd) ?
	mut ls := server.new()
	mut jrpc_server := jsonrpc.Server{
		stream: io
		handler: ls
	}

	if timeout_minutes_val := cmd.flags.get_int('timeout') {
		if timeout_minutes_val < 0 {
			return error('timeout: should be not less than zero')
		}

		ls.set_timeout_val(timeout_minutes_val)
	}

	if custom_vroot_path.len != 0 {
		if !os.exists(custom_vroot_path) {
			return error('Provided VROOT does not exist.')
		}
		if !os.is_dir(custom_vroot_path) {
			return error('Provided VROOT is not a directory.')
		} else {
			ls.set_vroot_path(custom_vroot_path)
		}
	}

	ls.set_features(enable_features, true) ?
	ls.set_features(disable_features, false) ?

	mut rw := server.ResponseWriter(jrpc_server.writer())

	// Show message that VLS is not yet ready!
	rw.show_message('VLS is a work-in-progress, pre-alpha language server. It may not be guaranteed to work reliably due to memory issues and other related factors. We encourage you to submit an issue if you encounter any problems.',
		.warning)

	go server.monitor_changes(mut ls, mut &rw)

	jrpc_server.start()
}

fn main() {
	mut cmd := cli.Command{
		name: 'vls'
		version: server.meta.version
		description: server.meta.description
		execute: run_cli
		posix_mode: true
	}

	cmd.add_flags([
		cli.Flag{
			flag: .bool
			name: 'child'
			description: "Runs VLS in child process mode. Beware: using --child directly won't trigger features such as error reporting. Use it on your risk."
		},
		cli.Flag{
			flag: .string
			name: 'enable'
			abbrev: 'e'
			description: 'Enables specific language features.'
		},
		cli.Flag{
			flag: .string
			name: 'disable'
			abbrev: 'd'
			description: 'Disables specific language features.'
		},
		cli.Flag{
			flag: .bool
			name: 'generate-report'
			description: "Generates an error report regardless of the language server's output."
		},
		cli.Flag{
			flag: .bool
			name: 'debug'
			description: "Toggles language server's debug mode."
		},
		cli.Flag{
			flag: .bool
			name: 'socket'
			description: 'Listens and communicates to the server through a TCP socket.'
		},
		cli.Flag{
			flag: .int
			default_value: ['5007'],
			name: 'port'
			description: 'Port to use for socket communication. (Default: 5007)'
		},
		cli.Flag{
			flag: .string
			name: 'vroot'
			required: false
			description: 'Path to the V installation directory. By default, it will use the VROOT env variable or the current directory of the V executable.'
		},
		cli.Flag{
			flag: .int
			name: 'timeout'
			default_value: ['15']
			description: 'Number of minutes to be set for timeout/auto-shutdown. After n number of minutes, VLS will automatically shutdown. Set to 0 to disable it.'
		},
	])

	cmd.parse(os.args)
}
