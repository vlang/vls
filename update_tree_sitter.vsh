// This is a script that will pull and update
// tree-sitter library files from upstream.
import x.json2

fn rm_rf(path string) {
	if !is_dir(path) {
		rm(path) or {
			eprintln(err)
			return
		}
	}
}

fn patch_file(file_path string, texts_to_replace []string) ! {
	file_contents := read_file(file_path) or {
		return error('Cannot read file ${file_path}. Reason: $err')
	}

	write_file(file_path, file_contents.replace_each(texts_to_replace)) or {
		return error('Cannot write file ${file_path}. Reason: $err')
	}
}

fn patch_includes(lib_files []string, includes_to_replace []string) {
	mapped_includes_to_replace := includes_to_replace.map('#include "$it"')
	for file_path in lib_files {
		patch_file(file_path, mapped_includes_to_replace) or {
			eprintln(err)
			continue
		}
	}
}

tree_sitter_dir := join_path(getwd(), 'tree_sitter')
lib_dir := join_path(tree_sitter_dir, 'lib')

// check if version txt file exists. clone repo
// if outdated or file does not exist.
version_file_path := join_path(tree_sitter_dir, 'ts_version.json')
mut got_version := ''

if exists(version_file_path) {
	version_file_contents := read_file(version_file_path)!
	version_obj := json2.fast_raw_decode(version_file_contents)?.as_map()
	got_version = version_obj['version']!.str()
} else {
	println('Version file not found. Proceeding...')
}

// remove tree-sitter dir first
clone_dir := join_path(temp_dir(), 'tree_sitter')

if exists(clone_dir) {
	walk(clone_dir, rm_rf)
	rmdir_all(clone_dir)!
}

// clone tree-sitter repository to temp directory
git_clone_cmd := 'git clone --depth 1 https://github.com/tree-sitter/tree-sitter.git $clone_dir'
println('Executing: $git_clone_cmd')
git_clone_cmd_out := execute(git_clone_cmd)
if git_clone_cmd_out.exit_code != 0 {
	eprintln('Failed to clone tree-sitter.')
	eprintln(git_clone_cmd_out.output)
	exit(git_clone_cmd_out.exit_code)
}

// get ts current git commit hash
git_curr_version_cmd := 'git -C $clone_dir rev-parse HEAD'
println('Executing: $git_curr_version_cmd')
curr_version_cmd_out := execute(git_curr_version_cmd)
if curr_version_cmd_out.exit_code != 0 {
	eprintln('Failed to obtain tree-sitter version.')
	eprintln(curr_version_cmd_out.output)
	exit(curr_version_cmd_out.exit_code)
}

if got_version == curr_version_cmd_out.output.trim_space() {
	println('You are using the latest version of Tree-Sitter.')
	exit(0)
}

// remove old tree-sitter if cloning is success
rmdir_all(lib_dir)!

// copy lib to $VLS_FOLDER/tree_sitter/lib
ts_lib_src_dir := join_path(clone_dir, 'lib', 'src')
cp_all(ts_lib_src_dir, lib_dir, true)!

// copy tree_sitter/api.h and tree_sitter/parser.h
ts_lib_include_dir := join_path(clone_dir, 'lib', 'include', 'tree_sitter')

cp(join_path(ts_lib_include_dir, 'api.h'), join_path(lib_dir, 'api.h'))!
cp(join_path(ts_lib_include_dir, 'parser.h'), join_path(lib_dir, 'parser.h'))!

// patch files to avoid conflicts
mut includes_to_replace := []string{cap: 5 * 2}
includes_to_replace << ['tree_sitter/api.h', 'api.h']
includes_to_replace << ['tree_sitter/parser.h', 'parser.h']

files_to_rename := [['atomic.h', 'ts_atomic.h']]
for file_name in files_to_rename {
	old_file_name := join_path(lib_dir, file_name[0])
	if !exists(old_file_name) {
		println('$old_file_name does not exist. Skip renaming...')
	}

	new_file_name := join_path(lib_dir, file_name[1])
	mv(old_file_name, new_file_name)!
	includes_to_replace << ['./${file_name[0]}', './${file_name[1]}']
}

patch_file(join_path(lib_dir, 'ts_atomic.h'), ['atomic_', 'ts_atomic_'])?
patch_file(join_path(lib_dir, 'ts_atomic.h'), ['__ts_atomic_load_n', '__atomic_load_n'])?

patch_file(join_path(lib_dir, 'parser.c'), ['atomic_', 'ts_atomic_'])?
patch_file(join_path(lib_dir, 'subtree.c'), ['atomic_', 'ts_atomic_'])?

patch_includes(glob(join_path(lib_dir, '*.h')) or { []string{} }, includes_to_replace)
patch_includes(glob(join_path(lib_dir, '*.c')) or { []string{} }, includes_to_replace)

// add txt file for tree-sitter version
write_file(version_file_path, '{"version": "$curr_version_cmd_out.output.trim_space()"}')!

// remove temp clone dir
walk(clone_dir, rm_rf)
rmdir_all(clone_dir)!
