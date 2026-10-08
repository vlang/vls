// vtest build: !windows
module main

import io
import os
import time
import x.json2

// A V3 diagnostics server. A query of one question gets the answer the test
// left for it; one of several questions gets for each, after its index, the
// position of the question itself as the declaration. It keeps the questions
// and a copy of the file of the first one, and fails the questions about a file
// whose name has `broken` in it, as V3 does with a program it cannot parse.
const fake_v3_query_server = r"#!/bin/sh
echo v-diagnostics-server: ready
here=$(dirname $0)
tab=$(printf '\t')
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	questions=${rest#* }
	echo v-diagnostics-server: child 1 $token
	echo $questions >> $here/questions.txt
	first=${questions%%$tab*}
	cp ${first%%:*} $here/asked.v
	case $first in
	*broken*) printf 'main.v:1:1: error: unexpected token\n\nv-diagnostics-server: end 1 %s\n' $token; continue ;;
	esac
	case $questions in
	*$tab*)
		i=0
		rest=$questions$tab
		while [ ${#rest} -gt 0 ]; do
			q=${rest%%$tab*}
			rest=${rest#*$tab}
			pos=${q#*:}
			printf '%s\t%s:%s:1\n' $i ${q%%:*} ${pos%%:*}
			i=$((i + 1))
		done
		;;
	*) cat $here/answer.txt; echo ;;
	esac
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

// A V that runs no diagnostics server, but whose V3 answers `-line-info` in a
// process of its own, with the answer the test left for it.
const fake_v3_one_shot = r"#!/bin/sh
case ${V_DIAGNOSTICS_SERVER}x in 1x) exit 0 ;; esac
here=$(dirname $0)
while [ $# -gt 0 ]; do
	if [ $1 = -line-info ]; then
		echo $2 >> $here/questions.txt
		cat $here/answer.txt
		exit 0
	fi
	shift
done
exit 1
"

// A V1 compiler that answers definition questions but has no V3 checker.
const fake_v1_definitions_only = r"#!/bin/sh
for arg in $@; do
	if [ $arg = -new-compiler ]; then
		echo 'unknown option `-new-compiler`'
		exit 1
	fi
done
while [ $# -gt 0 ]; do
	if [ $1 = -line-info ]; then
		question=$2
		file=${question%%:*}
		position=${question#*:}
		line=${position%%:*}
		case $line in
		3|13) printf '%s:3:3\n' $file ;;
		7|23) printf '%s:7:3\n' $file ;;
		17|19) printf '%s:17:1\n' $file ;;
		18) printf '%s:18:1\n' $file ;;
		esac
		exit 0
	fi
	shift
done
exit 0
"

// A V whose V3 has no query engine.
const fake_v3_without_line_info = r"#!/bin/sh
case ${V_DIAGNOSTICS_SERVER}x in 1x) exit 0 ;; esac
echo 'unknown option `-vls-mode`'
exit 1
"

// A V without a diagnostics server whose V3 answers `-line-info` in a process
// of its own, and notes each question with the program it checked: the last
// argument.
const fake_v3_notes_targets = r"#!/bin/sh
case ${V_DIAGNOSTICS_SERVER}x in 1x) exit 0 ;; esac
here=$(dirname $0)
question=
for arg in $@; do
	case $prev in -line-info) question=$arg ;; esac
	prev=$arg
done
echo $question $prev >> $here/questions.txt
cat $here/answer.txt
"

// A V3 diagnostics server whose every answer to a question is the position the
// question asks about: each name is its own declaration.
const fake_v3_self_declaration_server = r"#!/bin/sh
echo v-diagnostics-server: ready
tab=$(printf '\t')
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	questions=${rest#* }
	echo v-diagnostics-server: child 1 $token
	echo $questions [$(sed -n 4p ${questions%%:*} 2>/dev/null)] >> $(dirname $0)/questions.txt
	case $questions in
	*$tab*)
		i=0
		rest=$questions$tab
		while [ ${#rest} -gt 0 ]; do
			q=${rest%%$tab*}
			rest=${rest#*$tab}
			pos=${q#*:}
			printf '%s\t%s:%s:1\n' $i ${q%%:*} ${pos%%:*}
			i=$((i + 1))
		done
		;;
	*)
		pos=${questions#*:}
		printf '%s:%s:1\n' ${questions%%:*} ${pos%%:*}
		;;
	esac
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

// A diagnostics server that answers no question about line 4, and says that the
// name asked about anywhere else is declared at line 4, column 1: `p` of `p := 1`
// in the project of fake_v3_app.
const fake_v3_leads_back_server = r"#!/bin/sh
echo v-diagnostics-server: ready
tab=$(printf '\t')
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	questions=${rest#* }
	echo v-diagnostics-server: child 1 $token
	echo $questions >> $(dirname $0)/questions.txt
	i=0
	rest=$questions$tab
	while [ ${#rest} -gt 0 ]; do
		q=${rest%%$tab*}
		rest=${rest#*$tab}
		pos=${q#*:}
		if [ ${pos%%:*} != 4 ]; then
			case $questions in
			*$tab*) printf '%s\t%s:4:1\n' $i ${q%%:*} ;;
			*) printf '%s:4:1\n' ${q%%:*} ;;
			esac
		fi
		i=$((i + 1))
	done
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

// A diagnostics server that does not end when told to, as one whose child hangs.
// It gives up by itself after a while, so that no test leaves it running.
const fake_server_ignoring_quit = r"#!/bin/sh
echo v-diagnostics-server: ready
i=0
while [ $i -lt 10 ]; do
	sleep 1
	i=$((i + 1))
done
"

// A diagnostics server whose checks take two seconds and whose questions are
// answered at once.
const fake_slow_check_server = r"#!/bin/sh
echo v-diagnostics-server: ready
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	echo v-diagnostics-server: child 1 $token
	case $request in check) sleep 2 ;; esac
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

// A diagnostics server whose questions take a second to answer, and whose
// checks are answered at once.
const fake_slow_query_server = r"#!/bin/sh
echo v-diagnostics-server: ready
here=$(dirname $0)
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	echo v-diagnostics-server: child 1 $token
	case $request in query) sleep 1; cat $here/answer.txt; echo ;; esac
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

const fake_hover_answer = '{"contents":{"kind":"markdown","value":"```v\\nfake\\n```"}}'

// A V whose query server answers a hover with its answer.txt and a definition
// with the start of the line the question is on.
const fake_v3_hover_server = r"#!/bin/sh
echo v-diagnostics-server: ready
here=$(dirname $0)
tab=$(printf '\t')
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	questions=${rest#* }
	echo v-diagnostics-server: child 1 $token
	echo $questions >> $here/questions.txt
	i=0
	rest=$questions$tab
	while [ ${#rest} -gt 0 ]; do
		q=${rest%%$tab*}
		rest=${rest#*$tab}
		pos=${q#*:}
		case $q in
		*hv^*) printf '%s\t' $i; cat $here/answer.txt; echo ;;
		*) printf '%s\t%s:%s:1\n' $i ${q%%:*} ${pos%%:*} ;;
		esac
		i=$((i + 1))
	done
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

fn test_the_completion_placeholder_follows_a_dot_with_no_name() {
	source := 'fn main() {\n\tp := 1\n\tp.\n\tq.na\n\tprintln(p.x)\n}\n'
	// `p.` at the end of line 3: the cursor after the dot is column 3.
	assert with_completion_placeholder(source, '3:3') == source.replace('\tp.\n', '\tp.vlsmember\n')
	// A name after the dot already parses.
	assert with_completion_placeholder(source, '4:3') == source
	// A cursor that follows no dot.
	assert with_completion_placeholder(source, '2:3') == source
	assert with_completion_placeholder(source, '5:10') == source
	// Positions outside the text.
	assert with_completion_placeholder(source, '40:3') == source
	assert with_completion_placeholder(source, '3:0') == source
}

struct FakeV3 {
	dir     string
	project string
	server  string // the directory of the fake compiler, where it keeps what it was asked
}

// fake_v3_app returns an app that asks V3 first, and the fake compiler `script`
// as the diagnostics server it names (`VLS_DIAGNOSTICS_SERVER`) or as the V in
// use (`VLS_V_COMMAND`).
fn fake_v3_app(name string, script string, env_name string) !(&App, FakeV3) {
	dir := os.join_path(os.vtmp_dir(), 'vls_v3_query_${name}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	server := os.join_path(dir, 'server')
	os.mkdir_all(server)!
	exe := os.join_path(server, 'v')
	os.write_file(exe, script)!
	os.chmod(exe, 0o755)!
	os.write_file(os.join_path(server, 'answer.txt'), fake_hover_answer)!
	project := os.join_path(dir, 'project')
	os.mkdir_all(project)!
	os.write_file(os.join_path(project, 'main.v'), 'module main\n\nfn main() {\n\tp := 1\n\tprintln(p)\n}\n')!
	os.write_file(os.join_path(project, 'other.v'), 'module main\n\nfn other() {\n\tq := 2\n\tq.\n}\n')!
	os.setenv(env_name, exe, true)
	app := &App{
		open_files:           map[string]string{}
		temp_dir:             os.join_path(dir, 'tmp')
		v3_line_info_enabled: true
	}
	return app, FakeV3{
		dir:     dir
		project: project
		server:  server
	}
}

fn stop_fake_v3_app(mut app App, fake FakeV3) {
	app.stop_v3_queries()
	os.unsetenv('VLS_DIAGNOSTICS_SERVER')
	os.unsetenv('VLS_V_COMMAND')
	os.rmdir_all(fake.dir) or {}
}

fn (fake FakeV3) asked() string {
	return os.read_file(os.join_path(fake.server, 'asked.v')) or { '' }
}

fn (fake FakeV3) questions() []string {
	return (os.read_file(os.join_path(fake.server, 'questions.txt')) or { '' }).split_into_lines()
}

fn test_v3_answers_from_a_copy_that_holds_the_buffer() {
	mut app, fake := fake_v3_app('buffer', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	buffer := 'module main\n\nfn main() {\n\tp := 10\n\tprintln(p)\n}\n'
	app.open_files[uri] = buffer
	result := app.v3_line_info(.hover, uri, path, '4:hv^2') or {
		assert false, 'V3 gave no answer'
		return
	}
	assert result is Hover
	assert (result as Hover).contents.value.contains('fake')
	assert fake.questions().last().ends_with('main.v:4:hv^2')
	// The copy V3 checked holds the buffer, not the file on disk.
	assert fake.asked() == buffer
	assert os.read_file(path)!.contains('p := 1\n')
}

fn test_completion_writes_its_placeholder_in_the_copy_only() {
	mut app, fake := fake_v3_app('placeholder', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	// `other.v` is not open: the copy links it to the project until a request
	// writes it, which must not write through the link.
	path := os.join_path(fake.project, 'other.v')
	on_disk := os.read_file(path)!
	app.v3_line_info(.completion, path_to_uri(path), path, '5:3') or {}
	assert fake.asked() == on_disk.replace('\tq.\n', '\tq.vlsmember\n')
	assert os.read_file(path)! == on_disk
}

fn test_a_file_opened_after_the_copy_was_built_is_written_in_the_copy_only() {
	mut app, fake := fake_v3_app('opened_later', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	// main.v imports `helper`: the copy holds the files of helper as hard links
	// to them. Nothing imports `extra`: the copy links the whole directory.
	helper_path := os.join_path(fake.project, 'helper', 'helper.v')
	extra_path := os.join_path(fake.project, 'extra', 'extra.v')
	extra_sibling := os.join_path(fake.project, 'extra', 'more.v')
	os.mkdir_all(os.dir(helper_path))!
	os.mkdir_all(os.dir(extra_path))!
	os.write_file(helper_path, 'module helper\n\npub fn answer() int {\n\treturn 42\n}\n')!
	os.write_file(extra_path, 'module extra\n\npub fn one() int {\n\treturn 1\n}\n')!
	os.write_file(extra_sibling, 'module extra\n\npub fn two() int {\n\treturn 2\n}\n')!
	main_path := os.join_path(fake.project, 'main.v')
	main_uri := path_to_uri(main_path)
	app.open_files[main_uri] = 'module main\n\nimport helper\n\nfn main() {\n\tp := helper.answer()\n\tprintln(p)\n}\n'
	app.v3_line_info(.hover, main_uri, main_path, '6:hv^2') or {}
	copy_root := app.v3_copies()[0].overlay.temp_root
	copy_of_helper := os.join_path(copy_root, 'helper', 'helper.v')
	// What the test is about: the copy shares both files with the project.
	assert os.stat(copy_of_helper)!.inode == os.stat(helper_path)!.inode
	assert os.is_link(os.join_path(copy_root, 'extra'))
	helper_on_disk := os.read_file(helper_path)!
	extra_on_disk := os.read_file(extra_path)!
	// Both opened and edited, and not saved.
	helper_uri := path_to_uri(helper_path)
	extra_uri := path_to_uri(extra_path)
	helper_buffer := helper_on_disk.replace('42', '7') + '\nfn use() {\n\tx := answer()\n\tx.\n}\n'
	app.open_files[helper_uri] = helper_buffer
	app.open_files[extra_uri] = extra_on_disk.replace('1', '11')
	app.v3_line_info(.hover, main_uri, main_path, '6:hv^2') or {}
	assert os.read_file(os.join_path(copy_root, 'extra', 'extra.v'))! == app.open_files[extra_uri]
	// A completion writes its placeholder into the copy of helper.v.
	app.v3_line_info(.completion, helper_uri, helper_path, '9:3') or {}
	assert fake.asked() == helper_buffer.replace('\tx.\n', '\tx.vlsmember\n')
	assert os.read_file(helper_path)! == helper_on_disk
	assert os.read_file(extra_path)! == extra_on_disk
	// The files next to the one written are still in the copy.
	assert os.read_file(os.join_path(copy_root, 'extra', 'more.v'))! == os.read_file(extra_sibling)!
}

fn test_a_module_file_replaced_on_disk_is_taken_again_by_the_copy() {
	mut app, fake := fake_v3_app('replaced', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	// main.v imports `helper`: the copy holds helper.v as a hard link to it.
	helper_path := os.join_path(fake.project, 'helper', 'helper.v')
	os.mkdir_all(os.dir(helper_path))!
	os.write_file(helper_path, 'module helper\n\npub fn answer() int {\n\treturn 42\n}\n')!
	main_path := os.join_path(fake.project, 'main.v')
	main_uri := path_to_uri(main_path)
	app.open_files[main_uri] = 'module main\n\nimport helper\n\nfn main() {\n\tp := helper.answer()\n\tprintln(p)\n}\n'
	app.v3_line_info(.hover, main_uri, main_path, '6:hv^2') or {}
	copy_of_helper := os.join_path(app.v3_copies()[0].overlay.temp_root, 'helper', 'helper.v')
	assert os.stat(copy_of_helper)!.inode == os.stat(helper_path)!.inode
	// Replaced by another file, as a checkout or an editor that saves by
	// renaming does, and no client says so: the hard link holds the old one.
	replacement := helper_path + '.new'
	os.write_file(replacement, 'module helper\n\npub fn answer() string {\n\treturn "x"\n}\n')!
	os.rename(replacement, helper_path)!
	app.v3_line_info(.hover, main_uri, main_path, '6:hv^2') or {}
	assert os.read_file(copy_of_helper)! == os.read_file(helper_path)!
	// Written in place, then removed.
	os.write_file(helper_path, 'module helper\n\npub fn answer() f64 {\n\treturn 1.5\n}\n')!
	app.v3_line_info(.hover, main_uri, main_path, '6:hv^2') or {}
	assert os.read_file(copy_of_helper)! == os.read_file(helper_path)!
	os.rm(helper_path)!
	app.v3_line_info(.hover, main_uri, main_path, '6:hv^2') or {}
	assert !os.exists(copy_of_helper)
}

fn test_a_file_emptied_in_the_editor_is_empty_in_the_copy() {
	mut app, fake := fake_v3_app('emptied', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	// Nothing imports `extra`: the copy links the whole directory.
	extra_path := os.join_path(fake.project, 'extra', 'extra.v')
	os.mkdir_all(os.dir(extra_path))!
	os.write_file(extra_path, 'module extra\n\npub fn one() int {\n\treturn 1\n}\n')!
	main_path := os.join_path(fake.project, 'main.v')
	app.v3_line_info(.hover, path_to_uri(main_path), main_path, '4:hv^2') or {}
	copy_root := app.v3_copies()[0].overlay.temp_root
	assert os.is_link(os.join_path(copy_root, 'extra'))
	// Opened, and all its text deleted: nothing was written for it yet.
	app.open_files[path_to_uri(extra_path)] = ''
	app.v3_line_info(.hover, path_to_uri(main_path), main_path, '4:hv^2') or {}
	assert os.read_file(os.join_path(copy_root, 'extra', 'extra.v'))! == ''
	assert os.read_file(extra_path)! != ''
}

fn test_a_closed_file_goes_back_to_what_is_on_disk() {
	mut app, fake := fake_v3_app('closed', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	main_path := os.join_path(fake.project, 'main.v')
	main_uri := path_to_uri(main_path)
	app.open_files[main_uri] = 'module main\n\nfn main() {\n\tp := 10\n\tprintln(p)\n}\n'
	other := os.join_path(fake.project, 'other.v')
	app.v3_line_info(.hover, path_to_uri(other), other, '4:hv^2') or {}
	project := app.v3_copies()[0]
	copy_of_main := os.join_path(project.overlay.temp_root, 'main.v')
	assert os.read_file(copy_of_main)!.contains('p := 10\n')
	// Closed without saving: the copy holds main.v as it is on disk again.
	app.open_files.delete(main_uri)
	app.v3_line_info(.hover, path_to_uri(other), other, '4:hv^2') or {}
	assert os.read_file(copy_of_main)! == os.read_file(main_path)!
}

fn test_several_positions_are_asked_at_once() {
	mut app, fake := fake_v3_app('prefetch', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	// `p` where main.v declares it, and where it uses it.
	locations := [
		Location{
			uri:   uri
			range: LSPRange{
				start: Position{
					line: 3
					char: 1
				}
			}
		},
		Location{
			uri:   uri
			range: LSPRange{
				start: Position{
					line: 4
					char: 9
				}
			}
		},
	]
	mut cache := map[string]?Location{}
	app.v3_prefetch_anchors(locations, mut cache)
	// One query for both, and each answer kept where the lookups find it.
	assert fake.questions().len == 1
	for loc in locations {
		found := cache[anchor_cache_key(uri, loc.range.start.line, loc.range.start.char)] or {
			assert false, 'nothing kept for line ${loc.range.start.line}'
			return
		}
		assert found.uri == uri
		assert found.range.start.line == loc.range.start.line
	}
}

fn test_v1_answers_what_v3_cannot_parse() {
	mut app, fake := fake_v3_app('broken', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'broken.v')
	os.write_file(path, 'module main\n\nfn broken( {\n')!
	if _ := app.v3_line_info(.hover, path_to_uri(path), path, '3:hv^4') {
		assert false, 'a failed V3 query must leave the answer to V1'
	}
}

fn test_a_v1_only_compiler_refuses_a_rename_it_cannot_validate() {
	mut app, fake := fake_v3_app('v1_rename', fake_v1_definitions_only, 'VLS_V_COMMAND')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	os.setenv('VLS_DIAGNOSTICS_SERVER', 'off', true)
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	content := 'module main\n\nfn greet() int {\n\treturn 1\n}\n\nfn helper() int {\n\treturn 3\n}\n\nfn invoke(action fn () int) int {\n\tprintln(action())\n\treturn greet()\n}\n\nfn main() {\n\tx := 1\n\ty := 2\n\tprintln(x + y)\n\tprintln(invoke(fn () int {\n\t\treturn 2\n\t}))\n\tprintln(helper())\n}\n'
	os.write_file(path, content)!
	os.rm(os.join_path(fake.project, 'other.v'))!
	app.open_files[uri] = content
	app.workspace_roots = [fake.project]
	// The existing V1 definition path works after the V3 option is rejected.
	resolved := app.resolve_symbol_anchor_by(uri, 12, 9, false) or {
		panic('the fake V1 compiler did not answer the definition')
	}
	assert resolved.range.start.line == 2
	assert app.v3_one_shot_unsupported
	for spec in ['3:4 helper', '17:2 y', '3:4 action'] {
		parts := spec.split(' ')
		at := parts[0].split(':')
		request := Request{
			id:     1
			method: 'textDocument/rename'
			params: json2.encode(RenameParams{
				text_document: TextDocumentIdentifier{ uri: uri }
				position:      Position{ line: at[0].int() - 1, char: at[1].int() - 1 }
				new_name:      parts[1]
			})
		}
		if response := app.rename_request(request) {
			assert false, '${spec}: unvalidated rename returned ${response}'
		} else {
			assert err.msg().contains('cannot validate rename conflicts'), err.msg()
		}
	}
}

fn test_a_rename_refuses_when_known_definitions_disappear_after_editing() {
	script := fake_v3_leads_back_server.replace(r'if [ ${pos%%:*} != 4 ]; then',
		r'if [ ${pos%%:*} != 4 ] && grep -q "p := 1" ${q%%:*}; then')
	mut app, fake := fake_v3_app('rename_lost_answers', script, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	app.line_info_mode = .missing
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	app.open_files[uri] = os.read_file(path)!
	app.workspace_roots = [fake.project]
	if _ := app.rename_request(Request{
		id:     1
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{ uri: uri }
			position:      Position{ line: 3, char: 1 }
			new_name:      'renamed'
		})
	}) {
		assert false, 'a lost definition answer must not validate a rename'
	} else {
		assert err.msg().contains('previously resolved name'), err.msg()
	}
	copy_path := os.join_path(app.v3_query_pool().copies.values()[0].project.overlay.temp_root, 'main.v')
	assert os.read_file(copy_path)! == os.read_file(path)!
}

fn test_failed_sibling_buffer_write_prevents_querying_stale_overlay_text() {
	mut app, fake := fake_v3_app('sync_failure', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	app.open_files[uri] = os.read_file(path)!
	app.v3_line_info(.hover, uri, path, '4:hv^2') or { panic('first query failed') }
	copy_root := app.v3_query_pool().copies.values()[0].project.overlay.temp_root
	// A file occupying the sibling's parent makes the next buffer write fail.
	os.write_file(os.join_path(copy_root, 'blocked'), 'not a directory')!
	sibling := os.join_path(fake.project, 'blocked', 'sibling.v')
	app.open_files[path_to_uri(sibling)] = 'module main\n\nfn sibling() {}\n'
	asked := fake.questions().len
	if _ := app.v3_line_info(.hover, uri, path, '4:hv^2') {
		assert false, 'a stale sibling must not be queried'
	}
	assert fake.questions().len == asked
}

fn test_a_failed_compiler_check_is_not_a_successful_rename_validation() {
	for output in ['', 'compiler timed out', 'unknown option `-new-compiler`'] {
		if _ := rename_check_output(1, output) {
			assert false, 'a failed check must not validate a rename: ${output}'
		}
	}
	assert rename_check_output(0, '')! == ''
	message := 'main.v:3:1: error: redefinition of `helper`'
	assert rename_check_output(1, message)! == message
}

fn test_without_a_server_v3_answers_in_a_process_of_its_own() {
	mut app, fake := fake_v3_app('one_shot', fake_v3_one_shot, 'VLS_V_COMMAND')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	result := app.v3_line_info(.hover, path_to_uri(path), path, '4:hv^2') or {
		assert false, 'V3 gave no answer'
		return
	}
	assert (result as Hover).contents.value.contains('fake')
	assert fake.questions() == ['${os.join_path(app.v3_copies()[0].overlay.temp_root, 'main.v')}:4:hv^2']
	assert !app.v3_one_shot_unsupported
}

fn test_a_v_without_the_query_engine_leaves_the_answer_to_v1() {
	mut app, fake := fake_v3_app('no_engine', fake_v3_without_line_info, 'VLS_V_COMMAND')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	if _ := app.v3_line_info(.hover, path_to_uri(path), path, '4:hv^2') {
		assert false, 'a V without the query engine has no V3 answer'
	}
	assert app.v3_one_shot_unsupported
}

// A diagnostics server that answers no question: each one fails as on a
// program V3 cannot parse.
const fake_v3_failing_server = r"#!/bin/sh
echo v-diagnostics-server: ready
here=$(dirname $0)
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	echo ${rest#* } >> $here/questions.txt
	echo v-diagnostics-server: child 1 $token
	echo 'main.v:1:1: error: unexpected token'
	printf '\nv-diagnostics-server: end 1 %s\n' $token
done
"

// fake_one_shot_v writes the fake compiler that answers `-line-info` in a
// process of its own into a directory of its own under `dir`, with the answer
// the test left for it, and returns its path.
fn fake_one_shot_v(dir string, name string) !string {
	alone := os.join_path(dir, name)
	os.mkdir_all(alone)!
	exe := os.join_path(alone, 'v')
	os.write_file(exe, fake_v3_one_shot)!
	os.chmod(exe, 0o755)!
	os.write_file(os.join_path(alone, 'answer.txt'), fake_hover_answer)!
	return exe
}

fn test_v1_line_info_uses_the_warm_shared_server() {
	mut app, fake := fake_v3_app('v1_pooled', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	// V3 off: the request goes to the V1 path, which asks the shared pool first.
	app.v3_line_info_enabled = false
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	result := app.run_v_line_info(.hover, uri, '4:hv^2')
	assert result is Hover
	assert (result as Hover).contents.value.contains('fake')
	// Asked through the shared server, in the copy the diagnostics use.
	assert fake.questions().len == 1
	assert app.v3_copies().len == 1
	copy_root := app.v3_copies()[0].overlay.temp_root
	assert fake.questions()[0] == '${os.join_path(copy_root, 'main.v')}:4:hv^2'
	// The pool never changes how the session drives the compiler.
	assert app.line_info_mode == .unknown
	// A second request reuses the server and the copy: nothing new starts.
	app.run_v_line_info(.hover, uri, '4:hv^2')
	assert fake.questions().len == 2
	assert app.v3_query_pool().servers.len == 1
}

fn test_v1_definition_comes_back_mapped_from_the_shared_copy() {
	mut app, fake := fake_v3_app('v1_definition', fake_v3_self_declaration_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	app.v3_line_info_enabled = false
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	result := app.run_v_line_info(.definition, uri, '4:gd^2')
	assert result is Location
	found := result as Location
	// The server names the copy; the answer names the file it mirrors.
	assert found.uri == uri
	assert found.range.start.line == 3
}

fn test_v1_line_info_falls_back_to_its_own_process() {
	mut app, fake := fake_v3_app('v1_fallback', fake_v3_failing_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	app.v3_line_info_enabled = false
	// The V in use answers `-line-info` in a process of its own.
	os.setenv('VLS_V_COMMAND', fake_one_shot_v(fake.dir, 'alone')!, true)
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	result := app.run_v_line_info(.hover, uri, '4:hv^2')
	assert result is Hover
	assert (result as Hover).contents.value.contains('fake')
	// The pool was tried first, then the one-shot process answered.
	assert fake.questions().len == 1
	alone_questions := os.read_file(os.join_path(fake.dir, 'alone', 'questions.txt')) or { '' }
	assert alone_questions.split_into_lines().len == 1
}

fn test_v1_line_info_in_compat_mode_keeps_its_own_process() {
	mut app, fake := fake_v3_app('v1_compat', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	app.v3_line_info_enabled = false
	app.line_info_mode = .compat
	os.setenv('VLS_V_COMMAND', fake_one_shot_v(fake.dir, 'alone')!, true)
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	result := app.run_v_line_info(.hover, uri, '4:hv^2')
	assert result is Hover
	assert (result as Hover).contents.value.contains('fake')
	// Compat keeps its one-shot path: the shared server is never asked, and
	// the mode is untouched.
	assert !os.exists(os.join_path(fake.server, 'questions.txt'))
	assert app.line_info_mode == .compat
}

fn test_v1_line_info_without_a_server_keeps_its_own_process() {
	mut app, fake := fake_v3_app('v1_no_server', fake_v3_one_shot, 'VLS_V_COMMAND')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	app.v3_line_info_enabled = false
	os.setenv('VLS_DIAGNOSTICS_SERVER', 'off', true)
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	result := app.run_v_line_info(.hover, uri, '4:hv^2')
	assert result is Hover
	assert (result as Hover).contents.value.contains('fake')
	// No server to ask: no copy is built for questions.
	assert app.v3_copies().len == 0
}

fn test_only_a_created_or_deleted_file_rebuilds_the_copy() {
	mut app, fake := fake_v3_app('watcher', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	app.v3_line_info(.hover, path_to_uri(path), path, '4:hv^2') or {}
	assert app.v3_copies().len == 1
	// A change shows through the copy.
	app.v3_query_notice_disk_change(path, 2)
	assert app.v3_copies().len == 1
	// A new file is not in it.
	app.v3_query_notice_disk_change(os.join_path(fake.project, 'new.v'), 1)
	assert app.v3_copies().len == 0
}

fn test_a_disk_create_refreshes_the_owned_directory_of_an_existing_program_copy() {
	mut app, fake := fake_v3_app('owned_watcher', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	helper := os.join_path(fake.project, 'helper', 'helper.v')
	os.mkdir_all(os.dir(helper))!
	os.write_file(helper, 'module helper\n\npub fn answer() int { return 42 }\n')!
	main_path := os.join_path(fake.project, 'main.v')
	main_uri := path_to_uri(main_path)
	app.open_files[main_uri] = 'module main\n\nimport helper\n\nfn main() { println(helper.answer()) }\n'
	app.v3_line_info(.hover, main_uri, main_path, '5:hv^26') or {}
	mut pool := app.v3_query_pool()
	mut program := pool.program_copy(os.dir(main_path))
	program.mutex.lock()
	defer {
		program.mutex.unlock()
	}
	copy_dir := os.join_path(program.project.overlay.temp_root, 'helper')
	assert !os.is_link(copy_dir)
	// A watcher can mark a copy while a request already holds its lock. The
	// request must see the new file when it next prepares that same copy.
	new_file := os.join_path(fake.project, 'helper', 'new.v')
	new_content := 'module helper\n\npub fn another() int { return 7 }\n'
	os.write_file(new_file, new_content)!
	app.v3_query_notice_disk_change(new_file, 1)
	app.prepare_program_copy(mut pool, mut program, main_path, os.dir(main_path))!
	assert os.read_file(os.join_path(copy_dir, 'new.v'))! == new_content
}

fn test_a_test_file_is_asked_as_a_program_of_its_own() {
	mut app, fake := fake_v3_app('test_file', fake_v3_notes_targets, 'VLS_V_COMMAND')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	// The program of the directory leaves its test files out: V builds each one
	// with the files of its module.
	test_path := os.join_path(fake.project, 'main_test.v')
	os.write_file(test_path, 'module main\n\nfn test_one() {\n\tp := 1\n\tassert p == 1\n}\n')!
	main_path := os.join_path(fake.project, 'main.v')
	app.v3_line_info(.hover, path_to_uri(test_path), test_path, '4:hv^2') or {}
	app.v3_line_info(.hover, path_to_uri(main_path), main_path, '4:hv^2') or {}
	copy_root := app.v3_copies()[0].overlay.temp_root
	copy_of_test := os.join_path(copy_root, 'main_test.v')
	assert fake.questions() == ['${copy_of_test}:4:hv^2 ${copy_of_test}',
		'${os.join_path(copy_root, 'main.v')}:4:hv^2 .']
}

fn stop_and_report(mut server DiagnosticsServer, done chan bool) {
	server.stop()
	done <- true
}

fn test_a_server_that_does_not_end_is_stopped_anyway() {
	dir := os.join_path(os.vtmp_dir(), 'vls_v3_query_stop_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	exe := os.join_path(dir, 'v')
	os.write_file(exe, fake_server_ignoring_quit)!
	os.chmod(exe, 0o755)!
	mut server := start_diagnostics_server(exe, [], dir, false, false)!
	done := chan bool{cap: 1}
	spawn stop_and_report(mut server, done)
	select {
		_ := <-done {
		}
		5 * time.second {
			assert false, 'stop() waited for a server that does not end'
		}
	}
}

fn test_a_test_file_does_not_push_out_the_server_of_the_program() {
	mut app, fake := fake_v3_app('evict', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	exe := os.getenv('VLS_DIAGNOSTICS_SERVER')
	mut pool := new_diagnostics_server_pool()
	defer {
		pool.stop_all()
	}
	// The program of the directory first: the oldest server, when a fourth
	// program needs one.
	for target in ['.', 'a_test.v', 'b_test.v', 'c_test.v'] {
		pool.query(exe, ['-w', '-check', '-nocolor', target], fake.project, 'main.v:4:hv^2') or {}
	}
	targets := pool.servers.keys().map(it.all_after_last('\n'))
	assert '.' in targets, targets.str()
	assert 'a_test.v' !in targets, targets.str()
}

fn test_a_rename_asks_nothing_its_prepare_rename_asked() {
	mut app, fake := fake_v3_app('rename_cache', fake_v3_self_declaration_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	app.open_files[uri] = os.read_file(path)!
	app.workspace_roots = [fake.project]
	// `p` of `p := 1`.
	position := Position{
		line: 3
		char: 1
	}
	app.prepare_rename_request(Request{
		id:     1
		method: 'textDocument/prepareRename'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      position
		})
	}) or {}
	asked := fake.questions().len
	assert fake.questions().any(it.contains(':4:gd^')), 'prepareRename asked nothing'
	app.rename_request(Request{
		id:     2
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      position
			new_name:      'q'
		})
	}) or {}
	// With the documents as they were, the rename knows where `p` is declared:
	// it asks about line 4 again only in the copy that holds the renamed text,
	// to see where the renamed names lead there (see check_rename_conflicts).
	later := fake.questions()[asked..]
	assert !later.any(it.contains(':4:gd^') && it.contains('p := 1')), later.str()
	assert later.any(it.contains(':4:gd^') && it.contains('q := 1')), later.str()
}

fn test_a_rename_asks_again_what_its_prepare_rename_could_not_tell() {
	mut app, fake := fake_v3_app('rename_unanswered', fake_v3_leads_back_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	// No V1 either: a question V3 leaves unanswered gets no answer.
	app.line_info_mode = .missing
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	app.open_files[uri] = os.read_file(path)!
	app.workspace_roots = [fake.project]
	// `p` of `p := 1`: V3 does not say where it is declared, and its use in
	// `println(p)` leads back to it.
	position := Position{
		line: 3
		char: 1
	}
	prepared := app.prepare_rename_request(Request{
		id:     1
		method: 'textDocument/prepareRename'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      position
		})
	})!
	assert json2.encode(prepared).contains('"placeholder":"p"'), json2.encode(prepared)
	asked := fake.questions().len
	app.rename_request(Request{
		id:     2
		method: 'textDocument/rename'
		params: json2.encode(RenameParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      position
			new_name:      'q'
		})
	}) or {}
	// The compiler may have failed for a moment: what got no answer is asked again.
	later := fake.questions()[asked..]
	assert later.any(it.contains(':4:gd^')), later.str()
}

fn test_two_editors_on_one_project_keep_their_copies_apart() {
	mut first, fake := fake_v3_app('two_editors', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut first, fake)
	}
	first.diagnostics_scheduler = new_diagnostics_scheduler()
	// A VLS serving two clients over TCP has an App for each.
	mut second := &App{
		open_files:           map[string]string{}
		temp_dir:             os.join_path(fake.dir, 'tmp2')
		v3_line_info_enabled: true
	}
	defer {
		second.stop_v3_queries()
	}
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	first.open_files[uri] = 'module main\n\nfn main() {\n\tp := 10\n\tprintln(p)\n}\n'
	second.open_files[uri] = 'module main\n\nfn main() {\n\tp := 20\n\tprintln(p)\n}\n'
	first.v3_line_info(.hover, uri, path, '4:hv^2') or {}
	assert fake.asked() == first.open_files[uri]
	second.v3_line_info(.hover, uri, path, '4:hv^2') or {}
	assert fake.asked() == second.open_files[uri]
	// Each is asked about its own buffer, whatever the other wrote meanwhile.
	first.v3_line_info(.hover, uri, path, '4:hv^2') or {}
	assert fake.asked() == first.open_files[uri]
	// One that stops removes its own files only.
	second_copy := second.v3_copies()[0].overlay.temp_root
	first.stop_diagnostics_servers()
	assert os.is_dir(second_copy)
	first.stop_v3_queries()
	assert os.is_dir(second_copy)
	second.v3_line_info(.hover, uri, path, '4:hv^2') or {}
	assert fake.asked() == second.open_files[uri]
}

fn test_two_programs_of_one_project_keep_their_copies_apart() {
	mut app, fake := fake_v3_app('two_programs', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	// One v.mod and two programs: the one at its root, and cmd/tool.
	os.write_file(os.join_path(fake.project, 'v.mod'), "Module {\n\tname: 'project'\n}\n")!
	tool := os.join_path(fake.project, 'cmd', 'tool', 'main.v')
	os.mkdir_all(os.dir(tool))!
	os.write_file(tool, 'module main\n\nfn main() {\n\tt := 3\n\tprintln(t)\n}\n')!
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	buffer := 'module main\n\nfn main() {\n\tp := 10\n\tprintln(p)\n}\n'
	app.open_files[uri] = buffer
	app.v3_line_info(.hover, uri, path, '4:hv^2') or {}
	// An edit, a question about the other program, and the edit undone.
	app.open_files[uri] = buffer.replace('10', '20')
	app.v3_line_info(.hover, path_to_uri(tool), tool, '4:hv^2') or {}
	assert app.v3_copies().len == 2
	app.open_files[uri] = buffer
	app.v3_line_info(.hover, uri, path, '4:hv^2') or {}
	assert fake.asked() == buffer
}

fn test_a_session_that_ends_without_a_shutdown_removes_its_copies() {
	mut app, fake := fake_v3_app('session_end', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	app.v3_line_info(.hover, path_to_uri(path), path, '4:hv^2') or {}
	copy_root := app.v3_copies()[0].overlay.temp_root
	assert os.is_dir(copy_root)
	// The client goes away without a word.
	no_requests := os.join_path(fake.dir, 'no_requests.txt')
	os.write_file(no_requests, '')!
	mut input := os.open(no_requests)!
	defer {
		input.close()
	}
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.capture_output = true
	app.handle_requests(mut reader)
	assert !os.exists(copy_root)
}

fn check_in_background(mut pool DiagnosticsServerPool, exe string, dir string, done chan bool) {
	pool.check(exe, ['-check', '.'], dir, fn () bool {
		return false
	}, unsafe { nil }) or {}
	done <- true
}

const fake_server_waiting_for_release = r"#!/bin/sh
here=$(dirname $0)
echo v-diagnostics-server: ready
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	echo v-diagnostics-server: child 1 $token
	touch $here/started
	while [ ! -f $here/release ]; do sleep 0.01; done
	if [ -f source.v ]; then echo kept; else echo missing; fi
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

fn delayed_pool_query(mut pool DiagnosticsServerPool, exe string, dir string, done chan os.Result) {
	result := pool.query(exe, ['-check', '.'], dir, 'source.v:1:hv^1') or {
		os.Result{
			exit_code: -99
		}
	}
	done <- result
}

fn test_stopping_a_pool_retires_active_servers_without_removing_their_files() {
	dir := os.join_path(os.vtmp_dir(), 'vls_pool_shutdown_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	exe := os.join_path(dir, 'v')
	os.write_file(exe, fake_server_waiting_for_release)!
	os.chmod(exe, 0o755)!
	mut pool := new_diagnostics_server_pool()
	defer {
		pool.stop_all()
	}
	os.mkdir_all(pool.base)!
	os.write_file(os.join_path(pool.base, 'source.v'), 'module main\n')!
	done := chan os.Result{cap: 1}
	spawn delayed_pool_query(mut pool, exe, pool.base, done)
	started := os.join_path(dir, 'started')
	watch := time.new_stopwatch()
	for !os.exists(started) && watch.elapsed() < 5 * time.second {
		time.sleep(5 * time.millisecond)
	}
	was_started := os.exists(started)
	stopping := time.new_stopwatch()
	pool.stop_all()
	waited := stopping.elapsed()
	files_kept := os.is_file(os.join_path(pool.base, 'source.v'))
	// Release the request before assertions so its process always gets reaped.
	os.write_file(os.join_path(dir, 'release'), '')!
	result := <-done
	assert was_started
	assert waited < 500 * time.millisecond, 'stop_all waited ${waited} for the active request'
	assert files_kept
	assert result.exit_code == 0
	assert result.output.trim_space() == 'kept'
	assert !os.exists(pool.base)
	assert pool.servers.len == 0
	// A cancelled worker arriving later cannot start another server.
	late := pool.query(exe, ['-check', '.'], dir, 'source.v:1:hv^1')
	assert late == none
	assert pool.servers.len == 0
}

fn test_stopping_a_pool_keeps_copies_until_their_operation_releases_them() {
	mut pool := new_shared_diagnostics_server_pool()
	admitted := pool.begin_operation()
	assert admitted
	mut program := pool.program_copy('project')
	program.mutex.lock()
	os.mkdir_all(pool.base)!
	pool.stop_all()
	kept := os.is_dir(pool.base)
	late := pool.begin_operation()
	program.mutex.unlock()
	pool.end_operation()
	assert kept
	assert !late
	assert pool.copies.len == 0
	assert !os.exists(pool.base)
}

fn test_a_closed_query_pool_does_not_recreate_a_program_copy() {
	mut app, fake := fake_v3_app('closed_pool', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	mut pool := app.v3_query_pool()
	pool.stop_all()
	path := os.join_path(fake.project, 'main.v')
	answer := app.v3_line_info(.hover, path_to_uri(path), path, '4:hv^2')
	assert answer == none
	assert pool.copies.len == 0
	assert !os.exists(pool.base)
	assert fake.questions().len == 0
}

// Closing stdin does not end a process. Its pipe must be allowed to fail even
// when the preceding is_alive check says the compiler is still running.
const fake_server_closing_stdin = r"#!/bin/sh
exec 0<&-
echo v-diagnostics-server: ready
sleep 1
"

fn test_a_closed_compiler_input_falls_back_and_stops_without_sigpipe() {
	dir := os.join_path(os.vtmp_dir(), 'vls_pool_closed_input_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	exe := os.join_path(dir, 'v')
	os.write_file(exe, fake_server_closing_stdin)!
	os.chmod(exe, 0o755)!
	mut pool := new_diagnostics_server_pool()
	defer {
		pool.stop_all()
	}
	answer := pool.query(exe, ['-check', '.'], dir, 'source.v:1:hv^1')
	assert answer == none
	assert pool.servers.len == 0
	mut server := start_diagnostics_server(exe, [], dir, false, false)!
	server.stop()
	assert server.process == unsafe { nil }
}

const fake_server_with_invalid_child_pid = r"#!/bin/sh
echo v-diagnostics-server: ready
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	echo v-diagnostics-server: child INVALID_PID $token
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

fn test_invalid_child_pids_leave_the_check_to_the_compiler_fallback() {
	dir := os.join_path(os.vtmp_dir(), 'vls_pool_invalid_child_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	exe := os.join_path(dir, 'v')
	// Every server finishes normally and cancellation is disabled: this test
	// must never send a signal to any of these unsafe PID values.
	for pid in ['0', '-1', '2147483648', '4294967297', '999999999999999999999999', '12oops', '+2',
		'1_2', ''] {
		os.write_file(exe, fake_server_with_invalid_child_pid.replace('INVALID_PID', pid))!
		os.chmod(exe, 0o755)!
		mut pool := new_diagnostics_server_pool()
		answer := pool.check(exe, ['-check', '.'], dir, fn () bool {
			return false
		}, unsafe { nil })
		pool.stop_all()
		assert answer == none, 'the diagnostics server accepted child PID `${pid}`'
	}
	for pid in ['1', '2147483647'] {
		os.write_file(exe, fake_server_with_invalid_child_pid.replace('INVALID_PID', pid))!
		mut pool := new_diagnostics_server_pool()
		answer := pool.check(exe, ['-check', '.'], dir, fn () bool {
			return false
		}, unsafe { nil })
		pool.stop_all()
		assert (answer or { panic('a valid child PID was rejected') }).exit_code == 0
	}
}

const fake_server_delaying_cancelled_end = r"#!/bin/sh
here=$(dirname $0)
echo v-diagnostics-server: ready
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	sleep 20 &
	child=$!
	echo v-diagnostics-server: child $child $token
	echo $$ > $here/pid
	touch $here/started
	wait $child
	sleep 1
	printf '\nv-diagnostics-server: end 137 %s\n' $token
done
"

fn test_session_shutdown_joins_the_cancelled_diagnostics_worker() {
	mut app, fake := fake_v3_app('joined_shutdown', fake_server_delaying_cancelled_end, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	mut scheduler := new_diagnostics_scheduler()
	app.diagnostics_scheduler = scheduler
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	content := os.read_file(path)!
	app.open_files[uri] = content
	scheduled := app.schedule_diagnostics(uri, content)
	started := os.join_path(fake.server, 'started')
	watch := time.new_stopwatch()
	for !os.exists(started) && watch.elapsed() < 5 * time.second {
		time.sleep(5 * time.millisecond)
	}
	was_started := os.exists(started)
	pid := (os.read_file(os.join_path(fake.server, 'pid')) or { '0' }).trim_space().int()
	app.stop_diagnostics_servers()
	assert scheduled
	assert was_started
	assert pid > 0
	assert C.kill(pid, 0) != 0, 'the session returned while its compiler was alive'
	assert !scheduler.worker_running
	assert !os.exists(scheduler.servers.base)
}

const fake_one_shot_check_waiting_forever = r"#!/bin/sh
case ${V_DIAGNOSTICS_SERVER}x in 1x) exit 0 ;; esac
here=$(dirname $0)
echo $$ > $here/pid
touch $here/started
exec sleep 20
"

fn test_session_shutdown_cancels_a_one_shot_diagnostics_fallback() {
	mut app, fake := fake_v3_app('joined_fallback', fake_one_shot_check_waiting_forever, 'VLS_V_COMMAND')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	mut scheduler := new_diagnostics_scheduler()
	app.diagnostics_scheduler = scheduler
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	content := os.read_file(path)!
	app.open_files[uri] = content
	scheduled := app.schedule_diagnostics(uri, content)
	started := os.join_path(fake.server, 'started')
	watch := time.new_stopwatch()
	for !os.exists(started) && watch.elapsed() < 5 * time.second {
		time.sleep(5 * time.millisecond)
	}
	was_started := os.exists(started)
	pid := (os.read_file(os.join_path(fake.server, 'pid')) or { '0' }).trim_space().int()
	stopping := time.new_stopwatch()
	app.stop_diagnostics_servers()
	assert scheduled
	assert was_started
	assert stopping.elapsed() < 3 * time.second, 'shutdown waited for the compiler timeout'
	assert pid > 0
	assert C.kill(pid, 0) != 0
	assert !scheduler.worker_running
	assert !os.exists(scheduler.servers.base)
}

fn test_a_question_does_not_wait_for_the_check_of_another_server() {
	// A hover asks the server of its command line while the server of the
	// program's checks is busy: it must not wait for that check.
	dir := os.join_path(os.vtmp_dir(), 'vls_pool_concurrency_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	exe := os.join_path(dir, 'v')
	os.write_file(exe, fake_slow_check_server)!
	os.chmod(exe, 0o755)!
	mut pool := new_diagnostics_server_pool()
	defer {
		pool.stop_all()
	}
	query_args := ['-w', '-check', '.']
	pool.query(exe, query_args, dir, 'main.v:1:hv^1') or { assert false, 'no answer' }
	done := chan bool{cap: 1}
	spawn check_in_background(mut pool, exe, dir, done)
	time.sleep(300 * time.millisecond)
	sw := time.new_stopwatch()
	pool.query(exe, query_args, dir, 'main.v:1:hv^1') or { assert false, 'no answer' }
	waited := sw.elapsed()
	_ := <-done
	assert waited < time.second, 'the question waited ${waited} for the check of another server'
}

fn test_a_request_that_asks_no_compiler_does_not_wait_for_one_that_does() {
	// After a change an editor asks for the semantic tokens and the hover at the
	// cursor at once: the tokens, which the compiler plays no part in, come
	// first, though the hover was asked before them.
	mut app, fake := fake_v3_app('request_order', fake_slow_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	text := os.read_file(path)!
	messages := [
		'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"${path_to_uri(fake.project)}","capabilities":{}}}',
		'{"jsonrpc":"2.0","method":"initialized","params":{}}',
		'{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"${uri}","languageId":"v","version":1,"text":${json2.encode(text)}}}}',
		'{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"${uri}"},"position":{"line":3,"character":1}}}',
		'{"jsonrpc":"2.0","id":3,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"${uri}"}}}',
		'{"jsonrpc":"2.0","id":4,"method":"shutdown"}',
		'{"jsonrpc":"2.0","method":"exit"}',
	]
	input_path := os.join_path(fake.dir, 'requests.txt')
	os.write_file(input_path, messages.map('Content-Length: ${it.len}\r\n\r\n${it}').join(''))!
	mut input := os.open(input_path)!
	defer {
		input.close()
	}
	mut reader := io.new_buffered_reader(reader: input, cap: 1)
	app.capture_output = true
	app.handle_requests(mut reader)
	mut order := []string{}
	for message in app.captured_output {
		if message.contains('"id":2,') {
			order << 'hover'
		} else if message.contains('"id":3,') {
			order << 'tokens'
		}
	}
	assert order == ['tokens', 'hover'], order.str()
}

// A diagnostics server that writes V_DIAGNOSTICS_PREPARE, as it got it, next to
// itself.
const fake_server_noting_prepare = r"#!/bin/sh
here=$(dirname $0)
echo x${V_DIAGNOSTICS_PREPARE} > $here/prepare.txt
echo v-diagnostics-server: ready
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	echo v-diagnostics-server: child 1 $token
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

fn test_the_servers_of_the_diagnostics_and_of_the_questions_prepare_builtin() {
	dir := os.join_path(os.vtmp_dir(), 'vls_v3_prepare_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	exe := os.join_path(dir, 'v')
	os.write_file(exe, fake_server_noting_prepare)!
	os.chmod(exe, 0o755)!
	mut scheduler := new_diagnostics_scheduler()
	defer {
		scheduler.servers.stop_all()
	}
	scheduler.servers.check(exe, ['-check', '-nocolor', '.'], dir, fn () bool {
		return false
	}, unsafe { nil }) or {}
	assert os.read_file(os.join_path(dir, 'prepare.txt'))!.trim_space() == 'x1'
	os.rm(os.join_path(dir, 'prepare.txt'))!
	mut app := App{}
	defer {
		app.v3_query_pool().stop_all()
	}
	app.v3_query_pool().query(exe, ['-w', '-check', '-nocolor', '.'], dir, 'main.v:1:hv^1') or {}
	assert os.read_file(os.join_path(dir, 'prepare.txt'))!.trim_space() == 'x1'
	// A pool of neither kind leaves it to the compiler.
	mut plain := new_diagnostics_server_pool()
	defer {
		plain.stop_all()
	}
	plain.query(exe, ['-check', '-nocolor', '.'], dir, 'main.v:1:hv^1') or {}
	assert os.read_file(os.join_path(dir, 'prepare.txt'))!.trim_space() == 'x'
}

// A diagnostics server that notes each request with the directory it runs in,
// and when it starts, whether it shares its checks with its questions, and
// answers a question with the answer the test left for it.
const fake_server_noting_requests = r"#!/bin/sh
here=$(dirname $0)
echo start $(pwd) shared=x${V_DIAGNOSTICS_SHARED} >> $here/requests.txt
echo v-diagnostics-server: ready
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	echo $request $(pwd) >> $here/requests.txt
	echo v-diagnostics-server: child 1 $token
	case $request in query) cat $here/answer.txt; echo ;; esac
	printf '\nv-diagnostics-server: end 0 %s\n' $token
done
"

fn test_a_check_and_a_question_about_a_program_share_its_copy_and_its_server() {
	mut app, fake := fake_v3_app('shared_copy', fake_server_noting_requests, 'VLS_DIAGNOSTICS_SERVER')!
	app.diagnostics_scheduler = new_diagnostics_scheduler()
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	uri := path_to_uri(path)
	buffer := 'module main\n\nfn main() {\n\tp := 10\n\tprintln(p)\n}\n'
	app.open_files[uri] = buffer
	// The check of the diagnostics worker, as run_diagnostics_job makes it.
	mut scheduler := app.diagnostics_scheduler or { panic('no scheduler') }
	mut worker := App{
		text:                buffer
		open_files:          app.open_files.clone()
		temp_dir:            app.temp_dir
		diagnostics_enabled: true
		diagnostics_servers: scheduler.servers
		v3_query_servers:    scheduler.servers
	}
	worker.run_v_check(uri, buffer)
	app.v3_line_info(.hover, uri, path, '4:hv^2') or { panic('no answer') }
	requests := os.read_file(os.join_path(fake.server, 'requests.txt'))!.split_into_lines()
	// One server, which shares its checks with its questions, answers both, in
	// one copy of the program.
	assert requests.len == 3, requests.str()
	assert requests[0].starts_with('start ') && requests[0].ends_with(' shared=x1'), requests[0]
	copy_dir := requests[0].all_after('start ').all_before(' shared=')
	assert requests[1] == 'check ${copy_dir}'
	assert requests[2] == 'query ${copy_dir}'
	// The copy holds the buffer.
	assert os.read_file(os.join_path(copy_dir, 'main.v'))! == buffer
}

// A diagnostics server whose check sends the errors it found first, and then
// its whole answer.
const fake_server_with_partial_answers = r"#!/bin/sh
echo v-diagnostics-server: ready
while read -r request rest; do
	case $request in quit) exit 0 ;; esac
	token=${rest%% *}
	echo v-diagnostics-server: child 1 $token
	echo 'main.v:3:5: error: found first'
	printf '\nv-diagnostics-server: partial 1 %s\n' $token
	echo 'main.v:3:5: error: found first'
	echo 'main.v:9:1: notice: found at the end'
	printf '\nv-diagnostics-server: end 1 %s\n' $token
done
"

fn test_a_check_gets_the_partial_answer_of_the_server_first() {
	dir := os.join_path(os.vtmp_dir(), 'vls_partial_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	exe := os.join_path(dir, 'v')
	os.write_file(exe, fake_server_with_partial_answers)!
	os.chmod(exe, 0o755)!
	mut pool := new_diagnostics_server_pool()
	defer {
		pool.stop_all()
	}
	partials := chan os.Result{cap: 2}
	result := pool.check(exe, ['-check', '.'], dir, fn () bool {
		return false
	}, fn [partials] (answer os.Result) {
		partials <- answer
	}) or { panic('no answer') }
	assert partials.len == 1
	partial := <-partials
	assert partial.exit_code == 1
	// Each answer ends with the line before its own marker, as a whole answer
	// does.
	assert partial.output == 'main.v:3:5: error: found first\n'
	// The answer is what came after the partial one.
	assert result.exit_code == 1
	assert result.output == 'main.v:3:5: error: found first\nmain.v:9:1: notice: found at the end\n'
	// Without a callback the partial answer is skipped.
	plain := pool.check(exe, ['-check', '.'], dir, fn () bool {
		return false
	}, unsafe { nil }) or { panic('no answer') }
	assert plain.output == result.output
}

// hover_text_at is what a hover at `line` and `col` of `uri` shows.
fn hover_text_at(mut app App, uri string, line int, col int) string {
	response := app.operation_at_pos(.hover, Request{
		id:     1
		method: 'textDocument/hover'
		params: json2.encode(TextDocumentPositionParams{
			text_document: TextDocumentIdentifier{
				uri: uri
			}
			position:      Position{
				line: line
				char: col
			}
		})
	})
	result := response.result
	if result is Hover {
		return result.contents.value
	}
	return ''
}

const narrowing_source = 'module main

type Number = int | f64

struct Circle {
	r f64
}

struct Square {
	side f64
}

type Shape = Circle | Square

fn half[T Number](x T) f64 {
	\$if T is f64 {
		return x
	}
	return 0.0
}

fn area(s Shape) f64 {
	if s is Circle {
		return s.r
	}
	return 0.0
}

fn double(y int) int {
	return y * 2
}
'

fn test_the_compiler_tells_what_a_value_of_a_type_parameter_or_a_sum_type_is() {
	mut app, fake := fake_v3_app('narrowing', fake_v3_hover_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	os.write_file(os.join_path(fake.server, 'answer.txt'), '{"contents":{"kind":"markdown","value":"```v\\nx f64\\n```"}}')!
	path := os.join_path(fake.project, 'narrowing.v')
	os.write_file(path, narrowing_source)!
	uri := path_to_uri(path)
	app.open_files[uri] = narrowing_source
	lines := narrowing_source.split_into_lines()
	// `x` of `half[T Number]` in the branch of `$if T is f64 {`: a `$if` can
	// decide `T`, and the compiler says what it is there.
	x_line := lines.index('\t\treturn x')
	assert hover_text_at(mut app, uri, x_line, 9) == '```v\nx f64\n```'
	// `s` of a sum type in the branch of `if s is Circle {`: the compiler too.
	s_line := lines.index('\t\treturn s.r')
	assert hover_text_at(mut app, uri, s_line, 9) == '```v\nx f64\n```'
	// `y int` is the index's to tell: the compiler is not asked.
	asked := fake.questions().len
	y_line := lines.index('\treturn y * 2')
	assert hover_text_at(mut app, uri, y_line, 8) == '```v\ny int\n```'
	assert fake.questions().len == asked
}

fn test_the_index_tells_a_value_of_a_type_parameter_when_the_compiler_cannot() {
	// A compiler that answers no hover: the type written in the signature.
	mut app, fake := fake_v3_app('narrowing_none', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'narrowing.v')
	os.write_file(path, narrowing_source)!
	uri := path_to_uri(path)
	app.open_files[uri] = narrowing_source
	x_line := narrowing_source.split_into_lines().index('\t\treturn x')
	assert hover_text_at(mut app, uri, x_line, 9) == '```v\nx T\n```'
}

const multiline_sum_source = 'module main

struct Circle {
	r f64
}

struct Square {
	side f64
}

// vfmt writes a long sum type with each type on a line of its own.
type Shape2 = Circle
	| Square

fn area2(s Shape2) f64 {
	if s is Circle {
		return s.r
	}
	return 0.0
}

fn perimeter(s Shape2) f64 {
	s.
	return 0.0
}
'

fn test_a_sum_type_written_on_several_lines_is_a_sum_type() {
	mut app, fake := fake_v3_app('multiline_sum', fake_v3_hover_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	os.write_file(os.join_path(fake.server, 'answer.txt'), '{"contents":{"kind":"markdown","value":"```v\\ns main.Circle\\n```"}}')!
	path := os.join_path(fake.project, 'shapes.v')
	os.write_file(path, multiline_sum_source)!
	uri := path_to_uri(path)
	app.open_files[uri] = multiline_sum_source
	lines := multiline_sum_source.split_into_lines()
	// `s` in the branch of `if s is Circle {`: the compiler tells, as for a sum
	// type written on one line.
	assert hover_text_at(mut app, uri, lines.index('\t\treturn s.r'), 9) == '```v\ns main.Circle\n```'
	// `s.`: what a value of a sum type has, not the fields of its first type.
	dot := lines.index('\ts.')
	labels := app.indexed_completions(uri, Position{
		line: dot
		char: 3
	}).items.map(it.label)
	assert 'r' !in labels, labels.str()
	assert 'type_name' in labels, labels.str()
}
