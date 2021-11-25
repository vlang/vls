module main

import os
import server

const content_length = 'Content-Length: '

fn make_lsp_payload(output string) string {
	return 'Content-Length: $output.len\r\n\r\n$output'
}

fn launch_v_tool(args ...string) ?&os.Process {
	// using @VEXEROOT should never happen but will be used
	// just in case
	vroot_path := server.detect_vroot_path() or { @VEXEROOT }
	full_v_path := os.join_path(vroot_path, 'v')
	mut p := os.new_process(full_v_path)
	p.set_args(args)
	p.set_redirect_stdio()
	return p
}

fn new_vls_process(args ...string) &os.Process {
	mut p := os.new_process(os.executable())
	p.set_args(args)
	p.set_redirect_stdio()
	return p
}
