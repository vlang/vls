// Persistent diagnostics cache: a check is reused whenever the program it
// ran on and the compiler it ran with are unchanged, within the session
// and across restarts. The fingerprint covers file contents (editor
// buffers win over disk), so an identical state never pays for a check
// twice; anything the fingerprint does not cover falls back to a check.
module main

import json2
import os
import time

// diag_disk_cache_version versions the on-disk format.
const diag_disk_cache_version = 1
// diag_disk_cache_max_bytes bounds one program's cache file; larger caches
// are neither loaded nor written.
const diag_disk_cache_max_bytes = 2 * 1024 * 1024
// diag_disk_cache_max_entries bounds the entries kept per program.
const diag_disk_cache_max_entries = 1024

// compiler_fingerprint identifies the compiler a check ran with: its path,
// size and modification time. A compiler upgrade changes the binary, so
// cached diagnostics never survive one.
fn compiler_fingerprint() string {
	exe := resolve_v_compiler_exe()
	info := os.stat(exe) or { return exe }
	return '${exe}:${info.size}:${info.mtime}'
}

// program_content_fingerprint is what the `.v` files under `root` hold:
// their paths and content hashes, with the editor's open buffers winning
// over disk. It shares the walk bounds and exclusions of the workspace
// index; an incomplete walk salts the fingerprint so it never matches.
fn (app &App) program_content_fingerprint(root string) string {
	if root == '' || !os.is_dir(root) {
		return 'noroot:${time.now().unix_nano()}'
	}
	mut files := []string{}
	mut complete := collect_v_files_bounded(root, project_disk_max_files, mut files)
	files.sort()
	mut parts := []string{cap: files.len}
	mut bytes_read := u64(0)
	for path in files {
		content := app.source_text(path)
		if u64(content.len) > index_max_file_bytes
			|| u64(content.len) > project_disk_max_bytes - bytes_read {
			complete = false
			continue
		}
		bytes_read += u64(content.len)
		parts << '${path}:${content.hash()}'
	}
	if !complete {
		parts << 'incomplete:${time.now().unix_nano()}'
	}
	return parts.join('\n')
}

// diag_cache_base_dir holds one cache file per program. Tests point it
// elsewhere with VLS_DIAG_CACHE_DIR.
fn diag_cache_base_dir() string {
	override := os.getenv('VLS_DIAG_CACHE_DIR')
	if override != '' {
		return override
	}
	return os.join_path(os.cache_dir(), 'vls', 'check-diag')
}

fn diag_cache_file(program_root string) string {
	return os.join_path(diag_cache_base_dir(), 'prog_${program_root.hash().hex()}.json')
}

// DiagDiskCache is the on-disk format: a version, the compiler that wrote
// it, and the cached results by file path. Entries are DiagCacheEntry,
// shared with the session cache, so disk results merge without conversion.
struct DiagDiskCache {
	version  int
	compiler string
	entries  map[string]DiagCacheEntry
}

// load_diag_disk_cache reads the program's cache file; anything unreadable,
// oversized, versioned otherwise, or written by another compiler is dropped.
fn load_diag_disk_cache(program_root string) map[string]DiagCacheEntry {
	if program_root == '' {
		return {}
	}
	raw := os.read_file(diag_cache_file(program_root)) or { return {} }
	if raw.len > diag_disk_cache_max_bytes {
		return {}
	}
	stored := json2.decode[DiagDiskCache](raw) or { return {} }
	if stored.version != diag_disk_cache_version || stored.compiler != compiler_fingerprint() {
		return {}
	}
	return stored.entries
}

// save_diag_disk_entry records one file result, keeping what is already
// cached for the program. Writes are best effort: a cache must never fail
// a check.
fn save_diag_disk_entry(program_root string, path string, entry DiagCacheEntry) {
	if program_root == '' {
		return
	}
	file := diag_cache_file(program_root)
	mut entries := map[string]DiagCacheEntry{}
	if raw := os.read_file(file) {
		if raw.len <= diag_disk_cache_max_bytes {
			if stored := json2.decode[DiagDiskCache](raw) {
				if stored.version == diag_disk_cache_version
					&& stored.compiler == compiler_fingerprint() {
					entries = stored.entries.clone()
				}
			}
		}
	}
	entries[path] = entry
	if entries.len > diag_disk_cache_max_entries {
		return
	}
	encoded := json2.encode(DiagDiskCache{
		version:  diag_disk_cache_version
		compiler: compiler_fingerprint()
		entries:  entries
	})
	if encoded.len > diag_disk_cache_max_bytes {
		return
	}
	os.mkdir_all(os.dir(file)) or { return }
	os.write_file(file, encoded) or {}
}

// ensure_diag_disk_cache merges the program's disk results into the
// session cache once; later lookups hit memory. The fingerprint each entry
// carries still decides every hit.
fn (mut app App) ensure_diag_disk_cache(program_root string) {
	if program_root == '' || program_root in app.diag_disk_roots {
		return
	}
	app.diag_disk_roots[program_root] = true
	for path, disk in load_diag_disk_cache(program_root) {
		if path !in app.diag_cache {
			app.diag_cache[path] = DiagCacheEntry{
				fingerprint: disk.fingerprint
				errors:      disk.errors
			}
		}
	}
}
