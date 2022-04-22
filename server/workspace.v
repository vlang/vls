module server

import lsp
import json
import os

fn (mut ls Vls) did_change_watched_files(params string) {
	did_change_watched_params := json.decode(lsp.DidChangeWatchedFilesParams, params) or {
		ls.panic(err.msg())
		return
	}

	changes := did_change_watched_params.changes
	mut is_rename := false

	// NOTE:
	// 1. Renaming a file returns two events: one "deleted" event for
	//    the file with old name and one "created" event for the same
	//    file with new name.
	// 2. Deleting a folder does not trigger a "deleted" event. Restoring
	//    the files of the folder however triggers the "created" event.
	// 3. Renaming a folder triggers the "created" event for each file
	//    but with no "deleted" event prior to it.
	for i, change in changes {
		match change.typ {
			.created {
				if is_rename {
					prev_uri := changes[i - 1].uri
					if prev_uri in ls.files {
						ls.files[change.uri] = ls.files[prev_uri]
						ls.files.delete(prev_uri)
					}

					prev_uri_path := prev_uri.path()
					prev_uri_dir := prev_uri.dir_path()
					prev_uri_file_name := os.base(prev_uri_path)
					new_uri_path := change.uri.path()
					new_uri_file_name := os.base(new_uri_path)
					if prev_uri_path in ls.store.opened_scopes {
						ls.store.opened_scopes[new_uri_path] = ls.store.opened_scopes[prev_uri_path]
						ls.store.opened_scopes.delete(prev_uri_path)
					}

					// update existing symbols
					mut symbols := ls.store.get_symbols_by_file_path(prev_uri_path)
					for mut sym in symbols {
						sym.file_path = new_uri_path
					}

					// update existing imports
					for mut imp in ls.store.imports[prev_uri_dir] {
						if prev_uri_path in imp.ranges {
							imp.ranges[new_uri_path] = imp.ranges[prev_uri_path]
							imp.ranges.delete(prev_uri_path)
						}

						if prev_uri_file_name in imp.aliases {
							imp.aliases[new_uri_file_name] = imp.aliases[prev_uri_file_name]
							imp.aliases.delete(prev_uri_file_name)
						}

						if prev_uri_file_name in imp.symbols {
							imp.symbols[new_uri_file_name] = imp.symbols[prev_uri_file_name]
							imp.symbols.delete(prev_uri_file_name)
						}
					}

					is_rename = false
				} else {
					// TODO: let did_open do the job(?)
				}
			}
			.changed {
				// let did_change do the thing
				continue
			}
			.deleted {
				// do not proceed if type of change is a file rename
				if next_change := changes[i + 1] {
					// is_rename is set to true if next change event is created
					// and the same as the current uri
					is_rename = next_change.typ == .created && next_change.uri == change.uri
					continue
				}

				// TODO: use did_close(?)
				file_path := change.uri.path()

				ls.files.delete(change.uri)
				ls.store.opened_scopes.delete(file_path)

				if ls.files.count(change.uri.dir()) == 0 {
					ls.store.delete(change.uri.dir_path())
				} else {
					// delete symbols
					file_dir := change.uri.dir_path()
					for j := 0; j < ls.store.symbols[file_dir].len; {
						sym := ls.store.symbols[file_dir][j]
						if sym.file_path == file_path {
							ls.store.symbols[file_dir].delete(j)
						} else {
							j++
						}
					}

					// delete import
					file_name := os.base(file_path)
					for mut imp in ls.store.imports[file_dir] {
						imp.ranges.delete(file_path)
						imp.aliases.delete(file_name)
						imp.symbols.delete(file_name)
					}
				}
			}
		}

		// ls.log_message(change.str(), .info)
	}
}
