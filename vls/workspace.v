module vls

// did_change_watched_files executes a list of procedures when one
// of the files is changed. TODO for now.
fn (ls Vls) did_change_watched_files(id int, params string) {
	// TODO Remove, functions can't have two args with name `_`
	_ = ls
	_ = id
	_ = params
}
