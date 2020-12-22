module main

type Baz = string
type Bar = string | int

const (
	num = 1
)

interface Speaker {
	speak()
}

enum Color {
	red
	blue
}

struct Foo {}

fn (f Foo) speak() {}
fn main() {}