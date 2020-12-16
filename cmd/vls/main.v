module main

import cli
import vls
import os

const (
	// flag name - description
	feature_flag_data = {
		'diagnostics': 'the diagnostics feature'
		'completion': 'the autocompletion feature'
		'document-symbols': 'the document symbols feature'
		'workspace-symbols': 'the workspace symbols feature'
	}
)

fn run_cli(cmd cli.Command) ? {
	mut ls := vls.new(Stdio{})
	ls.start_loop()
}

fn main() {
	mut cmd := cli.Command{
		name: 'vls'
		version: '0.0.1'
		description: 'vls is a language server for the V language.'
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
