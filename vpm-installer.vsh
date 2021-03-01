// VLS VPM INSTALLER SCRIPT
// ========================
//
// This script is for users who have troubles compiling VLS through
// VPM / `v install` method (which the VSCode extension also uses).
//
// What it does is it automatically patches the VLS CLI file by 
// replacing `import vls` to `import vls.vls` (because of a quirk
// in the current imports system).
//
// Please also use this script when updating it to the latest version.
//
// To execute, type "v run <vls location>/vpm-installer.vsh" to install
// or "v run <vls location>/vpm-installer.vsh up" to update.
import os { args }

wd := getwd()
vmod_paths := vmodules_paths()
vls_path := join_path(vmod_paths[0], 'vls')
cli_path := join_path(vls_path, 'cmd', 'vls')
main_file_path := join_path(cli_path, 'main.v')
mut out_filename := 'vls'
$if windows {
	// vls.exe
	out_filename += '.exe'
}
program_path := join_path(vmod_paths[0], 'bin', out_filename)

// updates VLS to new version
if args.len >= 2 && args[1] == 'up' {
	rm(program_path) ?
	chdir(vls_path)
	println('> git reset --hard')
	system('git reset --hard')
	println('> git pull')
	system('git pull')
	chdir(wd)
}

println('Patching VLS CLI...')
mut cli_contents_lines := read_lines(main_file_path) ?
for i := 0; i < cli_contents_lines.len; i++ {
	if cli_contents_lines[i] == 'import vls' {
		cli_contents_lines[i] = 'import vls.vls'
		break
	}
}

write_file(main_file_path, cli_contents_lines.join('\n')) ?
println('Compiling VLS...')
println('> v -prod -o $out_file_path $cli_path')
compilation_exit_code := system('v -prod -o $out_file_path $cli_path')
if compilation_exit_code != 0 {
	return
}

println('VLS installed successfully.')


