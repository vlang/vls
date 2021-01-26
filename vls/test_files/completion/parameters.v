module completion

import lsp

pub const completion_contexts = {
	'assign.vv':              lsp.CompletionContext{.trigger_character, ' '}
	'blank.vv':               lsp.CompletionContext{.invoked, ''}
	'import.vv':              lsp.CompletionContext{.trigger_character, ' '}
	'incomplete_module.vv':   lsp.CompletionContext{.invoked, ''}
	'incomplete_selector.vv': lsp.CompletionContext{.trigger_character, '.'}
	'local_results.vv':       lsp.CompletionContext{.invoked, ''}
	'module_symbols_selector.vv': lsp.CompletionContext{.trigger_character, '.'}
	'struct_init.vv':         lsp.CompletionContext{.trigger_character, '{'}
}

pub const completion_positions = {
	'assign.vv':              lsp.Position{6, 8}
	'blank.vv':               lsp.Position{0, 0}
	'import.vv':              lsp.Position{2, 7}
	'incomplete_module.vv':   lsp.Position{0, 7}
	'incomplete_selector.vv': lsp.Position{12, 7}
	'local_results.vv':       lsp.Position{5, 2}
	'module_symbols_selector.vv': lsp.Position{5, 7}
	'struct_init.vv':         lsp.Position{8, 16}
}

pub const completion_results = {
	'assign.vv':              [
		lsp.CompletionItem{
			label: 'two'
			kind: .variable
			insert_text: 'two'
		},
		lsp.CompletionItem{
			label: 'zero'
			kind: .variable
			insert_text: 'zero'
		},
	]
	'blank.vv':               [
		lsp.CompletionItem{
			label: 'module main'
			kind: .variable
			insert_text: 'module main'
		},
		lsp.CompletionItem{
			label: 'module completion'
			kind: .variable
			insert_text: 'module completion'
		},
	]
	'import.vv':              [
		lsp.CompletionItem{
			label: 'abc'
			kind: .folder
			insert_text: 'abc'
		},
		lsp.CompletionItem{
			label: 'abc.def'
			kind: .folder
			insert_text: 'abc.def'
		},
		lsp.CompletionItem{
			label: 'abc.def.ghi'
			kind: .folder
			insert_text: 'abc.def.ghi'
		},
	]
	'incomplete_module.vv':   [
		lsp.CompletionItem{
			label: 'module main'
			kind: .variable
			insert_text: 'module main'
		},
		lsp.CompletionItem{
			label: 'module completion'
			kind: .variable
			insert_text: 'module completion'
		},
	]
	'incomplete_selector.vv': [
		lsp.CompletionItem{
			label: 'name'
			kind: .field
			insert_text: 'name'
		},
		lsp.CompletionItem{
			label: 'lol'
			kind: .method
			insert_text: 'lol()'
			insert_text_format: .snippet
		},
	]
	'local_results.vv':       [
		lsp.CompletionItem{
			label: 'foo'
			kind: .variable
			insert_text: 'foo'
		},
		lsp.CompletionItem{
			label: 'bar'
			kind: .variable
			insert_text: 'bar'
		},
	]
	'module_symbols_selector.vv': []lsp.CompletionItem{}
	'struct_init.vv':         [
		lsp.CompletionItem{
			label: 'name:'
			kind: .field
			insert_text_format: .snippet
			insert_text: 'name: \$0'
		},
		lsp.CompletionItem{
			label: 'age:'
			kind: .field
			insert_text_format: .snippet
			insert_text: 'age: \$0'
		},
	]
}