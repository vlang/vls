import server
import os
import test_utils
import net
import time

fn launch_cmd(exec_path string, args ...string) &os.Process {
	eprintln('executing $exec_path ${args.join(' ')}')

	mut p := os.new_process(exec_path)
	p.set_args(args)
	p.set_redirect_stdio()
	return p
}

fn launch_v_tool(vroot_path string, args ...string) &os.Process {
	return launch_cmd(os.join_path(vroot_path, 'v'), ...args)
}

fn get_vls_path(dir string) string {
	mut vls_path := os.join_path(dir, 'vls')
	$if windows {
		vls_path += '.exe'
	}
	return vls_path
}

fn wrap_request(payload string) string {
	return 'Content-Length: $payload.len\r\n\r\n$payload'
}

const vls_cmd_dir = os.join_path(@VMODROOT, 'cmd', 'vls')

const connection_dir = os.join_path(os.dir(@FILE), 'test_files', 'connection')

const init_msg = wrap_request('{"jsonrpc":"2.0","method":"window/showMessage","params":{"type":2,"message":"VLS is a work-in-progress, pre-alpha language server. It may not be guaranteed to work reliably due to memory issues and other related factors. We encourage you to submit an issue if you encounter any problems."}}')

const editor_info_msg = wrap_request('{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"VLS Version: 0.0.1, OS: linux 64"}}')

fn compile_and_start_vls(args ...string) ?&os.Process {
	mut final_args := ['--child']
	final_args << args

	vls_path := get_vls_path(vls_cmd_dir)
	if !os.exists(vls_path) {
		os.chdir(vls_cmd_dir) ?
		vroot_path := server.detect_vroot_path() ?
		mut v_build_process := launch_v_tool(vroot_path, '-d', 'connection_test', '-cc',
			'gcc', '-gc', 'boehm', '.')
		v_build_process.wait()

		if v_build_process.code > 0 {
			eprintln('[stderr] v_build_process: ' + v_build_process.stderr_slurp().trim_space())
		} else {
			eprintln('[stdout] v_build_process: ' + v_build_process.stdout_slurp().trim_space())
		}

		v_build_process.close()
		assert v_build_process.code == 0
		unsafe { v_build_process.free() }
	}

	assert os.exists(vls_path)
	return launch_cmd(vls_path, ...final_args)
}

fn test_stdio_connect() ? {
	mut io := test_utils.Testio{}
	mut p := compile_and_start_vls() ?
	defer {
		p.close()
		unsafe { p.free() }
	}

	p.run()
	assert p.status == .running
	assert p.pid > 0
	assert p.stdout_read() == init_msg
	p.stdin_write(wrap_request(io.request('exit')))
	p.wait()
	assert p.code > 0
}

fn test_tcp_connect() ? {
	// TODO: fix this later. Hangs on windows ci
	$if windows {
		return
	}
	mut io := test_utils.Testio{}
	mut p := compile_and_start_vls('--socket', '--port=5007') ?
	defer {
		p.close()
		unsafe { p.free() }
	}

	p.run()
	assert p.status == .running
	assert p.pid > 0
	assert p.is_alive() == true
	assert p.stdout_read().trim_space() == '[vls] : Established connection at 127.0.0.1:5007'
	mut conn := net.dial_tcp('127.0.0.1:5007') ?
	// TODO: add init message assertion
	conn.write_string(wrap_request(io.request('exit'))) ?
	conn.close() or {}
	p.wait()
	assert p.code > 0
}

fn test_stdio_timeout() ? {
	mut io := test_utils.Testio{}
	mut p := compile_and_start_vls('--timeout=1') ?
	p.run()
	assert p.status == .running
	assert p.pid > 0
	for {
		if !p.is_alive() {
			break
		}
		time.sleep(1 * time.second)
	}
	p.wait()
	assert p.status == .exited
	assert p.code == 0
	p.close()
	unsafe { p.free() }
}
