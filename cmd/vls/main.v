module main

import cli
import server
import os

fn C._setmode(int, int)

fn run_cli(cmd cli.Command) ? {
	// Fetch the command-line options.
	enable_flag_raw := cmd.flags.get_string('enable') or { '' }
	disable_flag_raw := cmd.flags.get_string('disable') or { '' }
	enable_features := if enable_flag_raw.len > 0 { enable_flag_raw.split(',') } else { []string{} }
	disable_features := if disable_flag_raw.len > 0 {
		disable_flag_raw.split(',')
	} else {
		[]string{}
	}
	debug_mode := cmd.flags.get_bool('debug') or { false }

	custom_vroot_path := cmd.flags.get_string('vroot') or { '' }
	socket_mode := cmd.flags.get_bool('socket') or { false }
	socket_port := cmd.flags.get_string('port') or { '5007' }

	// Setup the comm method and build the language server.
	mut io := if socket_mode {
		server.ReceiveSender(Socket{ port: socket_port, debug: debug_mode })
  } else {
		server.ReceiveSender(Stdio{ debug: debug_mode })
	}

	mut ls := server.new(io)
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
	ls.start_loop()
}

fn main() {
	$if windows {
		// 0x8000 = _O_BINARY from <fcntl.h>
		// windows replaces \n => \r\n, so \r\n will be replaced to \r\r\n
		// binary mode prevents this
		C._setmode(C._fileno(C.stdout), 0x8000)
	}
	mut cmd := cli.Command{
		name: 'vls'
		version: server.meta.version
		description: server.meta.description
		execute: run_cli
		posix_mode: true
	}

	cmd.add_flags([
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
			name: 'debug'
			description: "Toggles language server's debug mode."
		},
		cli.Flag{
			flag: .bool
			name: 'socket'
			description: 'Listens and communicates to the server through a TCP socket.'
		},
		cli.Flag{
			flag: .string
			name: 'port'
			description: 'Port to use for socket communication. (Default: 5007)'
		},
		cli.Flag{
			flag: .string
			name: 'vroot'
			required: false
			description: 'Path to the V installation directory. By default, it will use the VROOT env variable or the current directory of the V executable.'
		},
	])

	cmd.parse(os.args)
}
