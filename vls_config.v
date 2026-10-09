// Layered configuration: what a check runs with, and the switches a project may
// set for itself. V only compiles the code inside `$if flag ?` when it is given
// `-d flag`, and VLS used to run the compiler without any define, so that code
// was never checked. The defines now come from three tiers, the first that
// carries a value winning: the editor's own settings, the project's `vls.json`,
// and the VLS_DEFINES environment variable.
//
// The state lives here rather than on App: App is declared in main.v, and a
// configuration cache is not a reason to change it.
module main

import json2
import os
import sync
import time

// vls_config_file_name is the per-project override file. Its folder is the
// project root: the nearest directory above the file that holds a `v.mod`.
const vls_config_file_name = 'vls.json'

// vls_config_ttl_ms is how long a project's configuration is reused before it is
// read again. A watched change drops it at once; the bound is what keeps a client
// that watches only `.v` files from reading a stale `vls.json` for ever.
const vls_config_ttl_ms = 10_000

// vls_defines_env_var is the last tier of the defines. VFLAGS also reaches every
// compiler invocation, and the compiler merges the two, but VLS_DEFINES is the
// variable this file's precedence can reason about.
const vls_defines_env_var = 'VLS_DEFINES'

// EditorSettings is the top tier: what the editor last sent through
// workspace/didChangeConfiguration. The payload carries the whole settings state,
// so a key it does not send is unset rather than unknown: an empty `defines`
// leaves the decision to the tier below it.
struct EditorSettings {
mut:
	defines     []string
	inlay_hints ?bool
	diagnostics ?bool
}

// EditorDefinesParams is the shape an editor's configuration payload has: the
// defines may sit under `vls.defines` or directly under `defines`, so a client
// that sections its settings and one that does not both work.
struct EditorDefinesParams {
	settings EditorDefinesSettings
}

struct EditorDefinesSettings {
	vls     EditorDefines
	defines ?[]string
}

struct EditorDefines {
	defines ?[]string
}

// VlsProjectFile is the schema of a project's `vls.json`. Only the keys VLS
// consumes are declared, so an unknown key is dropped instead of rejecting the
// whole file.
struct VlsProjectFile {
mut:
	defines     []string
	inlay_hints ?bool @[json: 'inlayHints']
	diagnostics ?bool
}

// VlsProjectConfig is the merged result for one project root: the argument pairs
// a check runs with, and the switches the feature handlers apply.
struct VlsProjectConfig {
mut:
	defines     []string
	inlay_hints ?bool
	diagnostics ?bool
}

// VlsConfigCacheEntry is one project root's configuration and when it was read.
struct VlsConfigCacheEntry {
	config    VlsProjectConfig
	at_ms     i64
	signature string
}

// VlsConfigStore is the process-wide state of the layered configuration: the
// editor tier, and the merged configuration of every project root read so far.
// Both are read from the request thread and from the workers that run checks, so
// every access is behind the lock.
struct VlsConfigStore {
mut:
	editor EditorSettings
	roots  map[string]VlsConfigCacheEntry
	mu     &sync.RwMutex = sync.new_rwmutex()
}

// vls_config_store returns the store, created on first use. A function-local
// static holds it because the configuration has no field in App to live in; the
// same pattern keeps interop.v's temp path counter out of module scope.
fn vls_config_store() &VlsConfigStore {
	unsafe {
		mut static store := &VlsConfigStore{}
		if store == unsafe { nil } {
			store = &VlsConfigStore{}
		}
		return store
	}
}

// apply_editor_configuration folds a workspace/didChangeConfiguration payload
// into the configuration. The editor's settings are the top tier, so they are
// stored first; the merged result is then applied for every workspace root, and
// a changed defines value drops the cached diagnostics, which were computed with
// the old ones.
fn (mut app App) apply_editor_configuration(params_json string) {
	mut store := vls_config_store()
	previous := store.editor_settings().defines
	mut editor := EditorSettings{
		defines: resolve_editor_defines(params_json)
	}
	resolved := resolve_workspace_settings(params_json)
	if enabled := resolved.inlay_hints {
		editor.inlay_hints = enabled
	}
	if enabled := resolved.diagnostics {
		editor.diagnostics = enabled
	}
	// The editor tier is part of every merge, so the results cached for the
	// project roots are the ones computed without it.
	store.set_editor_settings(editor)
	current := editor.defines
	if current != previous {
		// A check's fingerprint covers the sources and the compiler, so every
		// result cached for any file is the one the old defines produce.
		app.diag_cache = map[string]DiagCacheEntry{}
		log('VLS: defines=${current}')
	}
	for root in app.workspace_roots {
		app.apply_project_settings(app.project_config_for_root(root))
	}
}

// project_config_for_path merges the tiers for the project root that owns `path`.
fn (mut app App) project_config_for_path(path string) VlsProjectConfig {
	return app.project_config_for_root(project_root_for_path(path))
}

// project_config_for_root merges the tiers for one project root, reusing the
// cached result for `vls_config_ttl_ms`. When a re-read finds a different
// configuration, the diagnostics computed with the old one are dropped.
fn (mut app App) project_config_for_root(root string) VlsProjectConfig {
	store := vls_config_store()
	if cached := store.cached_config(root, time.now().unix_milli()) {
		return cached
	}
	config := merge_config_tiers(store.editor_settings(), read_project_file(root),
		env_defines())
	previous := store.store_config(root, config)
	if previous != '' && previous != config_signature(config) {
		app.forget_project_diagnostics(root)
	}
	return config
}

// check_defines returns the defines the check of `path` runs with, and applies
// the switches of the same configuration, so a project's `vls.json` is in step
// even when the client's settings were sent before it was ever read.
fn (mut app App) check_defines(path string) []string {
	config := app.project_config_for_path(path)
	app.apply_project_settings(config)
	return config.defines.clone()
}

// apply_project_settings writes the switches of `config` into the App fields the
// feature handlers read. A tier that says nothing leaves the field as it is.
fn (mut app App) apply_project_settings(config VlsProjectConfig) {
	if enabled := config.inlay_hints {
		app.inlay_hints_enabled = enabled
	}
	if enabled := config.diagnostics {
		app.diagnostics_enabled = enabled
		if !enabled {
			app.cancel_all_scheduled_diagnostics()
		}
	}
}

// forget_config_file drops the configuration cached for the project root that
// owns `path` when `path` is that project's `vls.json`, together with the
// diagnostics computed with it, so the next check reads the file again.
fn (mut app App) forget_config_file(path string) {
	if os.file_name(path) != vls_config_file_name {
		return
	}
	root := project_root_for_path(path)
	mut store := vls_config_store()
	store.drop_config(root)
	app.forget_project_diagnostics(root)
}

// forget_project_diagnostics drops the diagnostics cached for the files under
// `root`: they were computed with another configuration.
fn (mut app App) forget_project_diagnostics(root string) {
	if root == '' {
		return
	}
	dir := normalize_overlay_path(root)
	mut stale := []string{}
	for uri, _ in app.diag_cache {
		if path_is_within(normalize_overlay_path(uri_to_path(uri)), dir) {
			stale << uri
		}
	}
	for uri in stale {
		app.diag_cache.delete(uri)
	}
}

// check_args_with_defines appends the defines of a check to its argument vector.
// The compiler takes options anywhere in the vector, so appending them after the
// path is enough. `v fmt` and the `-line-info` questions never see them: a
// formatter must not depend on the flags, and a question answered ahead of a
// check must not change with them.
fn check_args_with_defines(args []string, defines []string) []string {
	if defines.len == 0 {
		return args
	}
	mut out := args.clone()
	out << defines
	return out
}

// cached_config returns the configuration of `root` when it was read less than
// `vls_config_ttl_ms` ago.
fn (store &VlsConfigStore) cached_config(root string, now i64) ?VlsProjectConfig {
	store.mu.rlock()
	defer {
		store.mu.runlock()
	}
	if cached := store.roots[config_root_key(root)] {
		if now - cached.at_ms < vls_config_ttl_ms {
			return cached.config
		}
	}
	return none
}

// store_config records the configuration of `root` and returns the signature of
// the entry it replaces, or '' when the root had none.
fn (mut store VlsConfigStore) store_config(root string, config VlsProjectConfig) string {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	mut previous := ''
	if outdated := store.roots[config_root_key(root)] {
		previous = outdated.signature
	}
	store.roots[config_root_key(root)] = VlsConfigCacheEntry{
		config:    config
		at_ms:     time.now().unix_milli()
		signature: config_signature(config)
	}
	return previous
}

// drop_config forgets the configuration of `root`.
fn (mut store VlsConfigStore) drop_config(root string) {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.roots.delete(config_root_key(root))
}

// editor_settings returns the editor tier.
fn (store &VlsConfigStore) editor_settings() EditorSettings {
	store.mu.rlock()
	defer {
		store.mu.runlock()
	}
	return store.editor
}

// set_editor_settings replaces the editor tier, and drops the configuration
// cached for every project root, because that tier is part of all of them.
fn (mut store VlsConfigStore) set_editor_settings(settings EditorSettings) {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.editor = settings
	store.roots = map[string]VlsConfigCacheEntry{}
}

// project_root_for_path returns the project root that owns `path`: the folder
// with the nearest `v.mod` above it, or its own directory when there is none.
fn project_root_for_path(path string) string {
	return project_root_for_dir(os.dir(path))
}

// project_root_for_dir returns the project root a directory belongs to.
fn project_root_for_dir(dir string) string {
	if dir == '' {
		return ''
	}
	root := find_project_root(dir)
	return config_root_key(if root != '' { root } else { dir })
}

// config_root_key normalises a project root into the one spelling the cache is
// keyed by. A path from a URI uses forward slashes and one built from the
// filesystem may not, and they must not cache the same project twice.
fn config_root_key(root string) string {
	return normalize_overlay_path(root)
}

// read_project_file reads the project's `vls.json`. A missing, unreadable or
// malformed file contributes nothing: it must never keep a check from running.
fn read_project_file(root string) VlsProjectFile {
	if root == '' {
		return VlsProjectFile{}
	}
	path := os.join_path(root, vls_config_file_name)
	raw := os.read_file(path) or { return VlsProjectFile{} }
	return json2.decode[VlsProjectFile](raw) or { return VlsProjectFile{} }
}

// env_defines is the last tier: VLS_DEFINES, split with the quoting rules the
// compiler itself reads VFLAGS with.
fn env_defines() []string {
	raw := os.getenv_opt(vls_defines_env_var) or { return [] }
	return os.split_args(raw) or { return [] }
}

// merge_config_tiers folds the three tiers. For each key the first tier that
// carries a value wins, so the editor overrides the project and the project
// overrides the environment. A defines value replaces the one below it rather
// than adding to it, so the tiers cannot build up flags nobody asked for.
fn merge_config_tiers(editor EditorSettings, file VlsProjectFile, env []string) VlsProjectConfig {
	mut config := VlsProjectConfig{}
	if editor.defines.len > 0 {
		config.defines = define_args(editor.defines)
	} else if file.defines.len > 0 {
		config.defines = define_args(file.defines)
	} else {
		config.defines = define_args(env)
	}
	if enabled := editor.inlay_hints {
		config.inlay_hints = enabled
	} else if enabled := file.inlay_hints {
		config.inlay_hints = enabled
	}
	if enabled := editor.diagnostics {
		config.diagnostics = enabled
	} else if enabled := file.diagnostics {
		config.diagnostics = enabled
	}
	return config
}

// config_signature identifies a merged configuration, so a re-read can tell
// whether a project's file actually changed.
fn config_signature(config VlsProjectConfig) string {
	mut parts := [config.defines.join(' ')]
	if enabled := config.inlay_hints {
		parts << 'inlayHints:${enabled}'
	}
	if enabled := config.diagnostics {
		parts << 'diagnostics:${enabled}'
	}
	return parts.join('|')
}

// define_args turns the entries of a `defines` setting into the argument pairs
// the compiler takes. Both spellings an editor sends are accepted: `-d bespin` as
// two entries, and `-dbespin` as one. Anything that is not a `-d` flag is
// dropped, because this setting carries compile-time defines and nothing else.
fn define_args(defines []string) []string {
	mut args := []string{cap: defines.len}
	mut i := 0
	for i < defines.len {
		entry := defines[i].trim_space()
		i++
		if entry == '' {
			continue
		}
		if entry == '-d' {
			// The name is the next entry; a lone `-d` at the end carries none.
			if i < defines.len {
				name := defines[i].trim_space()
				if name != '' && !name.starts_with('-') {
					args << ['-d', name]
					i++
				}
			}
			continue
		}
		if entry.starts_with('-d') {
			args << ['-d', entry[2..].trim_left('=').trim_space()]
		}
	}
	return args
}

// resolve_editor_defines returns the defines of a
// workspace/didChangeConfiguration payload, and an empty list when it carries
// none: the payload is the whole settings state, so a missing key is an unset
// one, and the tiers below it decide.
fn resolve_editor_defines(params_json string) []string {
	decoded := json2.decode[EditorDefinesParams](params_json) or { return [] }
	if defines := decoded.settings.vls.defines {
		return defines
	}
	return decoded.settings.defines or { [] }
}
