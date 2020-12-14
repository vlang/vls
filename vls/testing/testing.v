module testing

pub struct Testio {
pub mut:
	response string
}

pub fn (mut io Testio) send(data string) {
	io.response = data
}
