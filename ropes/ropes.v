// this is a v port of https://github.com/vinzmay/go-rope/blob/master/rope.go
module ropes

[heap]
pub struct Rope {
pub mut:
	value  []rune
	weight int
	length int
	left   &Rope = &Rope(0)
	right  &Rope = &Rope(0)
}

fn (r &Rope) is_leaf() bool {
	return isnil(r.left)
}

// new returns a new rope initialized with given string.
pub fn new(bootstrap string) &Rope {
	return new_from_runes(bootstrap.runes())
}

pub fn new_from_runes(rn []rune) &Rope {
	return &Rope{
		value: rn
		weight: rn.len
		length: rn.len
	}
}

pub fn (r &Rope) len() int {
	if isnil(r) {
		return 0
	}
	return r.length
}

// str() has & appended which is annoying ://
pub fn (r &Rope) string() string {
	return r.runes().string()
}

pub fn (r &Rope) str() string {
	return r.string()
}

pub fn (r &Rope) runes() []rune {
	return r.report(1, r.length)
}

// at is v equiv of rope.Index(idx)
pub fn (r &Rope) at(idx int) rune {
	if idx < 0 || idx >= r.len() {
		panic('index out of bounds $idx/$r.length')
	}

	if r.is_leaf() {
		return r.value[idx]
	} else if idx >= r.left.len() {
		return r.right.at(idx - r.left.len())
	} else if idx > r.weight {
		return r.right.at(idx - r.weight)
	} else {
		return r.left.at(idx)
	}
}

// + is equiv to Concat()
pub fn (r &Rope) concat(other &Rope) &Rope {
	if isnil(r) {
		return other
	} else if isnil(other) {
		return r
	}

	r_len := if isnil(r) { 0 } else { r.length }
	other_len := if isnil(other) { 0 } else { other.length }

	return &Rope{
		weight: r_len
		length: r_len + other_len
		left: r
		right: other
	}
}

fn (r &Rope) internal_split(idx int, second_rope &Rope) (&Rope, &Rope) {
	if idx == r.weight {
		if r.is_leaf() {
			return r, r.right
		} else {
			return r.left, r.right
		}
	} else if idx > r.weight {
		new_right, new_second_rope := r.right.internal_split(idx - r.weight, second_rope)
		return r.left.concat(new_right), new_second_rope
	} else {
		if r.is_leaf() {
			mut lr := &Rope(0)
			if idx > 0 {
				lr = &Rope{
					weight: idx
					value: r.value[..idx]
					length: idx
				}
			}
			return lr, &Rope{
				weight: r.value.len - idx
				value: r.value[idx..]
				length: r.value.len - idx
			}
		} else {
			new_left, new_second_rope := r.left.internal_split(idx, second_rope)
			return new_left, new_second_rope.concat(r.right)
		}
	}
}

pub fn (r &Rope) split(idx int) (&Rope, &Rope) {
	if isnil(r) {
		panic('operation not permitted - rope is nil')
	} else if idx < 0 || idx > r.len() {
		panic('rope split out of bounds $idx/$r.len()')
	}
	a, b := r.internal_split(idx, &Rope(0))
	return a, b
}

pub fn (r &Rope) insert(idx int, str string) &Rope {
	if isnil(r) {
		return new(str)
	} else if str.len == 0 {
		return r
	}
	r1, r2 := r.split(idx)
	return r1.concat(new(str)).concat(r2)
}

pub fn (r &Rope) delete(idx int, len int) &Rope {
	if isnil(r) {
		panic('operation not permitted - rope is nil')
	}
	r1, r2 := r.split(idx)
	_, r4 := r2.split(len)
	return r1.concat(r4)
}

pub fn (r &Rope) report(idx int, len int) []rune {
	if isnil(r) {
		return []rune{len: 0}
	}
	mut res := []rune{len: len}
	r.internal_report(idx, len, mut res)
	return res
}

fn (r &Rope) internal_report(idx int, len int, mut res []rune) {
	if isnil(r) {
		return
	}

	if idx > r.weight {
		r.right.internal_report(idx - r.weight, len, mut res)
	} else if r.weight >= idx + len - 1 {
		if r.is_leaf() {
			mut left_idx := 0
			mut right_idx := idx - 1
			for left_idx < res.len {
				res[left_idx] = r.value[right_idx]
				right_idx++
				left_idx++
			}
		} else {
			r.left.internal_report(idx, len, mut res)
		}
	} else {
		r.left.internal_report(idx, r.weight - idx + 1, mut res[..r.weight])
		r.right.internal_report(idx, len - r.weight + idx - 1, mut res[r.weight..])
	}
}

pub fn (r &Rope) substr(start int, end int) string {
	len := end - start
	if start < 1 {
		r.report(1, len)
	}
	if start + len - 1 > r.length {
		r.report(start, r.length - start + 1)
	}
	_, r1 := r.split(start)
	r2, _ := r1.split(len)
	return r2.string()
}

// taken from https://github.com/zyedidia/rope/blob/master/rope.go
const rebalance_ratio = 1.2
const split_len = 4096 * 4
// const join_len = split_len / 2

fn (r &Rope) rebuild() &Rope {
	if isnil(r) || r.is_leaf() {
		return r
	}

	mut new_value := []rune{cap: r.left.len() + r.right.len()}
	new_value << r.left.runes()
	new_value << r.right.runes()
	new_rope := new_from_runes(new_value)
	if new_rope.len() > split_len {
		middle := new_value.len / 2
		left, right := new_rope.split(middle)
		return left.concat(right)
	}
	return new_rope
}

pub fn (r &Rope) rebalance() &Rope {
	if isnil(r) || r.is_leaf() {
		return r
	}
	left_ratio := f64(r.left.len()) / f64(r.right.len())
	right_ratio := f64(r.right.len()) / f64(r.left.len())
	if left_ratio > rebalance_ratio || right_ratio > rebalance_ratio {
		return r.rebuild()
	} else {
		return r.left.rebalance().concat(r.right.rebalance())
	}
}