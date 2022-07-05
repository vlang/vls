module main

import cli
import server
import os
import io
import jsonrpc
import net
import lsp.log { LogRecorder }

fn run_cli(cmd cli.Command) ? {
	run_as_child := cmd.flags.get_bool('child') or { false }
	validate_options(cmd) ?
	if run_as_child {
		run_server(cmd, run_as_child) ?
	} else {
		run_host(cmd) ?
	}
}

fn run_host(cmd cli.Command) ? {
	// TODO: make vlshost a jsonrpc handler
	should_generate_report := cmd.flags.get_bool('generate-report') or { false }
	flag_discriminator := if cmd.posix_mode { '--' } else { '-' }
	mut server_args := [flag_discriminator + 'child', flag_discriminator + 'socket']
	mut client_port := 5007

	for flag in cmd.flags {
		match flag.name {
			'enable', 'disable', 'vroot' {
				flag_value := cmd.flags.get_string(flag.name) or { continue }
				if flag_value.len == 0 {
					continue
				}
				server_args << flag_discriminator + flag.name
				server_args << flag_value
			}
			'debug' {
				flag_value := cmd.flags.get_bool(flag.name) or { continue }
				if !flag_value {
					continue
				}
				server_args << flag_discriminator + flag.name
			}
			'timeout' {
				flag_value := cmd.flags.get_int(flag.name) or { continue }
				if flag_value == 0 {
					continue
				}
				server_args << flag_discriminator + flag.name
				server_args << flag_value.str()
			}
			'port' {
				client_port = cmd.flags.get_int(flag.name) or { client_port }
				client_port++

				server_args << flag_discriminator + flag.name
				server_args << client_port.str()
			}
			else {}
		}
	}

	// Setup the comm method and build the language server.
	mut io := setup_and_configure_io(cmd, false) ?
	mut jrpc_server := &jsonrpc.Server{
		stream: io
		handler: &jsonrpc.PassiveHandler{}
	}

	mut host := VlsHost{
		server: jrpc_server
		writer: jrpc_server.writer(own_buffer: true)
		child: new_vls_process(...server_args)
		client: &net.TcpConn(0)
		client_port: client_port
		generate_report: should_generate_report
	}

	host.listen()
}

fn setup_and_configure_io(cmd cli.Command, is_child bool) ?io.ReaderWriter {
	socket_mode := cmd.flags.get_bool('socket') or { false }
	if socket_mode {
		socket_port := cmd.flags.get_int('port') or { 5007 }
		return new_socket_stream_server(socket_port, !is_child)
	} else {
		return new_stdio_stream()
	}
}

fn setup_logger(cmd cli.Command) jsonrpc.Interceptor {
	debug_mode := cmd.flags.get_bool('debug') or { false }
	return &LogRecorder{
		enabled: !debug_mode
	}
}

fn validate_options(cmd cli.Command) ? {
	if timeout_minutes_val := cmd.flags.get_int('timeout') {
		if timeout_minutes_val < 0 {
			return error('timeout: should be not less than zero')
		}
	}

	if custom_vroot_path := cmd.flags.get_string('vroot') {
		if custom_vroot_path.len != 0 {
			if !os.exists(custom_vroot_path) {
				return error('Provided VROOT does not exist.')
			}
			if !os.is_dir(custom_vroot_path) {
				return error('Provided VROOT is not a directory.')
			}
		}
	}
}

fn run_server(cmd cli.Command, is_child bool) ? {
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
	mut io := setup_and_configure_io(cmd, is_child) ?
	mut ls := server.new()
	mut jrpc_server := &jsonrpc.Server{
		stream: io
		interceptors: [
			setup_logger(cmd)
		]
		handler: ls
	}

	if custom_vroot_path.len != 0 {
		ls.set_vroot_path(custom_vroot_path)
	}
	if timeout_minutes_val := cmd.flags.get_int('timeout') {
		ls.set_timeout_val(timeout_minutes_val)
	}
	ls.set_features(enable_features, true) ?
	ls.set_features(disable_features, false) ?

	mut rw := unsafe { &server.ResponseWriter(jrpc_server.writer(own_buffer: true)) }

	// Show message that VLS is not yet ready!
	rw.show_message('VLS is a work-in-progress, pre-alpha language server. It may not be guaranteed to work reliably due to memory issues and other related factors. We encourage you to submit an issue if you encounter any problems.',
		.warning)

	go server.monitor_changes(mut ls, mut rw)

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
