module main

import os
import time

// Completion of the modules a file can import: the project's modules, the
// packages installed with `v install` (the VMODULES folders) and V's own vlib.
// Accepting one of them also adds its `import` line.

const importable_modules_ttl_ms = 10_000
const importable_module_max_depth = 8
const importable_module_max_count = 1000
// The folders of vlib that hold no module a program imports: tests and their
// data, and examples.
const vlib_scaffolding_dirs = ['tests', 'testdata', 'slow_tests', 'examples']

enum ModuleOrigin {
	project
	vpm
	vlib
}

// ImportableModule is a module a file can import: the path `import` takes and
// the name the code writes, the last part of that path. One that is not
// `offered` still takes its path and imports modules; a `deprecated` one is
// offered, as V still builds with it, and shown as such.
struct ImportableModule {
	path       string
	name       string
	dir        string
	origin     ModuleOrigin
	offered    bool
	deprecated bool
}

struct ImportableModulesCache {
	modules []ImportableModule
	at_ms   i64
}

// ModuleImports are the module paths that the files of a module folder import.
struct ModuleImports {
	paths []string
	at_ms i64
}

// importable_modules lists the modules `file_path` can import: the folders under
// the project root (its v.mod folder, or the program that imports the file),
// under each VMODULES path and under vlib whose files declare the module named
// after the folder. The file's own module is left out, and so are the modules
// that already import it: V3 accepts that cycle, but V1, which VLS asks for
// definitions and hints, does not.
fn (mut app App) importable_modules(file_path string) []ImportableModule {
	file_dir := os.dir(file_path)
	vmod_root := find_project_root(file_dir)
	root := if vmod_root != '' { vmod_root } else { app.program_root(file_path) }
	all := app.cached_importable_modules(root)
	own_dir := os.real_path(file_dir)
	own := all.filter(it.dir == own_dir)
	reaching := app.modules_reaching(own, all)
	return all.filter(it.offered && it.dir != own_dir && it.path !in reaching)
}

// cached_importable_modules walks `root` and the VMODULES folders at most once
// every `importable_modules_ttl_ms`; a watched file change clears the cache.
// vlib comes last: a module of the same path in the project or in VMODULES is
// the one V imports.
fn (mut app App) cached_importable_modules(root string) []ImportableModule {
	vmodules := os.vmodules_paths()
	key := '${root}|${vmodules.join('|')}'
	now := time.now().unix_milli()
	if cached := app.importable_modules_cache[key] {
		if now - cached.at_ms < importable_modules_ttl_ms {
			return cached.modules
		}
	}
	mut found := []ImportableModule{}
	mut seen_paths := map[string]bool{}
	mut seen_dirs := map[string]bool{}
	if root != '' && os.is_dir(root) {
		collect_importable_modules(root, '', .project, 0, mut found, mut seen_paths, mut
			seen_dirs)
	}
	for dir in vmodules {
		if os.is_dir(dir) {
			collect_importable_modules(dir, '', .vpm, 0, mut found, mut seen_paths, mut seen_dirs)
		}
	}
	for m in app.vlib_modules() {
		if m.path !in seen_paths {
			seen_paths[m.path] = true
			found << m
		}
	}
	app.importable_modules_cache[key] = ImportableModulesCache{
		modules: found
		at_ms:   now
	}
	return found
}

// vlib_modules lists the modules of V's vlib. It is walked once, and again
// after a watched file of vlib changes, as when working on V itself.
fn (mut app App) vlib_modules() []ImportableModule {
	v_dir := find_v_dir()
	if v_dir == '' {
		return []
	}
	vlib := os.join_path(v_dir, 'vlib')
	if vlib !in app.vlib_modules_cache {
		mut found := []ImportableModule{}
		mut seen_paths := map[string]bool{}
		mut seen_dirs := map[string]bool{}
		if os.is_dir(vlib) {
			collect_importable_modules(vlib, '', .vlib, 0, mut found, mut seen_paths, mut
				seen_dirs)
		}
		app.vlib_modules_cache[vlib] = found
	}
	return app.vlib_modules_cache[vlib] or { [] }
}

// collect_importable_modules walks the folders below `dir`. A folder is a module
// to import when its V files declare the module named after it (and that is not
// `main`); its import path is the folder path from where the walk started, with
// dots. Hidden and build folders are skipped, and so is the V repository's own
// `vlib`, whose modules are imported without that prefix, and in vlib the
// folders of tests and examples. Not offered, though found: a module that V
// refuses to build a program with, vlib's `builtin`, which every file has, and
// the internals of a vlib module.
fn collect_importable_modules(dir string, prefix string, origin ModuleOrigin, depth int, mut found []ImportableModule, mut seen_paths map[string]bool, mut seen_dirs map[string]bool) {
	if depth >= importable_module_max_depth || found.len >= importable_module_max_count {
		return
	}
	real := os.real_path(dir)
	if real in seen_dirs {
		return
	}
	seen_dirs[real] = true
	mut entries := os.ls(dir) or { return }
	entries.sort()
	for entry in entries {
		if entry.starts_with('.') || entry in index_excluded_dirs
			|| (prefix == '' && origin == .project && entry == 'vlib')
			|| (origin == .vlib && entry in vlib_scaffolding_dirs) {
			continue
		}
		sub := os.join_path(dir, entry)
		if !os.is_dir(sub) {
			continue
		}
		path := if prefix == '' { entry } else { '${prefix}.${entry}' }
		if entry != 'main' && path !in seen_paths && declared_module_of_dir(sub) == entry {
			seen_paths[path] = true
			deprecated, refused := module_deprecation(sub)
			found << ImportableModule{
				path:       path
				name:       entry
				dir:        os.real_path(sub)
				origin:     origin
				offered:    !(origin == .vlib && (path == 'builtin' || 'internal' in path.split('.')))
					&& !refused && !module_needs_flag(sub)
				deprecated: deprecated
			}
		}
		collect_importable_modules(sub, path, origin, depth + 1, mut found, mut seen_paths, mut
			seen_dirs)
	}
}

// declared_module_of_dir returns the module declared by the first V file directly
// in `dir`: 'main' for a file without a module line, '' when there is none.
fn declared_module_of_dir(dir string) string {
	mut files := os.ls(dir) or { return '' }
	files.sort()
	for file in files {
		if !file.ends_with('.v') || file.ends_with('_test.v') {
			continue
		}
		path := os.join_path(dir, file)
		if os.is_dir(path) {
			continue
		}
		content := os.read_file(path) or { continue }
		name := get_module_name(content)
		return if name == '' { 'main' } else { name }
	}
	return ''
}

// module_deprecation reports whether the module in `dir` is deprecated, and
// whether V already refuses it: a deprecated module is a warning, or a notice
// until its `deprecated_after` date, and an error from that date on.
fn module_deprecation(dir string) (bool, bool) {
	files := os.ls(dir) or { return false, false }
	today := time.now().strftime('%Y-%m-%d')
	mut deprecated := false
	for file in files {
		if !file.ends_with('.v') || file.ends_with('_test.v') {
			continue
		}
		for attribute in module_line_attributes(os.join_path(dir, file)) {
			if !attribute.contains('deprecated') {
				continue
			}
			deprecated = true
			if attribute.contains('deprecated_after') {
				after := attribute_value(attribute, 'deprecated_after')
				if after != '' && after <= today {
					return true, true
				}
			}
		}
	}
	return deprecated, false
}

// attribute_value returns the quoted value that `name` takes in `attribute`, as
// `2026-01-31` in `@[deprecated_after: '2026-01-31']`.
fn attribute_value(attribute string, name string) string {
	rest := attribute.all_after(name).trim_left(' :')
	if rest == '' || rest[0] !in [`'`, `"`] {
		return ''
	}
	return rest[1..].all_before(rest[..1])
}

// module_line_attributes returns the attributes in front of the module line of
// the V file at `path`. Only the start of the file is read, where that line is.
fn module_line_attributes(path string) []string {
	mut file := os.open(path) or { return [] }
	defer {
		file.close()
	}
	mut head := []u8{len: 4096}
	n := file.read(mut head) or { return [] }
	mut attributes := []string{}
	for line in head[..n].bytestr().split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.starts_with('module ') {
			break
		}
		if trimmed.starts_with('@[') || trimmed.starts_with('[') {
			attributes << trimmed
		}
	}
	return attributes
}

// module_needs_flag reports whether a file of the module in `dir` stops the build
// with `$compile_error` unless a `-d` flag leaves that file out, as `sync.arc`
// does without `-d ownership`.
fn module_needs_flag(dir string) bool {
	files := os.ls(dir) or { return false }
	for file in files {
		if !file.ends_with('.v') || !file.contains('_notd_') {
			continue
		}
		content := os.read_file(os.join_path(dir, file)) or { continue }
		if content.split_into_lines().any(it.starts_with('\$compile_error(')) {
			return true
		}
	}
	return false
}

// modules_reaching returns the paths of the modules in `all` that import one of
// `own`, directly or through others. A module imports modules of its origin or
// of those after it (a project imports packages and vlib, a package imports
// vlib), so only the modules that can reach `own` are read; vlib's imports are
// read once.
fn (mut app App) modules_reaching(own []ImportableModule, all []ImportableModule) map[string]bool {
	mut reaching := map[string]bool{}
	if own.len == 0 {
		return reaching
	}
	mut last_origin := 0
	for m in own {
		if int(m.origin) > last_origin {
			last_origin = int(m.origin)
		}
	}
	mut importers := map[string][]string{}
	for m in all {
		if int(m.origin) > last_origin {
			continue
		}
		for path in app.module_imports_of(m) {
			importers[path] << m.path
		}
	}
	mut pending := own.map(it.path)
	for pending.len > 0 {
		path := pending.pop()
		for importer in importers[path] or { []string{} } {
			if importer !in reaching {
				reaching[importer] = true
				pending << importer
			}
		}
	}
	return reaching
}

// module_imports_of returns the module paths that `m` imports, read again from
// its folder at most once every `importable_modules_ttl_ms`, or for vlib only
// when a watched file of that folder changes.
fn (mut app App) module_imports_of(m ImportableModule) []string {
	now := time.now().unix_milli()
	if cached := app.module_imports_cache[m.dir] {
		if m.origin == .vlib || now - cached.at_ms < importable_modules_ttl_ms {
			return cached.paths
		}
	}
	paths := module_dir_imports(m.dir)
	app.module_imports_cache[m.dir] = ModuleImports{
		paths: paths
		at_ms: now
	}
	return paths
}

// forget_module_folder drops what is known of the folder that holds the file at
// `path`, which changed on disk: the modules it imports, for a file of vlib the
// list of vlib's modules, and for one of vlib/builtin its functions.
fn (mut app App) forget_module_folder(path string) {
	dir := os.real_path(os.dir(path))
	app.module_imports_cache.delete(dir)
	app.builtin_calls_cache.delete(dir)
	stale := app.vlib_modules_cache.keys().filter(path_is_within(dir, it))
	for vlib in stale {
		app.vlib_modules_cache.delete(vlib)
	}
}

// module_dir_imports returns the module paths that the V files in `dir` import.
fn module_dir_imports(dir string) []string {
	mut paths := []string{}
	files := os.ls(dir) or { return paths }
	for file in files {
		if !file.ends_with('.v') || file.ends_with('_test.v') {
			continue
		}
		content := os.read_file(os.join_path(dir, file)) or { continue }
		for binding in parse_import_bindings(content) {
			if binding.module_path !in paths {
				paths << binding.module_path
			}
		}
	}
	return paths
}

// module_import_completions offers the importable modules that `content` does
// not import yet; accepting one also inserts its `import` line. Nothing is
// offered inside a string or a comment.
fn (mut app App) module_import_completions(uri string, content string, position Position) []Detail {
	if position_in_string_or_comment(content, position, app.position_encoding) {
		return []
	}
	mut taken := map[string]bool{}
	for binding in parse_import_bindings(content) {
		taken[binding.module_path] = true
		taken[binding.alias] = true
	}
	spot := import_spot(content)
	mut items := []Detail{}
	for m in app.importable_modules(uri_to_path(uri)) {
		if m.path in taken || m.name in taken {
			continue
		}
		items << Detail{
			kind:                  9 // CompletionItemKind.Module
			label:                 m.name
			detail:                match m.origin {
				.project { 'import ${m.path}' }
				.vpm { 'import ${m.path} (vpm)' }
				.vlib { 'import ${m.path} (vlib)' }
			}
			insert_text:           m.name
			tags:                  if m.deprecated { [1] } else { none }
			additional_text_edits: [spot.edit(m.path)]
		}
	}
	return items
}

// import_line_module_completions completes an `import` line with the project's
// modules and the installed packages, one path segment at a time. vlib is left
// to get_import_completions.
fn (mut app App) import_line_module_completions(file_path string, line string) []Detail {
	trimmed := line.trim_space()
	typed := if trimmed.len > 7 { trimmed[7..].trim_space() } else { '' }
	parts := typed.split('.')
	base := parts[..parts.len - 1]
	prefix := parts.last()
	mut labels := map[string]bool{}
	mut items := []Detail{}
	for m in app.importable_modules(file_path) {
		if m.origin == .vlib {
			continue
		}
		segments := m.path.split('.')
		if segments.len <= base.len || segments[..base.len] != base
			|| !segments[base.len].starts_with(prefix) {
			continue
		}
		label := segments[base.len]
		if label in labels {
			continue
		}
		labels[label] = true
		detail := if segments.len > base.len + 1 {
			'folder of modules'
		} else if m.origin == .vpm {
			'vpm module'
		} else {
			'project module'
		}
		items << Detail{
			kind:        9 // CompletionItemKind.Module
			label:       label
			detail:      detail
			insert_text: label
		}
	}
	return items
}

const declaration_starts = ['fn ', 'pub ', 'struct ', 'const ', 'enum ', 'interface ', 'type ',
	'union ', '__global', '$']

// ImportSpot is where a file takes a new `import` line: the line it goes in
// front of, and the text around the import there.
struct ImportSpot {
	line   int
	before string
	after  string
}

// import_spot finds where `content` takes a new `import`: after the last import,
// else in its own paragraph after the module line, else at the top (below a `#!`
// line). Only the header is read, since V has no imports after a declaration.
fn import_spot(content string) ImportSpot {
	lines := content.split_into_lines()
	mut scan_state := ImportScanState{}
	mut module_line := -1
	mut last_import := -1
	mut in_import_block := false
	for i, raw_line in lines {
		code := source_line_import_code(raw_line, mut scan_state).trim_space()
		if in_import_block {
			if code.starts_with(')') {
				in_import_block = false
			}
			last_import = i
			continue
		}
		if code.starts_with('module ') && module_line < 0 {
			module_line = i
		} else if code.starts_with('import ') {
			last_import = i
			in_import_block = code[7..].trim_space() == '('
		} else if declaration_starts.any(code.starts_with(it)) {
			break
		}
	}
	if last_import >= 0 {
		return ImportSpot{
			line:  last_import + 1
			after: '\n'
		}
	}
	if module_line >= 0 {
		return ImportSpot{
			line:   module_line + 1
			before: '\n'
			after:  '\n'
		}
	}
	return ImportSpot{
		line:  if lines.len > 0 && lines[0].starts_with('#!') { 1 } else { 0 }
		after: '\n\n'
	}
}

// edit inserts `import module_path` at the spot.
fn (spot ImportSpot) edit(module_path string) TextEdit {
	at := Position{
		line: spot.line
		char: 0
	}
	return TextEdit{
		range:    LSPRange{
			start: at
			end:   at
		}
		new_text: '${spot.before}import ${module_path}${spot.after}'
	}
}

// position_in_string_or_comment reports whether the text right before `position`
// is inside a string literal or a comment. The scan starts at the top-level
// declaration around the position, where no string or comment is open.
fn position_in_string_or_comment(content string, position Position, enc PositionEncoding) bool {
	lines := content.split_into_lines()
	if position.line < 0 || position.line >= lines.len || position.char <= 0 {
		return false
	}
	mut first := position.line
	for first > 0 && !declaration_starts.any(lines[first].starts_with(it)) {
		first--
	}
	col := encoded_col_to_byte(lines[position.line], position.char, enc) - 1
	line_in_scan := position.line - first
	for token in tokenize_v_source(lines[first..position.line + 1].join('\n')) {
		if token.line == line_in_scan && token.type_idx in [sem_tok_string, sem_tok_comment]
			&& token.start <= col && col < token.start + token.length {
			return true
		}
	}
	return false
}
