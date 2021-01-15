module completion

import lsp

pub const completion_contexts = {
	'assign.vv':              lsp.CompletionContext{.trigger_character, ' '}
	'blank.vv':               lsp.CompletionContext{.invoked, ''}
	'import.vv':              lsp.CompletionContext{.trigger_character, ' '}
	'incomplete_module.vv':   lsp.CompletionContext{.invoked, ''}
	'incomplete_selector.vv': lsp.CompletionContext{.trigger_character, '.'}
	'local_results.vv':       lsp.CompletionContext{.invoked, ''}
	'struct_init.vv':         lsp.CompletionContext{.trigger_character, '{'}
}

pub const completion_positions = {
	'assign.vv':              lsp.Position{6, 8}
	'blank.vv':               lsp.Position{0, 0}
	'import.vv':              lsp.Position{2, 7}
	'incomplete_module.vv':   lsp.Position{0, 7}
	'incomplete_selector.vv': lsp.Position{8, 6}
	'local_results.vv':       lsp.Position{5, 2}
	'struct_init.vv':         lsp.Position{8, 16}
}