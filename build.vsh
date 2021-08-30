#!/usr/local/bin/v run

import os

mut cc := 'gcc'
if os.args.len >= 2 {
	if os.args[1] in ['gcc', 'clang', 'msvc'] {
		cc = os.args[1]
	} else {
		println('> Usage error: parameter must in gcc/clang/msvc')
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
