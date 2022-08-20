module abc

pub struct Point {
pub:
	a int
	b int
}

pub fn this_is_a_function() string {
	return 'wee'
}

pub enum KeyCode {
	shift
	control
}

pub fn (code KeyCode) print() {}
