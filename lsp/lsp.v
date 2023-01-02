module lsp

import os

type DocumentUri = string

pub fn (du DocumentUri) dir() string {
	return os.dir(du)
}

pub fn (du DocumentUri) path() string {
	scheme := 'file://'
	if !du.starts_with(scheme) {
		return ''
	}

	mut authority := du.all_after(scheme).all_before('/')
	mut path := du.all_after(scheme).all_after('/')

	authority = unescape(authority)
	path = unescape(path)

	mut result := ''
	$if windows {
		if authority != '' && path != '' {
			result = '//${authority}/${path}'
		} else if path[0].is_letter() && path[1] == `:` {
			// convert driver name to upper case
			drive_name := if path[0].is_capital() {
				path[0]
			} else {
				path[0] - 32
			}

			result = rune(drive_name).str() + path[1..]
		} else {
			result = path
		}

		result = result.replace('/', '\\')
	} $else {
		result = '/' + path
	}

	return result
}

pub fn (du DocumentUri) dir_path() string {
	return os.dir(du.path())
}

pub fn (du DocumentUri) normalize() DocumentUri {
	return document_uri_from_path(du.path())
}

fn escape(s string) string {
	byte_array := s.bytes()

	return byte_array.map(if it.is_alnum() || it in [`-`, `.`, `_`, `~`, `/`] {
		rune(it).str()
	} else {
		'%${it:02X}'
	})
		.join('')
}

fn unescape(s string) string {
	rune_array := s.runes()
	mut results := []u8{}

	for i := 0; i < rune_array.len; i++ {
		if rune_array[i] != `%` {
			results << rune_array[i].bytes()
		} else {
			v1_rune := rune_array[i + 1] or { `\0` }
			v2_rune := rune_array[i + 2] or { `\0` }

			v1 := try_into_hex_int(v1_rune) or {
				results << rune_array[i].bytes()
				continue
			}
			v2 := try_into_hex_int(v2_rune) or {
				results << rune_array[i].bytes()
				continue
			}
			v := (v1 << 4) + v2

			results << v
			i += 2
		}
	}

	return results.bytestr()
}

fn try_into_hex_int(r rune) ?rune {
	return if r >= `0` && r <= `9` {
		r - `0`
	} else if r >= `A` && r <= `F` {
		r - `A` + 10
	} else if r >= `a` && r <= `f` {
		r - `a` + 10
	} else {
		none
	}
}

pub fn document_uri_from_path(path string) DocumentUri {
	scheme := 'file://'
	is_has_scheme := path.starts_with(scheme)

	mut fixed_path := if is_has_scheme {
		path.all_after(scheme)
	} else {
		path
	}

	mut authority := ''
	$if windows {
		fixed_path = fixed_path.replace('\\', '/')

		// UNC paths for accessing network resources
		if !is_has_scheme && fixed_path.starts_with('//') {
			authority = fixed_path.find_between('//', '/')
			fixed_path = fixed_path.all_after('//').all_after('/')
			if fixed_path == '' {
				fixed_path = '/'
			}
		}
	}

	mut is_need_prepend_slash := false
	$if windows {
		// paths start with '/' without specifying drive name are paths
		// relative to root of current drive.
		// an extra '/' needs to be prepended.
		is_need_prepend_slash = !fixed_path.starts_with('/')
			|| (fixed_path[1] != `/` && fixed_path[2] != `:`)
	} $else {
		is_need_prepend_slash = !fixed_path.starts_with('/')
	}

	if is_need_prepend_slash {
		fixed_path = '/' + fixed_path
	}

	$if windows {
		// convert driver name to lower case, e.g. /C:/foo ->  /c:/foo
		if fixed_path[2] == `:` && fixed_path[1].is_letter() {
			driver_name := if fixed_path[1].is_capital() {
				fixed_path[1] + 32
			} else {
				fixed_path[1]
			}
			fixed_path = '/${rune(driver_name).str()}${fixed_path[2..]}'
		}
	}

	uri := scheme + escape(authority) + escape(fixed_path)
	return uri
}

pub struct NotificationMessage {
	method string
	params string [raw]
}

// // method: $/cancelRequest
pub struct CancelParams {
	id int
}

pub struct Command {
	title     string
	command   string
	arguments []string
}

pub struct DocumentFilter {
	language string
	scheme   string
	pattern  string
}

pub struct TextDocumentRegistrationOptions {
	document_selector []DocumentFilter [json: documentSelector]
}
