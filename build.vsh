#!/usr/bin/env -S v run

import os

mut vls_exec_name := 'vls'

project_folder := dir(executable())
full_vls_bin_dir := real_path(join_path(project_folder, 'bin'))
full_vls_exec_path := real_path(join_path(full_vls_bin_dir, vls_exec_name))

chdir(project_folder)!

mkdir(full_vls_bin_dir) or {}

// use system default C compiler if found
mut cc := 'cc'

if os.args.len >= 2 {
	if os.args[1] in ['cc', 'gcc', 'clang', 'msvc'] {
		cc = os.args[1]
	} else {
		println('> Usage error: parameter must one of cc, gcc, clang, msvc')
		exit(1)
	}
}

println('> Building VLS...')

vls_git_hash := os.execute('git rev-parse --short HEAD')
if vls_git_hash.exit_code != 0 {
	println('Please install git')
	exit(vls_git_hash.exit_code)
}
os.setenv('VLS_BUILD_COMMIT', vls_git_hash.output.trim_space(), true)

mut buffer := ['v']
buffer << '-g'
buffer << ['-o', full_vls_exec_path]
buffer << ['-gc', 'boehm']
buffer << ['-cc', cc]
if cc != 'msvc' {
	buffer << ['-d', 'use_libbacktrace']
}

index_extra := os.args.index('--')
if index_extra > 0 {
	buffer << os.args[index_extra + 1..]
}

buffer << 'cmd/vls'

cmd := buffer.join(' ')
println(cmd)
ret := system(cmd)
if ret != 0 {
	println('Failed building VLS')
	exit(ret)
}

println('> VLS built successfully!')
println('Executable saved in: ${full_vls_exec_path}')
