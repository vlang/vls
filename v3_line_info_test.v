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
	echo $questions >> $(dirname $0)/questions.txt
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

const fake_hover_answer = '{"contents":{"kind":"markdown","value":"```v\\nfake\\n```"}}'

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
	copy_root := app.v3_query_projects.values()[0].overlay.temp_root
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
	copy_of_helper := os.join_path(app.v3_query_projects.values()[0].overlay.temp_root, 'helper', 'helper.v')
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
	copy_root := app.v3_query_projects.values()[0].overlay.temp_root
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
	project := app.v3_query_projects.values()[0]
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
	assert fake.questions() == ['${os.join_path(app.v3_query_projects.values()[0].overlay.temp_root, 'main.v')}:4:hv^2']
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

fn test_only_a_created_or_deleted_file_rebuilds_the_copy() {
	mut app, fake := fake_v3_app('watcher', fake_v3_query_server, 'VLS_DIAGNOSTICS_SERVER')!
	defer {
		stop_fake_v3_app(mut app, fake)
	}
	path := os.join_path(fake.project, 'main.v')
	app.v3_line_info(.hover, path_to_uri(path), path, '4:hv^2') or {}
	assert app.v3_query_projects.len == 1
	// A change shows through the copy.
	app.v3_query_notice_disk_change(path, 2)
	assert app.v3_query_projects.len == 1
	// A new file is not in it.
	app.v3_query_notice_disk_change(os.join_path(fake.project, 'new.v'), 1)
	assert app.v3_query_projects.len == 0
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
	copy_root := app.v3_query_projects.values()[0].overlay.temp_root
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
	mut server := start_diagnostics_server(exe, [], dir)!
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
	// With the documents as they were, the rename knows where `p` is declared.
	later := fake.questions()[asked..]
	assert !later.any(it.contains(':4:gd^')), later.str()
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
	second_copy := second.v3_query_projects.values()[0].overlay.temp_root
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
	assert app.v3_query_projects.len == 2
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
	copy_root := app.v3_query_projects.values()[0].overlay.temp_root
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
