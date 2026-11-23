module main

import os

struct ModuleDirectoryEntries {
mut:
	folders []string
	sources []string
}

// module_directory_entries sorts directories for stable precedence and source
// names for the first-file module declaration rule.
fn module_directory_entries(dir string) ?ModuleDirectoryEntries {
	mut entries := ModuleDirectoryEntries{}
	$if macos || linux {
		entries = native_module_directory_entries(dir) or { return none }
	} $else {
		for name in os.ls(dir) or { return none } {
			if os.is_dir(os.join_path(dir, name)) {
				entries.folders << name
			} else if name.ends_with('.v') && is_regular_module_source(dir, name) {
				entries.sources << name
			}
		}
	}
	entries.folders.sort()
	entries.sources.sort()
	return entries
}

fn is_regular_module_source(dir string, name string) bool {
	info := os.stat(os.join_path(dir, name)) or { return false }
	return info.get_filetype() == .regular
}

$if macos || linux {
	#include <dirent.h>

	fn native_module_directory_entries(dir string) ?ModuleDirectoryEntries {
		handle := unsafe { C.opendir(&char(dir.str)) }
		if isnil(handle) {
			return none
		}
		defer { C.closedir(handle) }
		mut entries := ModuleDirectoryEntries{}
		for {
			entry := C.readdir(handle)
			if isnil(entry) {
				break
			}
			name := unsafe { tos_clone(&u8(&entry.d_name[0])) }
			if name == '.' || name == '..' {
				continue
			}
			kind := entry.d_type
			// readdir already knows the kind in most directories. Follow links
			// and look up unknown entries exactly as os.is_dir did in the walk.
			if kind == C.DT_DIR || (kind in [C.DT_UNKNOWN, C.DT_LNK]
				&& os.is_dir(os.join_path(dir, name))) {
				entries.folders << name
			} else if name.ends_with('.v') && (kind == C.DT_REG
				|| (kind in [C.DT_UNKNOWN, C.DT_LNK] && is_regular_module_source(dir, name))) {
				entries.sources << name
			}
		}
		return entries
	}
}
