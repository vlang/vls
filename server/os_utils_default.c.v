module server

const (
	v_exec_name   = 'v'
	path_list_sep = ':'
)

fn is_proc_exists(pid int) bool {
	errno_ := C.kill(pid, 0)
	// if errno_ != C.ESRCH {
	if errno_ == 0 {
		return true
	}
	return false
}
