const PREC = {
  attributes: 8,
  primary: 7,
  unary: 6,
  multiplicative: 5,
  additive: 4,
  comparative: 3,
  and: 2,
  or: 1,
  resolve: 1,
  composite_literal: -1,
};

const multiplicative_operators = ["*", "/", "%", "<<", ">>", "&", "&^"];
const additive_operators = ["+", "-", "|", "^"];
const comparative_operators = ["==", "!=", "<", "<=", ">", ">="];
const assignment_operators = multiplicative_operators
  .concat(additive_operators)
  .map((operator) => operator + "=")
  .concat("=");
const unary_operators = ["+", "-", "!", "~", "^", "*", "&", "<-"];
const overloadable_operators = [
  "+",
  "-",
  "*",
  "/",
  "%",
  "<",
  ">",
  "==",
  "!=",
  "<=",
  ">=",
].map((operator) => token(operator));

const terminator = choice("\n", "\r", "\r\n");

const unicode_digit = /[0-9]/;
const unicode_letter = /[a-zA-Zα-ωΑ-Ωµ]/;
const unicode_letter_lower = /[a-zα-ωµ]/;
const unicode_letter_upper = /[A-ZΑ-Ω]/;

const letter = choice(unicode_letter, "_");

const hex_digit = /[0-9a-fA-F]/;
const octal_digit = /[0-7]/;
const decimal_digit = /[0-9]/;
const binary_digit = /[01]/;

const hex_digits = seq(hex_digit, repeat(seq(optional("_"), hex_digit)));
const octal_digits = seq(octal_digit, repeat(seq(optional("_"), octal_digit)));
const decimal_digits = seq(
  decimal_digit,
  repeat(seq(optional("_"), decimal_digit))
);
const binary_digits = seq(
  binary_digit,
  repeat(seq(optional("_"), binary_digit))
);

const hex_literal = seq("0", choice("x", "X"), optional("_"), hex_digits);
const octal_literal = seq(
  "0",
  optional(choice("o", "O")),
  optional("_"),
  octal_digits
);
const decimal_literal = choice(
  "0",
  seq(/[1-9]/, optional(seq(optional("_"), decimal_digits)))
);
const binary_literal = seq("0", choice("b", "B"), optional("_"), binary_digits);

const int_literal = choice(
  binary_literal,
  decimal_literal,
  octal_literal,
  hex_literal
);

const decimal_exponent = seq(
  choice("e", "E"),
  optional(choice("+", "-")),
  decimal_digits
);
const decimal_float_literal = choice(
  seq(decimal_digits, ".", decimal_digits, optional(decimal_exponent)),
  seq(decimal_digits, decimal_exponent),
  seq(".", decimal_digits, optional(decimal_exponent))
);

const hex_exponent = seq(
  choice("p", "P"),
  optional(choice("+", "-")),
  decimal_digits
);
const hex_mantissa = choice(
  seq(optional("_"), hex_digits, ".", optional(hex_digits)),
  seq(optional("_"), hex_digits),
  seq(".", hex_digits)
);
const hex_float_literal = seq(
  "0",
  choice("x", "X"),
  hex_mantissa,
  hex_exponent
);
const float_literal = choice(decimal_float_literal, hex_float_literal);

const pub_keyword = "pub";
const const_keyword = "const";
const mut_keyword = "mut";
const static_keyword = "static";
const global_keyword = "__global";
const fn_keyword = "fn";
const assert_keyword = "assert";
const as_keyword = "as";
const go_keyword = "go";
const asm_keyword = "asm";
const return_keyword = "return";
const type_keyword = "type";
const for_keyword = "for";
const in_keyword = "in";
const is_keyword = "is";
const if_keyword = "if";
const else_keyword = "else";
const union_keyword = "union";
const struct_keyword = "struct";
const enum_keyword = "enum";
const interface_keyword = "interface";
const defer_keyword = "defer";
const unsafe_keyword = "unsafe";
const import_keyword = "import";
const match_keyword = "match";
const lock_keyword = "lock";
const rlock_keyword = "rlock";
const select_keyword = "select";
const builtin_type_keywords = [
  "voidptr",
  "byteptr",
  "charptr",
  "i8",
  "i16",
  "int",
  "i64",
  "byte",
  "u8",
  "u16",
  "u32",
  "u64",
  "f32",
  "f64",
  "char",
  "bool",
  "string",
  "rune",
  "array",
  "map",
  "chan",
  "size_t",
  "size_t",
  "float_literal",
  "int_literal",
  "thread",
  "IError",
];

const fixed_array_symbol = "!";
const string_quotes = ["'", '"'];
const all_keywords = [
  pub_keyword,
  const_keyword,
  mut_keyword,
  global_keyword,
  fn_keyword,
  assert_keyword,
  as_keyword,
  go_keyword,
  asm_keyword,
  return_keyword,
  type_keyword,
  if_keyword,
  else_keyword,
  for_keyword,
  in_keyword,
  is_keyword,
  union_keyword,
  struct_keyword,
  enum_keyword,
  interface_keyword,
  defer_keyword,
  unsafe_keyword,
  import_keyword,
  match_keyword,
  lock_keyword,
  rlock_keyword,
  select_keyword,
  ...builtin_type_keywords,
];

module.exports = grammar({
  name: "v",

  extras: ($) => [$.comment, /\s/],

  word: ($) => $.identifier,

  inline: ($) => [
    $._type,
    $._string_literal,
    $._field_identifier,
    $._module_identifier,
    $._top_level_declaration,
    $._non_empty_array,
  ],

  supertypes: ($) => [
    $._expression,
    $._type,
    $._simple_type,
    $._statement,
    $._simple_statement,
    $._expression_with_blocks,
  ],

  conflicts: ($) => [
    [$.qualified_type, $._expression],
    [$.fixed_array_type, $._expression],
    [$._binded_type, $._expression],
    [$.assignable_identifier_list, $.identifier_list],
    [$.identifier_list, $._expression],
  ],

  rules: {
    source_file: ($) =>
      repeat(
        seq(
          choice($._top_level_declaration, $._statement),
          optional(terminator)
        )
      ),

    _top_level_declaration: ($) =>
      choice(
        $.const_declaration,
        $.global_var_declaration,
        $._c_directive,
        $.function_declaration,
        $.type_declaration,
        $.struct_declaration,
        $.enum_declaration,
        $.interface_declaration,
        $.import_declaration,
        $.module_clause
      ),

    _expression: ($) =>
      choice(
        $.int_literal,
        $.float_literal,
        $._string_literal,
        $.rune_literal,
        $._reserved_identifier,
        $.binded_identifier,
        $.identifier,
        $._single_line_expression,
        $.type_initializer,
        $.map,
        $.array,
        $.fixed_array,
        $.unary_expression,
        $.binary_expression,
        $.in_expression,
        $.is_expression,
        $.index_expression,
        $.slice_expression,
        $.type_cast_expression,
        $.as_type_cast_expression,
        $.call_expression,
        $.special_call_expression,
        $.fn_literal,
        $.selector_expression,
        $.parenthesized_expression,
        $._expression_with_blocks
      ),

    parenthesized_expression: ($) => seq("(", $._expression, ")"),

    unary_expression: ($) =>
      prec(
        PREC.unary,
        seq(
          field("operator", choice(...unary_operators)),
          field("operand", choice($._expression))
        )
      ),

    binary_expression: ($) => {
      const table = [
        [PREC.multiplicative, choice(...multiplicative_operators)],
        [PREC.additive, choice(...additive_operators)],
        [PREC.comparative, choice(...comparative_operators)],
        [PREC.and, "&&"],
        [PREC.or, "||"],
      ];

      return choice(
        ...table.map(([precedence, operator]) =>
          prec.left(
            precedence,
            seq(
              field("left", $._expression),
              field("operator", operator),
              field("right", $._expression)
            )
          )
        )
      );
    },

    as_type_cast_expression: ($) =>
      seq($._expression, as_keyword, $._simple_type),

    type_cast_expression: ($) =>
      seq(
        field("type", $._simple_type),
        "(",
        field("operand", $._expression),
        ")"
      ),

    call_expression: ($) =>
      prec.right(
        PREC.comparative,
        seq(
          field(
            "function",
            choice(
              $.identifier,
              $.binded_identifier,
              $.comptime_identifier,
              $.selector_expression,
              $.comptime_selector_expression
            )
          ),
          field("type_parameters", optional($.type_parameters)),
          field("arguments", $.argument_list),
          optional($.option_propagator)
        )
      ),

    special_argument_list: ($) =>
      seq(
        "(",
        choice($._simple_type, $.option_type),
        optional(seq(",", $._expression)),
        ")"
      ),

    special_call_expression: ($) =>
      prec.right(
        PREC.comparative,
        seq(
          field("function", choice($.identifier, $.selector_expression)),
          field("arguments", $.special_argument_list),
          optional($.option_propagator)
        )
      ),

    comptime_identifier: ($) => comp_time($.identifier),

    comptime_selector_expression: ($) =>
      comp_time(seq("(", $.selector_expression, ")")),

    option_propagator: ($) => prec.right(choice(token("?"), $.or_block)),

    or_block: ($) => seq("or", $.block),

    _expression_with_blocks: ($) =>
      choice(
        $.if_expression,
        $.match_expression,
        $.select_expression,
        $.sql_expression,
        $.lock_expression,
        $.unsafe_expression,
        $.comptime_if_expression
      ),

    _single_line_expression: ($) =>
      prec.left(
        PREC.resolve,
        choice(
          $.pseudo_comptime_identifier,
          $.type_selector_expression,
          $.none,
          $.true,
          $.false
        )
      ),

    // http://stackoverflow.com/questions/13014947/regex-to-match-a-c-style-multiline-comment/36328890#36328890
    comment: ($) =>
      token(choice(/\/\/.*/, seq("/*", /[^*]*\*+([^/*][^*]*\*+)*/, "/"))),

    escape_sequence: ($) =>
      token(
        prec(
          1,
          seq(
            "\\",
            choice(
              /u[a-fA-F\d]{4}/,
              /U[a-fA-F\d]{8}/,
              /x[a-fA-F\d]{2}/,
              /\d{3}/,
              /\r?\n/,
              /['"abfrntv\$\\]/,
              /\S/
            )
          )
        )
      ),

    none: ($) => "none",
    true: ($) => "true",
    false: ($) => "false",

    spread_operator: ($) =>
      prec.right(
        PREC.unary,
        seq(
          "...",
          choice(
            $.identifier,
            $.selector_expression,
            $.index_expression,
            $.slice_expression,
            $.parenthesized_expression
          )
        )
      ),

    type_initializer: ($) =>
      prec(
        PREC.composite_literal,
        seq(
          field(
            "type",
            choice(
              $.builtin_type,
              $.type_identifier,
              $.type_placeholder,
              $.generic_type,
              $._binded_type,
              $.qualified_type,
              $.pointer_type,
              $.array_type,
              $.fixed_array_type,
              $.map_type,
              $.channel_type
            )
          ),
          field("body", $.literal_value)
        )
      ),

    literal_value: ($) =>
      seq(
        "{",
        choice(
          repeat(
            seq(
              choice($.spread_operator, $.keyed_element),
              optional(choice(",", terminator))
            )
          ),
          // For short struct init syntax
          repeat(seq(alias($._expression, $.element), optional(",")))
        ),
        "}"
      ),

    keyed_element: ($) => seq($._element_key, field("value", $._expression)),

    _element_key: ($) =>
      seq(
        field(
          "name",
          choice(
            $._field_identifier,
            $._string_literal,
            $.int_literal,
            $.call_expression,
            $.selector_expression,
            $.type_selector_expression
          )
        ),
        token.immediate(":")
      ),

    map: ($) =>
      prec(
        PREC.composite_literal,
        seq(
          "{",
          repeat1(seq($.keyed_element, optional(choice(",", terminator)))),
          "}"
        )
      ),

    array: ($) => prec.right(PREC.composite_literal, $._non_empty_array),

    fixed_array: ($) =>
      prec.right(
        PREC.composite_literal,
        seq($._non_empty_array, fixed_array_symbol)
      ),

    _non_empty_array: ($) =>
      seq("[", repeat(seq($._expression, optional(","))), "]"),

    fixed_array_type: ($) =>
      seq(
        "[",
        field("size", choice($.int_literal, $.identifier)),
        "]",
        field("element", $._simple_type)
      ),

    array_type: ($) =>
      prec(PREC.resolve, seq("[", "]", field("element", $._simple_type))),

    variadic_type: ($) => seq("...", $._simple_type),

    pointer_type: ($) => prec(PREC.unary, seq("&", $._simple_type)),

    map_type: ($) =>
      seq("map[", field("key", $._simple_type), "]", field("value", $._type)),

    channel_type: ($) =>
      prec.right(PREC.primary, seq("chan", field("value", $._simple_type))),

    int_literal: ($) => token(int_literal),

    float_literal: ($) => token(float_literal),

    rune_literal: ($) =>
      token(
        seq(
          "`",
          choice(
            /[^'\\]/,
            "'",
            '"',
            seq(
              "\\",
              choice(
                "0",
                "`",
                seq("x", hex_digit, hex_digit),
                seq(octal_digit, octal_digit, octal_digit),
                seq("u", hex_digit, hex_digit, hex_digit, hex_digit),
                seq(
                  "U",
                  hex_digit,
                  hex_digit,
                  hex_digit,
                  hex_digit,
                  hex_digit,
                  hex_digit,
                  hex_digit,
                  hex_digit
                ),
                seq(choice("a", "b", "f", "n", "r", "t", "v", "\\", "'", '"'))
              )
            )
          ),
          "`"
        )
      ),

    _string_literal: ($) =>
      choice(
        $.c_string_literal,
        $.raw_string_literal,
        $.interpreted_string_literal
      ),

    c_string_literal: ($) => quoted_string($, "c", $.string_interpolation),
    raw_string_literal: ($) => quoted_string1($, "r"),
    interpreted_string_literal: ($) =>
      quoted_string($, "", $.string_interpolation),

    string_interpolation: ($) =>
      choice(
        seq("${", $._expression, optional($.format_specifier), "}"),
        seq(
          "$",
          choice(
            $._single_line_expression,
            $.identifier,
            $.selector_expression,
            $.call_expression
          )
        )
      ),

    format_flag: ($) => token(/[gGeEfFcdoxXpsSc]/),

    format_specifier: ($) =>
      seq(
        token(":"),
        choice(
          $.format_flag,
          seq(
            optional(token(/[+-0]/)),
            $.int_literal,
            optional(seq(".", $.int_literal)),
            optional($.format_flag)
          )
        )
      ),

    _reserved_identifier: ($) =>
      alias(choice("array", "string", "char", "sql"), $.identifier),

    identifier: ($) =>
      token(
        choice(
          seq(
            choice(unicode_letter_lower, "_"),
            repeat(choice(letter, unicode_digit))
          ),
          seq("@", choice(...all_keywords))
        )
      ),

    // Some of the syntaxes in V are restricted
    // to be in a single line. That's why an identifier
    // immediate token is created to solve this concern.
    immediate_identifier: ($) =>
      token.immediate(
        seq(
          choice(unicode_letter_lower),
          repeat(choice(letter, unicode_digit, "_"))
        )
      ),

    _old_identifier: ($) =>
      token(seq(letter, repeat(choice(letter, unicode_digit)))),

    _mutable_identifier: ($) =>
      prec(
        PREC.resolve,
        seq(
          mut_keyword,
          optional(static_keyword),
          choice($.identifier, $.selector_expression, $._reserved_identifier)
        )
      ),

    mutable_expression: ($) =>
      prec(
        PREC.resolve,
        seq(
          mut_keyword,
          choice(
            $.identifier,
            $.selector_expression,
            $.index_expression,
            $.slice_expression,
            $.unary_expression,
            $.type_initializer
          )
        )
      ),

    binded_identifier: ($) =>
      seq(
        field("language", choice("C", "JS")),
        token.immediate("."),
        field("name", alias($._old_identifier, $.identifier))
      ),

    identifier_list: ($) =>
      prec(
        PREC.primary,
        comma_sep1(choice($.identifier, $._mutable_identifier))
      ),

    assignable_identifier_list: ($) =>
      prec(
        PREC.primary,
        comma_sep1(
          choice(
            $.binded_identifier,
            $._reserved_identifier,
            $.identifier,
            $.selector_expression,
            $.index_expression,
            $.unary_expression,
            $.parenthesized_expression
          )
        )
      ),

    expression_list: ($) => prec(PREC.resolve, comma_sep1($._expression)),

    parameter_declaration: ($) =>
      seq(
        optional(mut_keyword),
        field("name", choice($.identifier, $._reserved_identifier)),
        field("type", choice($._simple_type, $.option_type, $.variadic_type))
      ),

    parameter_list: ($) =>
      prec(PREC.resolve, seq("(", comma_sep($.parameter_declaration), ")")),

    _empty_literal_value: ($) => alias("{}", $.literal_value),

    argument_list: ($) =>
      seq(
        "(",
        optional(
          seq(
            choice(
              $._empty_literal_value,
              $._expression,
              $.mutable_expression,
              $.keyed_element,
              $.spread_operator
            ),
            // TODO: accept terminator as argument separator for now
            // to avoid complexities in the grammar.
            // Finalize the syntax with keyed elements (aka struct init fields)
            repeat(
              seq(
                choice(",", terminator),
                choice(
                  $._empty_literal_value,
                  $._expression,
                  $.mutable_expression,
                  $.keyed_element,
                  $.spread_operator
                )
              )
            ),
            optional(terminator)
          )
        ),
        ")"
      ),

    _type: ($) => choice($._simple_type, $.option_type, $.multi_return_type),

    option_type: ($) =>
      prec.right(
        seq("?", optional(choice($._simple_type, $.multi_return_type)))
      ),

    multi_return_type: ($) => seq("(", comma_sep1($._simple_type), ")"),

    type_list: ($) => comma_sep1($._simple_type),

    _simple_type: ($) =>
      choice(
        $.builtin_type,
        $.type_identifier,
        $.type_placeholder,
        $._binded_type,
        $.qualified_type,
        $.pointer_type,
        $.array_type,
        $.fixed_array_type,
        $.function_type,
        $.generic_type,
        $.map_type,
        $.channel_type
      ),

    type_parameters: ($) =>
      prec(
        PREC.resolve,
        seq(
          token.immediate("<"),
          comma_sep1($._simple_type),
          token.immediate(">")
        )
      ),

    builtin_type: ($) =>
      prec.right(PREC.resolve, choice(...builtin_type_keywords)),

    _binded_type: ($) => prec.right(alias($.binded_identifier, $.binded_type)),

    generic_type: ($) =>
      seq(choice($.qualified_type, $.type_identifier), $.type_parameters),

    qualified_type: ($) =>
      seq(
        field("module", $._module_identifier),
        ".",
        field("name", $.type_identifier)
      ),

    type_placeholder: ($) => token(unicode_letter_upper),

    pseudo_comptime_identifier: ($) =>
      seq("@", alias(/[A-Z][A-Z0-9_]+/, $.identifier)),

    type_identifier: ($) =>
      token(seq(unicode_letter_upper, repeat1(choice(letter, unicode_digit)))),

    _module_identifier: ($) => alias($.identifier, $.module_identifier),

    _field_identifier: ($) => alias($.identifier, $.field_identifier),

    _statement_list: ($) => repeat1($._statement),

    _statement: ($) =>
      choice(
        $._simple_statement,
        $.assert_statement,
        $.continue_statement,
        $.break_statement,
        $.return_statement,
        $.asm_statement,
        $.go_statement,
        $.goto_statement,
        $.labeled_statement,
        $.empty_labeled_statement,
        $.defer_statement,
        $.for_statement,
        $.comptime_for_statement,
        $.send_statement,
        $.block
      ),

    _simple_statement: ($) =>
      choice(
        $._expression,
        $.inc_statement,
        $.dec_statement,
        $.assignment_statement,
        $.short_var_declaration
      ),

    inc_statement: ($) => seq($._expression, "++"),

    dec_statement: ($) => seq($._expression, "--"),

    send_statement: ($) =>
      prec(
        PREC.unary,
        seq(
          field("channel", $._expression),
          "<-",
          field("value", $._expression)
        )
      ),

    short_var_declaration: ($) =>
      prec.right(
        seq(
          field("left", $.identifier_list),
          ":=",
          field("right", $.expression_list)
        )
      ),

    assignment_statement: ($) =>
      seq(
        field("left", $.assignable_identifier_list),
        field("operator", choice(...assignment_operators)),
        field("right", $.expression_list)
      ),

    assert_statement: ($) => seq(assert_keyword, $._expression),

    block: ($) => seq("{", optional($._statement_list), "}"),

    defer_statement: ($) => seq(defer_keyword, $.block),

    unsafe_expression: ($) => seq(unsafe_keyword, $.block),

    overloadable_operator: ($) => choice(...overloadable_operators),

    exposed_variables_list: ($) => seq("[", $.identifier_list, "]"),

    function_declaration: ($) =>
      prec.right(
        seq(
          field("attributes", optional($.attribute_list)),
          optional(pub_keyword),
          fn_keyword,
          field("receiver", optional($.parameter_list)),
          field("exposed_variables", optional($.exposed_variables_list)),
          field(
            "name",
            choice($.binded_identifier, $.identifier, $.overloadable_operator)
          ),
          field("type_parameters", optional($.type_parameters)),
          field(
            "parameters",
            choice($.parameter_list, $.type_only_parameter_list)
          ),
          field("result", optional($._type)),
          field("body", optional($.block))
        )
      ),

    function_type: ($) =>
      prec.right(
        seq(
          fn_keyword,
          field(
            "parameters",
            choice($.parameter_list, $.type_only_parameter_list)
          ),
          field("result", optional($._type))
        )
      ),

    type_only_parameter_list: ($) =>
      seq("(", comma_sep($.type_parameter_declaration), ")"),

    type_parameter_declaration: ($) =>
      seq(
        optional(mut_keyword),
        field("type", choice($._simple_type, $.option_type, $.variadic_type))
      ),

    fn_literal: ($) =>
      prec.right(
        seq(
          fn_keyword,
          field("exposed_variables", optional($.exposed_variables_list)),
          field("parameters", $.parameter_list),
          field("result", optional($._type)),
          field("body", $.block),
          field("arguments", optional($.argument_list))
        )
      ),

    global_var_declaration: ($) =>
      seq(
        global_keyword,
        choice(
          $._global_var_spec,
          $.global_var_type_initializer,
          seq(
            "(",
            repeat(
              seq(
                choice($._global_var_spec, $.global_var_type_initializer),
                terminator
              )
            ),
            ")"
          )
        )
      ),

    _global_var_spec: ($) => alias($.const_spec, $.global_var_spec),

    global_var_type_initializer: ($) =>
      seq(field("name", $.identifier), field("type", $._type)),

    const_declaration: ($) =>
      seq(
        optional(pub_keyword),
        const_keyword,
        choice(
          $.const_spec,
          seq("(", repeat1(seq($.const_spec, terminator)), ")")
        )
      ),

    const_spec: ($) =>
      seq(field("name", $.identifier), "=", field("value", $._expression)),

    asm_statement: ($) => seq(asm_keyword, $.identifier, $._content_block),

    // NOTE: this should be put into a separate grammar
    // to avoid any "noise" (i guess)
    sql_expression: ($) =>
      prec(PREC.resolve, seq("sql", optional($.identifier), $._content_block)),

    // Loose checking for asm and sql statements
    _content_block: ($) => seq("{", token.immediate(prec(1, /[^{}]+/)), "}"),

    break_statement: ($) =>
      prec.right(seq("break", optional(alias($.identifier, $.label_name)))),

    continue_statement: ($) =>
      prec.right(seq("continue", optional(alias($.identifier, $.label_name)))),

    return_statement: ($) =>
      prec.right(seq(return_keyword, optional($.expression_list))),

    type_declaration: ($) =>
      seq(
        optional(pub_keyword),
        type_keyword,
        field("name", choice($.type_identifier, $.builtin_type)),
        field("type_parameters", optional($.type_parameters)),
        "=",
        field("types", alias($.sum_type_list, $.type_list))
      ),

    sum_type_list: ($) => seq($._simple_type, repeat(seq("|", $._simple_type))),

    go_statement: ($) => seq(go_keyword, $._expression),

    goto_statement: ($) => seq("goto", alias($.identifier, $.label_name)),

    labeled_statement: ($) =>
      prec.right(
        PREC.resolve,
        seq(
          field("label", alias($.identifier, $.label_name)),
          ":",
          $._statement
        )
      ),

    empty_labeled_statement: ($) =>
      seq(field("label", alias($.identifier, $.label_name)), ":"),

    for_statement: ($) =>
      seq(
        for_keyword,
        optional(
          choice(
            prec(PREC.resolve, $.for_in_operator),
            $._expression, // condition-based for
            $.cstyle_for_clause
          )
        ),
        field("body", $.block)
      ),

    comptime_for_statement: ($) =>
      seq("$for", $.for_in_operator, field("body", $.block)),

    for_in_operator: ($) =>
      prec(
        PREC.primary,
        seq(
          field("left", $.identifier_list),
          in_keyword,
          field(
            "right",
            choice($._expression, alias($._definite_range, $.range))
          )
        )
      ),

    _definite_range: ($) =>
      prec(
        PREC.multiplicative,
        seq(
          field("start", $._expression),
          choice("..", "..."),
          field("end", $._expression)
        )
      ),

    _range: ($) =>
      prec(
        PREC.multiplicative,
        seq(
          field("start", optional($._expression)),
          choice("..", "..."),
          field("end", optional($._expression))
        )
      ),

    selector_expression: ($) =>
      prec(
        PREC.primary,
        seq(
          field("operand", $._expression),
          ".",
          field(
            "field",
            choice(
              $.identifier,
              $._reserved_identifier,
              $.comptime_identifier,
              $.comptime_selector_expression
            )
          )
        )
      ),

    index_expression: ($) =>
      prec.right(
        PREC.primary,
        seq(
          field("operand", $._expression),
          "[",
          field("index", $._expression),
          "]",
          optional($.option_propagator)
        )
      ),

    slice_expression: ($) =>
      prec(
        PREC.primary,
        seq(field("operand", $._expression), "[", $._range, "]")
      ),

    cstyle_for_clause: ($) =>
      prec.left(
        seq(
          field("initializer", optional($._simple_statement)),
          ";",
          field("condition", optional($._expression)),
          ";",
          field("update", optional($._simple_statement))
        )
      ),

    _comptime_block: ($) =>
      seq(
        "{",
        optional(
          repeat(
            seq(choice($._statement, $._c_directive), optional(terminator))
          )
        ),
        "}"
      ),

    comptime_if_expression: ($) =>
      seq(
        "$" + if_keyword,
        field(
          "condition",
          choice(
            alias($._generic_type_is_expression, $.is_expression),
            seq($._expression, optional("?"))
          )
        ),
        field("consequence", alias($._comptime_block, $.block)),
        optional(
          seq(
            "$else",
            field(
              "alternative",
              choice(
                alias($._comptime_block, $.block),
                $.comptime_if_expression
              )
            )
          )
        )
      ),

    if_expression: ($) =>
      seq(
        if_keyword,
        choice(
          field("condition", $._expression),
          field("initializer", $.short_var_declaration)
        ),
        field("consequence", $.block),
        optional(
          seq(
            else_keyword,
            field("alternative", choice($.block, $.if_expression))
          )
        )
      ),

    in_expression: ($) =>
      prec.left(
        PREC.comparative,
        seq(
          field("left", $._expression),
          choice(in_keyword, "!" + in_keyword),
          field("right", $._expression)
        )
      ),

    _generic_type_is_expression: ($) =>
      prec.left(
        PREC.comparative,
        seq(
          field("left", $.type_placeholder),
          choice(is_keyword, "!" + is_keyword),
          field("right", choice($.option_type, $._simple_type))
        )
      ),

    is_expression: ($) =>
      prec.left(
        PREC.comparative,
        seq(
          field("left", choice($.mutable_expression, $._expression)),
          choice(is_keyword, "!" + is_keyword),
          field("right", choice($.option_type, $._simple_type, $.none))
        )
      ),

    attribute_spec: ($) =>
      prec(
        PREC.attributes,
        choice(
          seq(if_keyword, $.identifier, optional("?")),
          choice(alias("unsafe", $.identifier), $.identifier),
          seq(
            field("name", choice(alias("unsafe", $.identifier), $.identifier)),
            ":",
            field("value", choice($._string_literal, $.identifier))
          )
        )
      ),

    attribute_declaration: ($) =>
      seq("[", seq($.attribute_spec, repeat(seq(";", $.attribute_spec))), "]"),

    attribute_list: ($) =>
      repeat1(seq($.attribute_declaration, optional(terminator))),

    struct_declaration: ($) =>
      seq(
        field("attributes", optional($.attribute_list)),
        optional(pub_keyword),
        choice(struct_keyword, union_keyword),
        field(
          "name",
          prec.dynamic(
            PREC.composite_literal,
            choice(
              $.type_identifier,
              // in order to parse builtin
              $.builtin_type,
              $._binded_type,
              $.generic_type
            )
          )
        ),
        $.struct_field_declaration_list
      ),

    struct_field_declaration_list: ($) =>
      seq(
        "{",
        repeat(
          seq(
            choice($.struct_field_scope, $.struct_field_declaration),
            optional(terminator)
          )
        ),
        "}"
      ),

    struct_field_scope: ($) =>
      seq(
        choice(
          pub_keyword,
          mut_keyword,
          seq(pub_keyword, mut_keyword),
          global_keyword
        ),
        token.immediate(":")
      ),

    struct_field_declaration: ($) =>
      prec.right(
        choice(
          seq(
            field("name", choice($._field_identifier)),
            field("type", choice($._simple_type, $.option_type)),
            field("attributes", optional($.attribute_declaration)),
            optional(seq("=", field("default_value", $._expression))),
            optional(terminator)
          ),
          field(
            "type",
            seq(
              choice($.type_identifier, $.qualified_type),
              optional(terminator)
            )
          )
        )
      ),

    enum_declaration: ($) =>
      seq(
        optional($.attribute_list),
        optional(pub_keyword),
        enum_keyword,
        field("name", $.type_identifier),
        $.enum_member_declaration_list
      ),

    enum_member_declaration_list: ($) =>
      seq(
        "{",
        optional(seq(repeat(seq($.enum_member, optional(terminator))))),
        "}"
      ),

    enum_member: ($) =>
      seq(
        field("name", $.identifier),
        optional(seq("=", field("value", $._expression)))
      ),

    type_selector_expression: ($) =>
      seq(
        field(
          "type",
          optional(
            choice($.type_placeholder, $.type_identifier, $.qualified_type)
          )
        ),
        ".",
        field("field_name", choice($._reserved_identifier, $.identifier))
      ),

    interface_declaration: ($) =>
      seq(
        field("attributes", optional($.attribute_list)),
        optional(pub_keyword),
        interface_keyword,
        field("name", choice($.type_identifier, $.generic_type)),
        $.interface_spec_list
      ),

    interface_spec_list: ($) =>
      seq(
        "{",
        optional(
          repeat(
            seq(
              choice(
                $.struct_field_declaration,
                $.interface_spec,
                $.interface_field_scope
              ),
              optional(terminator)
            )
          )
        ),
        "}"
      ),

    interface_field_scope: ($) => seq(mut_keyword + ":"),

    interface_spec: ($) =>
      prec.right(
        seq(
          field("name", $._field_identifier),
          field("parameters", $.parameter_list),
          field("result", optional($._type))
        )
      ),

    _c_directive: ($) =>
      choice(
        $.c_include_clause,
        $.c_flag_clause,
        $.c_define_clause,
        $.c_pkgconfig
      ),

    c_include_clause: ($) =>
      seq(
        "#include",
        field(
          "path",
          choice($.interpreted_string_literal, $.c_include_path_string)
        ),
        field(
          "error_message",
          optional(
            seq(
              "#",
              token(prec(PREC.composite_literal, repeat1(/.|\\\r?\n/))),
              terminator
            )
          )
        )
      ),

    // Taken from: https://github.com/tree-sitter/tree-sitter-c/blob/master/grammar.js#L937
    c_include_path_string: (_) =>
      token(seq("<", repeat(choice(/[^>\n]/, "\\>")), ">")),

    c_flag_clause: ($) =>
      seq(
        "#flag",
        field("platform", optional($.identifier)),
        field("flag", optional(seq("-", letter))),
        field(
          "value",
          token(prec(PREC.composite_literal, repeat1(/.|\\\r?\n/)))
        )
      ),

    c_define_clause: ($) =>
      seq(
        "#define",
        field("name", alias($._old_identifier, $.identifier)),
        field(
          "value",
          optional(token(prec(PREC.composite_literal, repeat1(/.|\\\r?\n/))))
        ),
        terminator
      ),

    c_pkgconfig: ($) =>
      seq(
        "#pkgconfig",
        token(prec(PREC.composite_literal, repeat1(/.|\\\r?\n/))),
        terminator
      ),

    module_clause: ($) =>
      seq(
        field("attributes", optional($.attribute_list)),
        "module",
        " ",
        alias($.immediate_identifier, $.module_identifier)
      ),

    import_declaration: ($) =>
      prec.right(
        PREC.resolve,
        seq(
          import_keyword,
          // Adds a space in order to avoid import_path
          // getting parsed on other lines
          " ",
          field("path", $.import_path),
          optional(
            seq(
              // Same as well for aliases and symbols. Although
              // the contents inside the braces are allowed as per testing.
              " ",
              choice(
                field("alias", $.import_alias),
                field("symbols", $.import_symbols)
              )
            )
          )
        )
      ),

    import_path: ($) =>
      token.immediate(seq(letter, repeat(choice(letter, unicode_digit, ".")))),

    import_symbols: ($) =>
      seq(token.immediate("{"), $.import_symbols_list, "}"),

    import_symbols_list: ($) =>
      comma_sep1(choice($.identifier, alias($.type_identifier, $.identifier))),

    import_alias: ($) =>
      seq(
        "as",
        " ",
        field("name", alias($.immediate_identifier, $.module_identifier))
      ),

    match_expression: ($) =>
      seq(
        match_keyword,
        field("condition", choice($._expression, $._mutable_identifier)),
        "{",
        repeat($.expression_case),
        optional($.default_case),
        "}"
      ),

    expression_case: ($) =>
      seq(
        field(
          "value",
          choice(
            $.expression_list,
            $.type_list,
            alias($._definite_range, $.range)
          )
        ),
        field("consequence", $.block)
      ),

    default_case: ($) => seq(else_keyword, field("consequence", $.block)),

    select_expression: ($) =>
      seq(
        select_keyword,
        field("selected_variables", optional($.expression_list)),
        "{",
        repeat($.select_branch),
        optional($.select_default_branch),
        "}"
      ),

    select_branch: ($) => seq(choice($.short_var_declaration), $.block),

    select_default_branch: ($) =>
      seq(
        choice(
          prec(PREC.primary, seq(optional(">"), $._expression)),
          else_keyword
        ),
        $.block
      ),

    lock_expression: ($) =>
      seq(
        choice(lock_keyword, rlock_keyword),
        field("locked_variables", optional($.expression_list)),
        field("body", $.block)
      ),
  },
});

function comp_time(rule) {
  return seq("$", rule);
}

function comma_sep1(rules) {
  return seq(rules, repeat(seq(",", rules)));
}

function comma_sep(rule) {
  return optional(comma_sep1(rule));
}

function quoted_string1($, prefix, rule) {
  return choice(
    ...string_quotes.map((quote) =>
      seq(
        prefix + quote,
        repeat(token.immediate(new RegExp(`[^${quote}]+`))),
        quote
      )
    )
  );
}

function quoted_string($, prefix, rule) {
  return choice(
    ...string_quotes.map((quote) =>
      seq(
        prefix + quote,
        repeat(
          choice(
            // TODO: not the best solution but we can improve this later
            alias(
              choice(
                token.immediate("$c"),
                token.immediate("$r"),
              ),
              $.string_interpolation
            ),
            token.immediate("$("),
            token.immediate("$%"),
            token.immediate(prec(1, new RegExp(`[^\$${quote}\\\\]+`))),
            $.escape_sequence,
            rule
          )
        ),
        quote
      )
    )
  );
}
