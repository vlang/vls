module main

struct Barw {
	name string
}

fn (b Bar) theres_a_method() {}

struct Foow {
	bar Barw
}

fn main() {
  foo := Foow{Barw{}}
  foo.bar.
}