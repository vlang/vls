#import <tree_sitter/parser.h>
#import <ctype.h>
// #import <stdio.h>

enum TokenType {
    AUTOMATIC_SEPARATOR
};

void *tree_sitter_v_external_scanner_create() {
    return 0;
}

void tree_sitter_v_external_scanner_destroy() {}

void tree_sitter_v_external_scanner_reset() {}

unsigned tree_sitter_v_external_scanner_serialize(void *p, char *buffer) {
    return 0;
}

void tree_sitter_v_external_scanner_deserialize(void *p, char *b, unsigned n) {}

bool tree_sitter_v_external_scanner_scan(void *payload, TSLexer *lexer, bool *valid_symbols) {
    bool is_newline = false;
    int tab_count = 0;

    if (valid_symbols[AUTOMATIC_SEPARATOR]) {
        while (lexer->lookahead == '\r' || lexer->lookahead == '\n' || lexer->lookahead == '\t') {
            if (!is_newline && (lexer->lookahead == '\r' || lexer->lookahead == '\n')) {
                is_newline = true;
            } else if (lexer->lookahead == '\t') {
                tab_count++;
            }

            lexer->advance(lexer, true);
        }

        lexer->mark_end(lexer);

        // true if tab count is 1 or below, false if above 1
        bool needs_to_be_separated = tab_count <= 1;

        // for multi-level blocks. not a good code. should be improved later.
        if (!needs_to_be_separated) {
            switch (lexer->lookahead) {
            case '|':
            case '&':
                needs_to_be_separated = false;
                break;
            default:
                if (isalpha(lexer->lookahead) || lexer->lookahead == '_') {
                    needs_to_be_separated = true;
                }
            }
        }

        // printf("needs_to_be_separated: %d\n", is_newline && needs_to_be_separated);
        return is_newline && needs_to_be_separated;
    }

    return false;
}