#include <tree_sitter/parser.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>

enum TokenType {
    AUTOMATIC_SEPARATOR,
    BRACED_INTERPOLATION_OPENING,
    UNBRACED_INTERPOLATION_OPENING,
    INTERPOLATION_CLOSING,
    C_STRING_OPENING, // = 4
    RAW_STRING_OPENING, // = 5
    STRING_OPENING, // = 6
    STRING_CONTENT,
    STRING_CLOSING,
    COMMENT,
    NONE
};

enum StringType {
    SINGLE_QUOTE = NONE + 1, // = 9 + 1 + 1 = 11
    DOUBLE_QUOTE = NONE + 4, // = 9 + 1 + 4 = 14
};

enum StringTokenType {
    C_SINGLE_QUOTE_OPENING = C_STRING_OPENING + SINGLE_QUOTE, // 5 + 11 = 16
    C_DOUBLE_QUOTE_OPENING = C_STRING_OPENING + DOUBLE_QUOTE, // 5 + 14 = 19
    RAW_SINGLE_QUOTE_OPENING = RAW_STRING_OPENING + SINGLE_QUOTE, // 4 + 11 = 15
    RAW_DOUBLE_QUOTE_OPENING = RAW_STRING_OPENING + DOUBLE_QUOTE, // 4 + 14 = 18
    SINGLE_QUOTE_OPENING = STRING_OPENING + SINGLE_QUOTE, // 6 + 11 = 17 
    DOUBLE_QUOTE_OPENING = STRING_OPENING + DOUBLE_QUOTE // 6 + 14 = 20
};

bool is_type_single_quote(uint8_t type) {
    uint8_t orig_type = type - SINGLE_QUOTE;
    return orig_type >= C_STRING_OPENING && orig_type <= STRING_OPENING;
}

bool is_type_double_quote(uint8_t type) {
    uint8_t orig_type = type - DOUBLE_QUOTE;
    return orig_type >= C_STRING_OPENING && orig_type <= STRING_OPENING;
}

bool is_type_string(uint8_t type) {
    return is_type_single_quote(type) || is_type_double_quote(type);
}

uint8_t get_final_string_type(uint8_t type) {
    if (is_type_single_quote(type)) {
        return type - SINGLE_QUOTE;
    } else if (is_type_double_quote(type)) {
        return type - DOUBLE_QUOTE;
    } else {
        return type;
    }
}

char expected_end_char(uint8_t type) {
    if (is_type_single_quote(type)) {
        return '\'';
    } else if (is_type_double_quote(type)) {
        return '"';
    } else if (type == BRACED_INTERPOLATION_OPENING) {
        return '}';
    } else {
        return '\0';
    }
}

// Stack
typedef struct {
    int top;
    int init_size;
    uint8_t *contents;
} Stack;

Stack *new_stack(int init_size) {
    Stack *stack = malloc(sizeof(Stack));
    stack->top = -1;
    stack->init_size = init_size;
    stack->contents = malloc(sizeof(uint8_t) * (init_size + 1));
    return stack;
}

void stack_push(Stack *stack, uint8_t content) {
    if (stack->top < stack->init_size) {
        stack->contents[++stack->top] = content;
    }
}

uint8_t stack_top(Stack *stack) {
    if (stack->top >= 0) {
        return stack->contents[stack->top];
    }
    // if stack is at -1;
    return NONE;
}

uint8_t stack_pop(Stack *stack) {
    if (stack->top >= 0) {
        uint8_t current_top = stack_top(stack);
        stack->contents[stack->top--] = NONE;
        return current_top;
    }
    // if stack is at -1;
    return NONE;
}

bool stack_empty(Stack *stack) {
    return stack->top == -1;
}

void stack_serialize(Stack *stack, char *buffer, unsigned *n) {
    int size = stack->top + 1;
    unsigned i = *n;
    buffer[i++] = stack->top;
    buffer[i++] = stack->init_size;
    if (size > 0) {
        memcpy(&buffer[i], stack->contents, size);
        i += size;
    }
}

void stack_deserialize(Stack *stack, const char *buffer, unsigned *n, unsigned len) {
    if (len == 0) return;
    memset(stack->contents, 0, stack->init_size * sizeof(*stack->contents));
    stack->top = buffer[(*n)++];
    stack->init_size = buffer[(*n)++];
    int size = stack->top + 1;
    if (size > 0) {
        memcpy(stack->contents, &buffer[*n], size);
        (*n) += size;
    }
}

// Utils
void tsv_advance(TSLexer *lexer) {
    lexer->advance(lexer, false);
}

void ts_skip(TSLexer *lexer) {
    lexer->advance(lexer, true);
}

bool is_separatable(char c) {
    return c == '\r' || c == '\n' || c == '\t';
}

// Scanner
typedef struct {
    bool initialized;
    Stack *tokens;
} Scanner;

void push_type(Scanner *scanner, uint8_t token_type) {
    stack_push(scanner->tokens, token_type);
}

bool scan_interpolation_opening(Scanner *scanner, TSLexer *lexer) {
    if (lexer->lookahead != '$') {
        return false;
    }

    tsv_advance(lexer);
    uint8_t got_top = stack_top(scanner->tokens);
    if (is_type_string(got_top) && lexer->lookahead == expected_end_char(got_top)) {
        return false;
    }

    bool is_valid = false;
    bool is_braced = false;
    if (lexer->lookahead == '{') {
        tsv_advance(lexer);
        is_valid = true;
        is_braced = true;
    } else if (isalpha(lexer->lookahead)) {
        // hopefully resolves issues regarding '$r' or '$c' 
        is_valid = true;
    } else {
        switch (lexer->lookahead) {
            // just marked it here
            case '$':
            case '%':
            case '(':
            case '\\':
                is_valid = false;
        }
    }

    if (is_valid) {
        lexer->mark_end(lexer);
        if (is_braced) {
            lexer->result_symbol = BRACED_INTERPOLATION_OPENING;
            push_type(scanner, lexer->result_symbol);
        } else {
            lexer->result_symbol = UNBRACED_INTERPOLATION_OPENING;
        }
    }

    return is_valid;
}

bool scan_interpolation_closing(Scanner *scanner, TSLexer *lexer) {
    uint8_t got_top = stack_pop(scanner->tokens);
    bool has_braced_closing = got_top == BRACED_INTERPOLATION_OPENING && lexer->lookahead == expected_end_char(got_top);
    if (has_braced_closing || got_top == UNBRACED_INTERPOLATION_OPENING) {
        if (has_braced_closing) {
            tsv_advance(lexer);
        }

        lexer->result_symbol = INTERPOLATION_CLOSING;
        return true;
    }
    return false;
}

bool scan_automatic_separator(Scanner *scanner, TSLexer *lexer) {
    bool is_newline = false;
    bool has_whitespace = false;
    int tab_count = 0;

    while (is_separatable(lexer->lookahead)) {
        if (!has_whitespace) {
            has_whitespace = true;
        }

        if (lexer->lookahead == '\r') {
            tsv_advance(lexer);
            lexer->mark_end(lexer);
        }

        if (!is_newline && lexer->lookahead == '\n') {
            is_newline = true;
        } else if (lexer->lookahead == '\t') {
            tab_count++;
        }

        tsv_advance(lexer);
        lexer->mark_end(lexer);
    }

    // true if tab count is 1 or below, false if above 1
    bool needs_to_be_separated = tab_count <= 1;

    // for multi-level blocks. not a good code. should be improved later.
    if (has_whitespace) {
        char got_char = lexer->lookahead; 
        switch (got_char) {
        case '|':
        case '&':
            tsv_advance(lexer);
            if (lexer->lookahead == got_char || !isalpha(lexer->lookahead)) {
                needs_to_be_separated = false;
            } else {
                needs_to_be_separated = true;
            }
            break;
        case '*':
        case '_':
        case '\'':
        case '"':
            needs_to_be_separated = true;
            break;
        case '/':
            tsv_advance(lexer);
            if (lexer->lookahead == got_char || lexer->lookahead == '*') {
                needs_to_be_separated = true;
            } else {
                needs_to_be_separated = false;
            }
        default:
            if (isalpha(lexer->lookahead)) {
                needs_to_be_separated = true;
            }
            break;
        }
    }

    if (is_newline && needs_to_be_separated) {
        lexer->result_symbol = AUTOMATIC_SEPARATOR;
        return true;
    }

    return false;
}

bool scan_string_opening(Scanner *scanner, TSLexer *lexer, bool is_quote, bool is_c, bool is_raw) {
    if (is_raw && lexer->lookahead == 'r') {
        lexer->result_symbol = RAW_STRING_OPENING;
        tsv_advance(lexer);
    } else if (is_c && lexer->lookahead == 'c') {
        lexer->result_symbol = C_STRING_OPENING;
        tsv_advance(lexer);
    } else if (is_quote && (lexer->lookahead == '\'' || lexer->lookahead == '"')) {
        lexer->result_symbol = STRING_OPENING;
    } else {
        return false;
    }

    if (lexer->lookahead == '\'' || lexer->lookahead == '"') {
        uint8_t string_type = lexer->lookahead == '\'' ? SINGLE_QUOTE : DOUBLE_QUOTE;

        tsv_advance(lexer);
        lexer->mark_end(lexer);
        
        push_type(scanner, lexer->result_symbol + string_type);

        return true;
    }

    return false;
}

bool scan_string_content(Scanner *scanner, TSLexer *lexer) {
    uint8_t got_top = stack_top(scanner->tokens);
    if (stack_empty(scanner->tokens) || !is_type_string(got_top)) {
        return false;
    }

    lexer->result_symbol = STRING_CONTENT;
    bool is_raw = get_final_string_type(got_top) == RAW_STRING_OPENING;
    bool has_content = false;
    char quote_to_skip = expected_end_char(got_top);

    for (; ; has_content = true) {
        lexer->mark_end(lexer);

        if (lexer->lookahead == '\0' || lexer->lookahead == quote_to_skip) {
            return has_content;
        }

        if (!is_raw && (lexer->lookahead == '\\' || lexer->lookahead == '$')) {
            return has_content;
        }

        tsv_advance(lexer);
    }

    return has_content;
}

bool scan_string_closing(Scanner *scanner, TSLexer *lexer) {
    uint8_t got_top = stack_pop(scanner->tokens);
    if (is_type_string(got_top) && lexer->lookahead == expected_end_char(got_top)) {
        tsv_advance(lexer);
        lexer->result_symbol = STRING_CLOSING;
        return true;
    }

    return false;
}

bool scan_comment(Scanner *scanner, TSLexer *lexer) {
    uint8_t got_top = stack_top(scanner->tokens);
    if (is_type_string(got_top) || lexer->lookahead != '/') {
        return false;
    }

    tsv_advance(lexer);
    if (lexer->lookahead != '/' && lexer->lookahead != '*') {
        return false;
    }

    bool is_multiline = lexer->lookahead == '*';
    int nested_multiline_count = 0;
    tsv_advance(lexer);

    while (true) {
        lexer->mark_end(lexer);
        if (is_multiline) {
            if (lexer->lookahead == '/') {
                // Handles the "nested" comments (e.g. /* /* comment */ */)
                tsv_advance(lexer);
                if (lexer->lookahead == '*') {
                    tsv_advance(lexer);
                    lexer->mark_end(lexer);
                    nested_multiline_count++;
                }

                continue;
            } else if (lexer->lookahead == '*') {
                tsv_advance(lexer);
                if (lexer->lookahead == '/') {
                    tsv_advance(lexer);
                    lexer->mark_end(lexer);
                    if (nested_multiline_count == 0) {
                        break;
                    } else {
                        nested_multiline_count--;
                    }
                }

                // do mark_end first before advancing
                continue;
            }
        } else if (!is_multiline && (lexer->lookahead == '\r' || lexer->lookahead == '\n')) {
            break;
        } 
        
        if (lexer->lookahead == '\0') {
            break;
        }

        tsv_advance(lexer);
    }

    lexer->result_symbol = COMMENT;
    return true;
}

// Tree-Sitter external scanner functions
void *tree_sitter_v_external_scanner_create() {
    Scanner *scanner = malloc(sizeof(Scanner));
    scanner->initialized = true;
    scanner->tokens = new_stack(10);
    return scanner;
}

void tree_sitter_v_external_scanner_destroy(void *p) {
    Scanner *scanner = (Scanner*) p;
    if (scanner->tokens->top + 1 > 0) {
        free(scanner->tokens->contents);
    }
    free(scanner->tokens);
    free(scanner);
}

unsigned tree_sitter_v_external_scanner_serialize(void *p, char *buffer) {
    unsigned i = 0;
    Scanner *scanner = (Scanner*) p;
    stack_serialize(scanner->tokens, buffer, &i);
    return i;
}

void tree_sitter_v_external_scanner_deserialize(void *p, const char *buffer, unsigned n) {
    Scanner *scanner = (Scanner*) p;
    if (n > 0){
        unsigned i = 0;
        scanner->initialized = true;
        stack_deserialize(scanner->tokens, buffer, &i, n);
    } else {
        scanner->initialized = false;
    }
}

bool tree_sitter_v_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    if (lexer->lookahead == 0) {
        // tsv_advance(lexer);
        return false;
    }
    
    Scanner *scanner = (Scanner*) payload;
    bool is_stack_empty = stack_empty(scanner->tokens);
    uint8_t top = stack_top(scanner->tokens);

    if (is_separatable(lexer->lookahead) && valid_symbols[AUTOMATIC_SEPARATOR] && is_stack_empty) {
        return scan_automatic_separator(scanner, lexer);
    } else if (is_stack_empty || top == BRACED_INTERPOLATION_OPENING) {
        while (lexer->lookahead == ' ' || is_separatable(lexer->lookahead)) {
            // skip only if whitespace
            lexer->advance(lexer, true);
        }
    }

    if (!is_type_string(top) && lexer->lookahead == '/' && valid_symbols[COMMENT]) {
        return scan_comment(scanner, lexer);
    }

    if (
        (
            top == BRACED_INTERPOLATION_OPENING 
            || top == UNBRACED_INTERPOLATION_OPENING
            || is_stack_empty
        ) && (
            valid_symbols[C_STRING_OPENING] 
            || valid_symbols[RAW_STRING_OPENING]
            || valid_symbols[STRING_OPENING]
        )
    ) {
        return scan_string_opening(
            scanner, 
            lexer,
            valid_symbols[STRING_OPENING],
            valid_symbols[C_STRING_OPENING],
            valid_symbols[RAW_STRING_OPENING]
        );
    } else {
        while (isspace(lexer->lookahead)) {
            tsv_advance(lexer);
        }
        
        if (valid_symbols[STRING_CLOSING] || valid_symbols[STRING_CONTENT] || valid_symbols[BRACED_INTERPOLATION_OPENING] || valid_symbols[UNBRACED_INTERPOLATION_OPENING] || valid_symbols[INTERPOLATION_CLOSING]) {
            if (lexer->lookahead == expected_end_char(top)) {
                if (valid_symbols[STRING_CLOSING]) {
                    return scan_string_closing(scanner, lexer);
                } else if (valid_symbols[INTERPOLATION_CLOSING]) {
                    return scan_interpolation_closing(scanner, lexer);
                }
            } else if (lexer->lookahead == '$' && (valid_symbols[BRACED_INTERPOLATION_OPENING] || valid_symbols[UNBRACED_INTERPOLATION_OPENING])) {
                return scan_interpolation_opening(scanner, lexer);
            }

            return scan_string_content(scanner, lexer);
        }
    }

    return false;
}