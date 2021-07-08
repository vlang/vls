module analyzer

struct TreeCursor {
mut:
	cursor C.TSTreeCursor
}

fn (mut tc TreeCursor) next() bool {
	if !tc.cursor.next() {
		return false
	}

	mut rep := 0
	for (!tc.current_node().is_named() || tc.current_node().has_error()) && rep < 5 {
		if !tc.cursor.next() {
			return false
		}
		
		rep++
	}

	return true
}

fn (mut tc TreeCursor) to_first_child() bool {
	return tc.cursor.to_first_child()
}

fn (tc &TreeCursor) current_node() C.TSNode {
	return tc.cursor.current_node()
}

[unsafe]
fn (tc &TreeCursor) free() {
	unsafe { tc.cursor.free() }
}

pub struct Analyzer {
pub mut:
	cur_file_path string
	cursor  	TreeCursor
	src_text []byte
	store &Store = &Store(0)

	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import bool
}

fn report_error(msg string, range C.TSRange) IError {
	return AnalyzerError{
		msg: msg
		code: 0
		range: range
	}
}

pub fn (mut an Analyzer) unwrap_error(err IError) {
	if err is AnalyzerError {
		an.store.report({ 
			content: err.msg
			range: err.range
			file_path: an.store.cur_file_path.clone()
		})
	}
}

// pub fn (mut store Store) analyze(tree &C.TSTree, src_text []byte) {
// 	mut an := analyzer.Analyzer{}
// 	an.store = unsafe { store }
// 	an.src_text = src_text
// 	child_len := int(root_node.child_count())
// 	an.cursor = TreeCursor{root_node.tree_cursor()}
// 	for _ in 0 .. child_len {
// 		an.top_level_statement()
// 	}
// 	unsafe { an.cursor.free() }
// }
