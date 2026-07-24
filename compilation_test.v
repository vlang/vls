module main

// This file used to be a no-op (`assert true`). It now exercises a cross-section
// of the server's pure logic so the suite fails loudly if a foundational
// invariant regresses, instead of merely proving the code compiles.

fn test_smoke_uri_roundtrip() {
	original := '/home/user/my project/a#b.v'
	assert uri_to_path(path_to_uri(original)) == original
}

fn test_smoke_incremental_edit_is_lossless() {
	content := 'a\r\nb\r\n'
	updated := apply_incremental_change(content, LSPRange{
		start: Position{
			line: 0
			char: 1
		}
		end:   Position{
			line: 0
			char: 1
		}
	}, 'X')
	// The CRLF terminators must be preserved exactly.
	assert updated == 'aX\r\nb\r\n'
}

fn test_smoke_raw_id_extraction() {
	id := extract_raw_id('{"jsonrpc":"2.0","id":"z-9","method":"initialize"}') or {
		assert false, 'expected id'
		return
	}
	assert id == '"z-9"'
}

fn test_smoke_argv_is_shell_free() {
	// A malicious path stays a single literal argv element (no shell involved).
	malicious := '/tmp/$(touch /tmp/pwned)/x.v'
	args := build_v_check_args_single(malicious)
	assert malicious in args
}
