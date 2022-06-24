module analyzer

pub type Runes = []rune

pub fn (r Runes) at(idx int) rune {
	return r[idx]
}

pub fn (r Runes) len() int {
	return r.len
}

pub fn (r Runes) substr(start_index int, end_index int) string {
	return r[start_index .. end_index].string()
}