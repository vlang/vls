#import <tree_sitter/parser.h>

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

        // true if tab count is 1 or below, false if above 1
        bool needs_to_be_separated = tab_count <= 1;
        return is_newline && needs_to_be_separated;
    }

    return false;
}