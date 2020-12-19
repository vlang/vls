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
	ls.start_loop()
}

fn main() {
	mut cmd := cli.Command{
		name: 'vls'
		version: meta.version
		description: meta.description
		execute: run_cli
	}

	for name, desc in feature_flag_data {
		cmd.add_flags([
			cli.Flag{
				flag: .bool
				name: 'enable-$name'
				description: 'Enables $desc'
				value: 'true'
			},
			cli.Flag{
				flag: .bool
				name: 'disable-$name'
				description: 'Disables $desc'
				value: 'false'
			}
		])
	}

	cmd.parse(os.args)
}
