module analyzer

import os

const (
	v_ext                           = '.v'
	user_os                         = os.user_os()
	c_file_suffixes                 = [
		'_windows',
		'_linux',
		'_macos',
		'_darwin',
		'_ios',
		'_android',
		'_freebsd',
		'_openbsd',
		'_netbsd',
		'_dragonfly',
		'_solaris',
		'_nix',
		'_native',
		// '.freestanding'
	]
	os_file_specific_suffix_indices = {
		'windows':   [0]
		'linux':     [1, 11]
		'macos':     [2, 3, 11]
		'ios':       [4, 11]
		'android':   [5, 11]
		'freebsd':   [6, 11]
		'openbsd':   [7, 11]
		'netbsd':    [8, 11]
		'dragonfly': [9, 11]
		'solaris':   [10, 11]
	}
)

fn should_analyze_file_c(file_name string) bool {
	if file_name.ends_with('.js.v') {
		return false
	}

	for os, file_suffix_indices in analyzer.os_file_specific_suffix_indices {
		for i in file_suffix_indices {
			suffix := analyzer.c_file_suffixes[i]
			if file_name.ends_with(suffix + '.v') || file_name.ends_with(suffix + '.c.v') {
				if os != analyzer.user_os {
					return false
				}

				return true
			}
		}
	}

	return true
}

pub fn should_analyze_file(file_name string) bool {
	if !file_name.ends_with('.v') {
		return false
	}

	// TODO: support for JS and ASM
	if file_name.ends_with('.js.v') {
		return false
	}

	if file_name.ends_with('_test.v')
		|| file_name.all_before_last('.v').all_before_last('.').ends_with('_test') {
		return false
	}

	if !should_analyze_file_c(file_name) {
		return false
	}

	// if file.starts_with('.#') {
	// 		continue
	// 	}
	// 	if file.contains('_d_') {
	// 		if prefs.compile_defines_all.len == 0 {
	// 			continue
	// 		}
	// 		mut allowed := false
	// 		for cdefine in prefs.compile_defines {
	// 			file_postfix := '_d_${cdefine}.v'
	// 			if file.ends_with(file_postfix) {
	// 				allowed = true
	// 				break
	// 			}
	// 		}
	// 		if !allowed {
	// 			continue
	// 		}
	// 	}

	// 	if file.contains('_notd_') {
	// 		mut allowed := true
	// 		for cdefine in prefs.compile_defines {
	// 			file_postfix := '_notd_${cdefine}.v'
	// 			if file.ends_with(file_postfix) {
	// 				allowed = false
	// 				break
	// 			}
	// 		}
	// 		if !allowed {
	// 			continue
	// 		}
	// 	}
	return true
}

struct ImportPathIterator {
	start_path            string
	lookup_paths          []string
	fallback_lookup_paths []string
mut:
	idx         int
	in_start    bool = true
	in_fallback bool
}

fn (mut iter ImportPathIterator) next() ?string {
	if iter.in_start {
		defer {
			iter.in_start = false
		}
		return iter.start_path
	}

	if !iter.in_fallback && iter.idx >= iter.lookup_paths.len {
		iter.in_fallback = true
		iter.idx = 0
	}

	if iter.in_fallback && iter.idx >= iter.fallback_lookup_paths.len {
		return none
	}

	defer {
		iter.idx++
	}
	return if !iter.in_fallback {
		iter.lookup_paths[iter.idx]
	} else {
		iter.fallback_lookup_paths[iter.idx]
	}
}

fn (mut iter ImportPathIterator) reset() {
	iter.idx = 0
	iter.in_fallback = false
	iter.in_start = true
}
