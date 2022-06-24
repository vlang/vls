// a v port of the https://github.com/vinzmay/go-rope/blob/master/rope_test.go test file
import ropes

fn test_rope_creation() ? {
	r := ropes.new('test')
	assert r.str() == 'test'
	assert r.len() == 4
}

fn test_rope_concat() ? {
	r := ropes.new('abcdef')
	r2 := ropes.new('ghilmno')
	r3 := r.concat(r2)
	assert r.str() == 'abcdef'
	assert r.len() == 6
	assert r2.str() == 'ghilmno'
	assert r2.len() == 7
	assert r3.str() == 'abcdefghilmno'
	assert r3.len() == 13
}

fn test_rope_split() ? {
	r := ropes.new('abcdef')
	r1, r2 := r.split(4)
	assert r.str() == 'abcdef'
	assert r.len() == 6
	assert r1.str() == 'abcd'
	assert r1.len() == 4
	assert r2.str() == 'ef'
	assert r2.len() == 2

	assert r.delete(1, 4).string() == 'af'
}

fn test_rope_substr() {
	r := ropes.new('abcdef')
	assert r.substr(0, 4) == 'abcd'
}