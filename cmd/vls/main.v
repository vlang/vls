module main

import cli
import vls
import v.vmod
import os

const (
	meta = vmod.decode(@VMOD_FILE)?
)

fn run_cli(cmd cli.Command) ? {
	mut ls := vls.new(Stdio{})
	enable_flag_raw := cmd.flags.get_string('enable') or { '' }
	disable_flag_raw := cmd.flags.get_string('disable') or { '' }
	enable_features := if enable_flag_raw.len > 0 { enable_flag_raw.split(',') } else { []string{} }
	disable_features := if disable_flag_raw.len > 0 { disable_flag_raw.split(',') } else { []string{} }
	ls.set_features(enable_features, true) or {
		eprintln('error: $err')
		exit(1)
	}
	ls.set_features(disable_features, false) or {
		eprintln('error: $err')
		exit(1)
	}
	ls.start_loop()
}

fn main() {
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
		}
	])

	cmd.parse(os.args)
}
