module main

import os
import time

// CompletionImportsScan inventories optional auto-imports on a worker. Its
// result owns its data and can be discarded on a watched file change.
struct CompletionImportsScan {
	key        string
	prefix     string
	generation u64
	result     chan []ImportableModule
}

fn scan_completion_imports(scan CompletionImportsScan, dir string, root string) {
	mut worker := &App{}
	modules := worker.importable_modules_in_scope(dir, root, scan.prefix)
	scan.result <- modules
}

// completion_imports returns the last compatible result while a single
// background scan is running. A completion marked incomplete tells LSP
// clients to request the rest as the user types.
fn (mut app App) completion_imports(file_path string, prefix string) ([]ImportableModule, bool) {
	if scan := app.completion_imports_scan {
		mut modules := []ImportableModule{}
		if scan.result.try_pop(mut modules) == .success {
			app.completion_imports_scan = none
			if scan.generation == app.completion_imports_generation {
				app.completion_imports_cache[scan.key] = ImportableModulesCache{
					prefix:  scan.prefix
					modules: modules
					at_ms:   time.now().unix_milli()
				}
			}
		}
	}
	dir := os.real_path(os.dir(file_path))
	root := app.importable_module_root(file_path)
	key := '${root}\x00${dir}\x00${os.vmodules_paths().join('|')}\x00${find_v_dir()}'
	if cached := app.completion_imports_cache[key] {
		if prefix.starts_with(cached.prefix) && time.now().unix_milli() - cached.at_ms < importable_modules_ttl_ms {
			return cached.modules, false
		}
	}
	if app.completion_imports_scan == none {
		scan := CompletionImportsScan{
			key:        key
			prefix:     prefix
			generation: app.completion_imports_generation
			result:     chan []ImportableModule{cap: 1}
		}
		app.completion_imports_scan = scan
		spawn scan_completion_imports(scan, dir, root)
	}
	return []ImportableModule{}, true
}
