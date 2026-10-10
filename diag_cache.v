// Persistent diagnostics cache: a check is reused whenever the program it
// ran on and the compiler it ran with are unchanged, within the session
// and across restarts. The fingerprint covers file contents (editor
// buffers win over disk), so an identical state never pays for a check
// twice; anything the fingerprint does not cover falls back to a check.
module main

import json2
import os
import time

// diag_disk_cache_version versions the on-disk format. Version 2 stores one
// state per program instead of one entry per file: a 40-file program's
// fingerprints no longer reach the byte cap, which used to make the cache
// silently stop writing entirely.
const diag_disk_cache_version = 2
// diag_disk_cache_max_bytes bounds one program's cache file; a larger state
// is neither loaded nor written.
const diag_disk_cache_max_bytes = 4 * 1024 * 1024
// project_files_ttl_ms is how long a directory listing is reused. A create or
// a delete drops it at once; a change does not, because the content memo
// gates on size, inode and mtime.
const project_files_ttl_ms = 2000

// ContentMemo is a file's content hash with the metadata it was read at.
// Rehashing is skipped while the three move together, which is the common
// case between two edits in a large project.
struct ContentMemo {
	valid bool
	hash  int
	len   int
	inode u64
	size  i64
	mtime i64
}

// FileListEntry is one project's `.v` file list, with the time it was taken.
struct FileListEntry {
	files    []string
	at_ms    i64
	complete bool
	valid    bool
}

// compiler_fingerprint identifies the compiler a check ran with: its path,
// size and modification time. A compiler upgrade changes the binary, so
// cached diagnostics never survive one.
fn compiler_fingerprint() string {
	exe := resolve_v_compiler_exe()
	info := os.stat(exe) or { return exe }
	return '${exe}:${info.size}:${info.mtime}'
}

// forget_project_files drops the cached listing of every project, which a
// file appearing or disappearing under a watched directory invalidates.
fn (mut app App) forget_project_files() {
	app.file_list_cache.clear()
}

// cached_project_files returns the project's `.v` files, walking at most once
// per `project_files_ttl_ms`. The listing is the expensive half of the
// fingerprint on a large tree, and it does not change between two edits.
fn (mut app App) cached_project_files(root string) ([]string, bool) {
	now := time.now().unix_milli()
	if cached := app.file_list_cache[root] {
		if cached.valid && now - cached.at_ms < project_files_ttl_ms {
			return cached.files, cached.complete
		}
	}
	mut files := []string{}
	complete := collect_v_files_bounded(root, project_disk_max_files, mut files)
	files.sort()
	app.file_list_cache[root] = FileListEntry{
		files:    files.clone()
		at_ms:    now
		complete: complete
		valid:    true
	}
	return files, complete
}

// program_content_fingerprint is what the `.v` files under `root` hold:
// their paths and content hashes, with the editor's open buffers winning
// over disk. It shares the walk bounds and exclusions of the workspace
// index; an incomplete walk salts the fingerprint so it never matches.
//
// Three things keep it off the critical path on a large tree: the listing is
// cached, the open buffers are looked up in one map instead of a scan per
// candidate file, and an unchanged file on disk is not re-read — its size,
// inode and mtime gate the hash.
fn (mut app App) program_content_fingerprint(root string) string {
	if root == '' || !os.is_dir(root) {
		return 'noroot:${time.now().unix_nano()}'
	}
	files, mut complete := app.cached_project_files(root)
	mut open_by_path := map[string]string{}
	for uri, content in app.open_files {
		open_by_path[normalize_overlay_path(uri_to_path(uri))] = content
	}
	mut parts := []string{cap: files.len}
	mut bytes_read := u64(0)
	for path in files {
		if open_content := open_by_path[normalize_overlay_path(path)] {
			if u64(open_content.len) > index_max_file_bytes
				|| u64(open_content.len) > project_disk_max_bytes - bytes_read {
				complete = false
				continue
			}
			bytes_read += u64(open_content.len)
			parts << '${path}:${open_content.hash()}'
			continue
		}
		key := normalize_overlay_path(path)
		if memo := app.content_memo[key] {
			if memo.valid {
				info := os.stat(path) or {
					app.content_memo.delete(key)
					complete = false
					continue
				}
				if memo.size == info.size && memo.mtime == info.mtime
					&& memo.inode == info.inode {
					if u64(memo.len) > index_max_file_bytes
						|| u64(memo.len) > project_disk_max_bytes - bytes_read {
						complete = false
						continue
					}
					bytes_read += u64(memo.len)
					parts << '${path}:${memo.hash}'
					continue
				}
			}
		}
		content := os.read_file(path) or {
			complete = false
			continue
		}
		if u64(content.len) > index_max_file_bytes
			|| u64(content.len) > project_disk_max_bytes - bytes_read {
			complete = false
			continue
		}
		info := os.stat(path) or {
			complete = false
			continue
		}
		bytes_read += u64(content.len)
		hash := content.hash()
		app.content_memo[key] = ContentMemo{
			valid: true
			hash:  hash
			len:   content.len
			inode: info.inode
			size:  info.size
			mtime: info.mtime
		}
		parts << '${path}:${hash}'
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

// DiagDiskState is one checked state of a program: the fingerprint it was
// checked at, and the errors of each file the check answered for.
struct DiagDiskState {
	fingerprint string
	files       map[string][]JsonError
}

// DiagDiskCache is the on-disk format: a version, the compiler that wrote it,
// and the program's last checked state. One state instead of one entry per
// file keeps the file small, so a 200-file project no longer outgrows the
// byte cap and silently stops being cached.
struct DiagDiskCache {
	version  int
	compiler string
	state    DiagDiskState
}

// load_diag_disk_cache reads the program's stored state; anything unreadable,
// oversized, versioned otherwise, or written by another compiler is dropped.
fn load_diag_disk_cache(program_root string) ?DiagDiskState {
	if program_root == '' {
		return none
	}
	raw := os.read_file(diag_cache_file(program_root)) or { return none }
	if raw.len > diag_disk_cache_max_bytes {
		return none
	}
	stored := json2.decode[DiagDiskCache](raw) or { return none }
	if stored.version != diag_disk_cache_version || stored.compiler != compiler_fingerprint() {
		return none
	}
	if stored.state.fingerprint == '' {
		return none
	}
	return stored.state
}

// save_diag_disk_entry records one file result into the program's stored
// state, keeping the files of the same check together and dropping the
// results of a state that has been superseded. Writes are best effort: a
// cache must never fail a check.
fn save_diag_disk_entry(program_root string, path string, entry DiagCacheEntry) {
	if program_root == '' {
		return
	}
	file := diag_cache_file(program_root)
	mut state := load_diag_disk_cache(program_root) or {
		DiagDiskState{
			fingerprint: entry.fingerprint
			files:       map[string][]JsonError{}
		}
	}
	mut state_files := map[string][]JsonError{}
	if state.fingerprint == entry.fingerprint {
		state_files = state.files.clone()
	}
	state_files[path] = entry.errors
	encoded := json2.encode(DiagDiskCache{
		version:  diag_disk_cache_version
		compiler: compiler_fingerprint()
		state:    DiagDiskState{
			fingerprint: entry.fingerprint
			files:       state_files
		}
	})
	if encoded.len > diag_disk_cache_max_bytes {
		return
	}
	os.mkdir_all(os.dir(file)) or { return }
	os.write_file(file, encoded) or {}
}

// ensure_diag_disk_cache merges the program's stored state into the session
// cache once; later lookups hit memory. Only a state matching the
// fingerprint of this check is merged, so a reused answer always describes
// the same bytes.
fn (mut app App) ensure_diag_disk_cache(program_root string, fingerprint string) {
	if program_root == '' || program_root in app.diag_disk_roots {
		return
	}
	app.diag_disk_roots[program_root] = true
	state := load_diag_disk_cache(program_root) or { return }
	if state.fingerprint != fingerprint {
		return
	}
	for path, errors in state.files {
		if path !in app.diag_cache {
			app.diag_cache[path] = DiagCacheEntry{
				fingerprint: state.fingerprint
				errors:      errors
			}
		}
	}
}
