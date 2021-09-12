module scanner

#include <tree_sitter/parser.h>

type TSSymbol = u16

[typedef]
struct C.TSLexer {
	lookahead rune
	result_symbol TSSymbol
	advance fn (l &C.TSLexer, skip bool)
	mark_end fn (l &C.TSLexer)
	get_column fn (l &C.TSLexer) u32
	is_at_included_range_start fn (l &C.TSLexer) bool
	eof fn (l &C.TSLexer) bool
}

