module errors

pub const (
	unknown_node_type_error = 'unknown_node_type_error'
	bool_string_cast_error = 'bool_string_cast_error'
	constant_mutation_error = 'constant_mutation_error'
	decomposition_error = 'decomposition_error'
	defer_break_error = 'defer_break_error'
	empty_enum_error = 'empty_enum_error'
	enum_default_value_error = 'enum_default_value_error'
	enum_duplicate_member_error = 'enum_duplicate_member_error'
	enum_duplicate_value_error = 'enum_duplicate_value_error'
	enum_value_overflow_error = 'enum_value_overflow_error'
	unexpected_argument_error_single = 'unexpected_argument_error_single'
	unexpected_argument_error_plural = 'unexpected_argument_error_plural'
	float_modulo_error = 'float_modulo_error'
	mismatched_type_error = 'mismatched_type_error'
	nonloop_break_error = 'nonloop_break_error'
	not_found_error = 'not_found_error'
	not_public_error = 'not_public_error'
	if_expr_non_bool_cond_error = 'if_expr_non_bool_cond_error'
	if_expr_no_else_error = 'if_expr_no_else_error'
	if_no_expression_value_error = 'if_no_expression_value_error'
	imaginary_mutation_error = 'imaginary_mutation_error'
	invalid_argument_error = 'invalid_argument_error'
	invalid_option_propagate_call_error = 'invalid_option_propagate_call_error'
	undefined_ident_assignment_error = 'undefined_ident_assignment_error'
	undefined_operation_error = 'undefined_operation_error'
	unhandled_optional_fn_call_error = 'unhandled_optional_fn_call_error'
	unhandled_optional_selector_error = 'unhandled_optional_selector_error'
	unknown_type_error = 'unknown_type_error'
	unknown_function_error = 'unknown_function_error'
	unknown_field_error = 'unknown_field_error'
	unknown_method_or_field_error = 'unknown_method_or_field_error'
	ambiguous_method_error = 'ambiguous_method_error'
	ambiguous_field_error = 'ambiguous_field_error'
	ambiguous_call_error = 'ambiguous_call_error'
	append_type_mismatch_error = 'append_type_mismatch_error'
	array_append_expr_error = 'array_append_expr_error'
	invalid_array_element_type_error = 'invalid_array_element_type_error'
	invalid_enum_casting_error = 'invalid_enum_casting_error'
	invalid_sumtype_array_init_error = 'invalid_sumtype_array_init_error'
	invalid_assignment_error = 'invalid_assignment_error'
	selective_const_import_error = 'selective_const_import_error'
	send_channel_invalid_chan_type_error = 'send_channel_invalid_chan_type_error'
	send_channel_invalid_value_type_error = 'send_channel_invalid_value_type_error'
	send_operator_in_var_decl_error = 'send_operator_in_var_decl_error'
	invalid_assert_type_error = 'invalid_assert_type_error'
	typedef_map_init_error = 'typedef_map_init_error'
	unnecessary_if_parenthesis_error = 'unnecessary_if_parenthesis_error'
	unreachable_code_error = 'unreachable_code_error'
	untyped_empty_array_error = 'untyped_empty_array_error'
	unused_expression_error = 'unused_identifier_error'
	unwrapped_option_binary_expr_error = 'unwrapped_option_binary_expr_error'
	void_symbol_casting_error = 'void_symbol_casting_error'
	wrong_error_propagation_error = 'wrong_error_propagation_error'
)

pub const message_templates = {
	errors.unknown_node_type_error: 'unknown node `%s`'
	errors.bool_string_cast_error: 'cannot cast type `bool` to string, use `%s.str()` instead.'
	errors.constant_mutation_error: 'cannot modify constant `%s`'
	errors.decomposition_error: 'decomposition can only be used on arrays'
	errors.defer_break_error: '`break` is not allowed in defer statements'
	errors.empty_enum_error: 'enum cannot be empty'
	errors.enum_default_value_error: 'default value for enum has to be an integer'
	errors.enum_duplicate_member_error: 'field name `%s` duplicate'
	errors.enum_duplicate_value_error: 'enum value `%s` already exists'
	errors.enum_value_overflow_error: 'enum value overflows'
	errors.unexpected_argument_error_plural: 'expected %s arguments, but got %s'
	errors.unexpected_argument_error_single: 'expected %s argument, but got %s'
	errors.float_modulo_error: 'float modulo not allowed, use math.fmod() instead'
	errors.mismatched_type_error: 'mismatched types `%s` and `%s`'
	errors.nonloop_break_error: 'break statement not within a loop'
	errors.not_found_error: 'symbol `%s` not found'
	errors.not_public_error: 'symbol `%s` not public'
	errors.if_expr_non_bool_cond_error: 'non-bool type `%s` used as if condition'
	errors.if_expr_no_else_error: '`if` expression needs `else` clause'
	errors.if_no_expression_value_error: '`if` expression requires an expression as the last statement of every branch'
	errors.imaginary_mutation_error: 'cannot modify blank `_` identifier'
	errors.invalid_argument_error: 'cannot use `%s` as `%s` in argument %s to `%s`'
	errors.invalid_option_propagate_call_error: 'unexpected `?`, the function `%s` does neither return an optional nor a result'
	errors.undefined_ident_assignment_error: 'undefined ident: `%s` (use `:=` to declare a variable)'
	errors.undefined_operation_error: 'undefined operation `%s` %s `%s`'
	errors.unhandled_optional_fn_call_error: '%s() returns an option, so it should have either an `or {}` block, or `?` at the end'
	errors.unhandled_optional_selector_error: 'cannot access fields of an optional, handle the error with `or {...}` or propagate it with `?`'
	errors.unknown_type_error: 'unknown type `%s`'
	errors.unknown_function_error: 'unknown function: %s'
	errors.unknown_field_error : 'type `%s` has no field named `%s`'
	errors.unknown_method_or_field_error : 'unknown method or field: `%s.%s`'
	errors.ambiguous_method_error: 'ambiguous method `%s`'
	errors.ambiguous_field_error: 'ambiguous field `%s`'
	errors.ambiguous_call_error: 'ambiguous call to: `%s`, may refer to fn `%s` or variable `%s`'
	errors.append_type_mismatch_error: 'cannot append `%s` to `%s`'
	errors.array_append_expr_error: 'array append cannot be used in an expression'
	errors.invalid_array_element_type_error: 'invalid array element: expected `%s`, not `%s`'
	errors.invalid_enum_casting_error: '%s does not represent a value of enum %s'
	errors.invalid_sumtype_array_init_error: 'cannot initialize sum type array without default value'
	errors.send_channel_invalid_chan_type_error: 'cannot push on non-channel `%s`'
	errors.invalid_assignment_error: 'cannot assign to `%s`: expected `%s`, not `%s`'
	errors.selective_const_import_error: 'cannot selective import constant `{{var}}` from `{{module}}`, import `{{module}}` and use `{{module}}.{{var}}` instead'
	errors.send_channel_invalid_value_type_error: 'cannot push `%s` on `%s`'
	errors.send_operator_in_var_decl_error: '<- operator can only be used with `chan` types'
	errors.invalid_assert_type_error: 'assert can be used only with `bool` expressions, but found `%s` instead'
	errors.typedef_map_init_error: 'direct map alias init is not possible, use `{{type_name}}({{map_type}}{})` instead'
	errors.unnecessary_if_parenthesis_error : 'unnecessary `()` in `if` condition, use `if expr {` instead of `if (expr) {`'
	errors.unreachable_code_error: 'unreachable code'
	errors.untyped_empty_array_error: 'array_init: no type specified (maybe: `[]Type{}` instead of `[]`)'
	errors.unused_expression_error: '`%s` evaluated but not used'
	errors.unwrapped_option_binary_expr_error: 'unwrapped optional cannot be used in an infix expression'
	errors.void_symbol_casting_error: 'expression does not return a value so it cannot be cast'
	errors.wrong_error_propagation_error: 'to propagate the optional call, `%s` must return an optional'
}
