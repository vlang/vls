module scanner

enum TokenType {
  automatic_separator
}

const automatic_separator = int(TokenType.automatic_separator)

[export: 'tree_sitter_v_external_scanner_create']
fn external_scanner_create() voidptr {
	return 0
}

[export: 'tree_sitter_v_external_scanner_destroy']
fn external_scanner_destroy(p voidptr) {}

[export: 'tree_sitter_v_external_scanner_reset']
fn external_scanner_reset(p voidptr) {}

[export: 'tree_sitter_v_external_scanner_serialize']
fn external_scanner_serialize(p voidptr, buffer &char) u32 {
	return 0
}

[export: 'tree_sitter_v_external_scanner_deserialize']
fn external_scanner_deserialize(p voidptr, b &char, n u32) {}

[export: 'tree_sitter_v_external_scanner_scan']
fn external_scanner_scan(payload voidptr, lexer &C.TSLexer, valid_symbols &bool) bool {
  mut is_newline := false
  mut tab_count := 0

	if unsafe { valid_symbols[automatic_separator] } {
    for lexer.lookahead == `\r` || lexer.lookahead == `\n` || lexer.lookahead == `\t` {
      if !is_newline && (lexer.lookahead == `\r` || lexer.lookahead == `\n`) {
        is_newline = true
      } else if lexer.lookahead == `\t` {
        tab_count++
      }

      lexer.advance(lexer, true)
    }

    // true if tab count is 1 or below, false if above 1
    needs_to_be_separated := tab_count <= 1

    // eprintln('lookahead: ${lexer.lookahead} ${rune(lexer.lookahead).str().bytes()}')
    return is_newline && needs_to_be_separated
	}
	
	return false
}
