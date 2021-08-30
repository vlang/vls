#!/usr/local/bin/v run

import os

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

ret := system('v -gc boehm -cc $cc cmd/vls -o vls')
if ret != 0 {
	println('Failed building VLS')
	return
}

println('> VLS built successfully!')
