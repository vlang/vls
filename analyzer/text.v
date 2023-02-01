module analyzer

pub type Runes = []rune

pub fn (r Runes) at(idx int) rune {
	return r[idx]
}

pub fn (r Runes) len() int {
	return r.len
}

pub fn (r Runes) substr(start_index int, end_index int) string {
	mut st, mut ed := -1, -1
	mut offset := 0
	for i, v in r {
		if offset >= end_index {
			ed = i
			break
		} else if offset >= start_index && st < 0 {
			st = i
		}
		offset += v.length_in_bytes()
	}

	if ed < 0 {
		ed = r.len
	}

	return r[st..ed].string()
}
