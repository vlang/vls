#!/usr/local/bin/v run

import os

mut vls_exec_name := 'vls'
$if windows {
	vls_exec_name += '.exe'
}

vls_bin_dir := 'bin'
full_vls_bin_dir := join_path(dir(executable()), vls_bin_dir)

if !exists(full_vls_bin_dir) {
	mkdir(full_vls_bin_dir) ?
}

// use system default C compiler if found
mut cc := 'cc'
if os.args.len >= 2 {
	if os.args[1] in ['cc', 'gcc', 'clang', 'msvc'] {
		cc = os.args[1]
	} else {
		println('> Usage error: parameter must be in cc/gcc/clang/msvc')
		return
	}
}
println('> Building VLS...')

ret := system('v -gc boehm -cg -cc $cc cmd/vls -o ${join_path(vls_bin_dir, vls_exec_name)}')
if ret != 0 {
	println('Failed building VLS')
	return
}

println('> VLS built successfully!')
