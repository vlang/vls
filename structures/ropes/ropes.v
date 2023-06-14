// this is a v port of https://github.com/vinzmay/go-rope/blob/master/rope.go
module ropes

[heap]
pub struct Rope {
pub mut:
	value  []rune
	depth  int
	weight int
	length int
	left   &Rope = &Rope(unsafe { nil })
	right  &Rope = &Rope(unsafe { nil })
}

pub fn (r &Rope) is_leaf() bool {
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

fn (r &Rope) safe_depth() int {
	if isnil(r) {
		return 0
	}
	return r.depth
}

pub fn (r &Rope) len() int {
	if isnil(r) {
		return 0
	}
	return r.length
}

// str() has & appended which is annoying ://
pub fn (r &Rope) string() string {
	if isnil(r) {
		return ''
	}
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
		panic('index out of bounds ${idx}/${r.length}')
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
	if isnil(r) || r.len() == 0 {
		return other
	} else if isnil(other) || other.len() == 0 {
		return r
	} else if r.len() + other.len() <= ropes.max_leaf_size {
		return new(r.string() + other.string())
	}

	r_depth := r.safe_depth()
	other_depth := other.safe_depth()
	depth := if r_depth > other_depth { r_depth } else { other_depth }

	return &Rope{
		weight: r.len()
		length: r.len() + other.len()
		depth: depth + 1
		left: r
		right: other
	}
}

pub fn (r &Rope) split(idx int) (&Rope, &Rope) {
	if isnil(r) {
		panic('operation not permitted - rope is nil')
	} else if idx < 0 || idx > r.len() {
		panic('rope split out of bounds ${idx}/${r.len()}')
	}

	if r.is_leaf() {
		return new_from_runes(r.value[..idx]), new_from_runes(r.value[idx..])
	} else if idx == 0 {
		return &Rope{}, r
	} else if idx == r.len() {
		return r, &Rope{}
	} else if idx < r.left.len() {
		left, right := r.left.split(idx)
		return left, right.concat(r.right).rebalance_if_needed()
	} else if idx > r.left.len() {
		left, right := r.right.split(idx - r.left.len())
		return r.left.concat(left).rebalance_if_needed(), right
	} else {
		return r.left, r.right
	}
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
	if len == 0 {
		return r
	} else if isnil(r) {
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

fn (r &Rope) b_internal_report(cur_offset int, start int, end int, mut res []rune) (int, int) {
	if isnil(r) || end <= start {
		return 0, cur_offset
	}

	mut read_cnt, mut offset := 0, cur_offset
	if r.is_leaf() {
		for v in r.value {
			if offset >= end {
				break
			} else if offset >= start {
				res << v
			}
			offset += v.length_in_bytes()
		}
		read_cnt = offset - cur_offset
	} else {
		left_cnt, l_offset := r.left.b_internal_report(offset, start, end, mut res)
		right_cnt, r_offset := r.right.b_internal_report(l_offset, start + left_cnt, end, mut
			res)
		read_cnt += left_cnt + right_cnt
		offset = r_offset
	}

	return read_cnt, offset
}

fn (r &Rope) b_report(start int, end int) []rune {
	mut res := []rune{}
	if end <= start {
		return res
	}

	r.b_internal_report(0, start, end, mut res)

	return res
}

pub fn (r &Rope) substr(start int, end int) string {
	res := r.b_report(start, end)
	return res.string()
}

pub fn (r &Rope) rebalance_if_needed() &Rope {
	if r.is_balanced() || (r.left.safe_depth() - r.right.safe_depth()) < ropes.max_depth {
		return r
	}
	return r.rebalance()
}

pub fn (r &Rope) rebalance() &Rope {
	if r.is_balanced() {
		return r
	}
	mut leaves := []&Rope{}
	get_all_leaves(r, mut leaves)
	return merge(leaves, 0, leaves.len)
}

fn merge(leaves []&Rope, start int, end int) &Rope {
	len := end - start
	match len {
		1 {
			return leaves[start]
		}
		2 {
			return leaves[start].concat(leaves[start + 1])
		}
		else {
			mid := start + len / 2
			return merge(leaves, start, mid).concat(merge(leaves, mid, end))
		}
	}
}

fn get_all_leaves(r &Rope, mut leaves []&Rope) {
	if isnil(r) {
		return
	} else if r.is_leaf() {
		leaves << r
	} else {
		get_all_leaves(r.left, mut leaves)
		get_all_leaves(r.right, mut leaves)
	}
}

pub fn (r &Rope) is_balanced() bool {
	if r.is_leaf() {
		return true
	} else if r.depth >= ropes.fibonnaci.len - 2 {
		return false
	} else {
		return ropes.fibonnaci[r.depth + 2] <= r.length
	}
}

// based on https://github.com/deadpixi/rope/blob/main/rope.go
const max_depth = 64

const max_leaf_size = 4096

const fibonnaci = build_fib()

fn build_fib() []int {
	mut fib := []int{len: ropes.max_depth + 3}
	mut first := 0
	mut second := 1
	for c := 0; c < ropes.max_depth + 3; c++ {
		mut next := 0
		if c <= 1 {
			next = c
		} else {
			next = first + second
			first = second
			second = next
		}
		fib[c] = next
	}
	return fib
}
