module errors

pub const (
	unknown_node_type_error = 'unknown_node_type_error'
	mismatched_type_error = 'mismatched_type_error'
	not_found_error = 'not_found_error'
	not_public_error = 'not_public_error'
	invalid_argument_error = 'invalid_argument_error'
	undefined_operation_error = 'undefined_operation_error'
	unknown_type_error = 'unknown_type_error'
	ambiguous_method_error = 'ambiguous_method_error'
	ambiguous_field_error = 'ambiguous_field_error'
	ambiguous_call_error = 'ambiguous_call_error'
	append_type_mismatch_error = 'append_type_mismatch_error'
	array_append_expr_error = 'array_append_expr_error'
	invalid_array_element_type_error = 'invalid_array_element_type_error'
	invalid_sumtype_array_init_error = 'invalid_sumtype_array_init_error'
	send_channel_invalid_chan_type_error = 'send_channel_invalid_chan_type_error'
	invalid_assignment_error = 'invalid_assignment_error'
	send_channel_invalid_value_type_error = 'send_channel_invalid_value_type_error'
	send_operator_in_var_decl_error = 'send_operator_in_var_decl_error'
	invalid_assert_type_error = 'invalid_assert_type_error'
	untyped_empty_array_error = 'untyped_empty_array_error'
)

pub const message_templates = {
	errors.unknown_node_type_error: 'unknown node `%s`'
	errors.mismatched_type_error: 'mismatched types `%s` and `%s`'
	errors.not_found_error: 'symbol `%s` not found'
	errors.not_public_error: 'symbol `%s` not public'
	errors.invalid_argument_error: 'cannot use `%s` as `%s` in argument %s to `%s`'
	errors.undefined_operation_error: 'undefined operation `%s` %s `%s`'
	errors.unknown_type_error: 'unknown type `%s`'
	errors.ambiguous_method_error: 'ambiguous method `%s`'
	errors.ambiguous_field_error: 'ambiguous field `%s`'
	errors.ambiguous_call_error: 'ambiguous call to: `%s`, may refer to fn `%s` or variable `%s`'
	errors.append_type_mismatch_error: 'cannot append `%s` to `%s`'
	errors.array_append_expr_error: 'array append cannot be used in an expression'
	errors.invalid_array_element_type_error: 'invalid array element: expected `%s`, not `%s`'
	errors.invalid_sumtype_array_init_error: 'cannot initialize sum type array without default value'
	errors.send_channel_invalid_chan_type_error: 'cannot push on non-channel `%s`'
	errors.invalid_assignment_error: 'cannot assign to `%s`: expected `%s`, not `%s`'
	errors.send_channel_invalid_value_type_error: 'cannot push `%s` on `%s`'
	errors.send_operator_in_var_decl_error: '<- operator can only be used with `chan` types'
	errors.invalid_assert_type_error: 'assert can be used only with `bool` expressions, but found `%s` instead'
	errors.untyped_empty_array_error: 'array_init: no type specified (maybe: `[]Type{}` instead of `[]`)'
}