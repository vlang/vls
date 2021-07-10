module main

import cli
import vls
import v.vmod
import os

fn C._setmode(int, int)

const (
	meta = meta_info()
)

fn meta_info() vmod.Manifest {
	x := vmod.decode(@VMOD_FILE) or { panic(err) }
	return x
}

fn run_cli(cmd cli.Command) ? {
	// Fetch the command-line options.
	enable_flag_raw := cmd.flags.get_string('enable') or { '' }
	disable_flag_raw := cmd.flags.get_string('disable') or { '' }
	enable_features := if enable_flag_raw.len > 0 { enable_flag_raw.split(',') } else { []string{} }
	disable_features := if disable_flag_raw.len > 0 { disable_flag_raw.split(',') } else { []string{} }
	debug_mode := cmd.flags.get_bool('debug') or { false }
	socket_mode := cmd.flags.get_bool('socket') or { false }
	socket_port := cmd.flags.get_string('port') or { '5007' }

	// Build the language server.
	mut ls := if socket_mode {
		vls.new(&Socket{ conn: 0, port: socket_port, debug: debug_mode })
	} else {
		vls.new(&Stdio{ debug: debug_mode })
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
		version: meta.version
		description: meta.description
		execute: run_cli
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
			description: "Use sockets and TCP for interacting with the server"
		}
		cli.Flag{
			flag: .string
			name: 'port'
			description: "Port to use for socket communication, by default 5007"
		}
	])

	cmd.parse(os.args)
}
