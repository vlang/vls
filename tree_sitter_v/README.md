# tree-sitter-v
V language grammar for [tree-sitter](https://github.com/tree-sitter/tree-sitter)

[![build/test](https://github.com/nedpals/tree-sitter-v/actions/workflows/ci.yml/badge.svg)](https://github.com/nedpals/tree-sitter-v/actions/workflows/ci.yml)
![report-badge](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/nedpals/a5d2f238264b49f2c0301eaf799a0e7c/raw/report-badge-data.json)

## Existing grammars
This grammar is heavily derived from the following language grammars:

- [tree-sitter-go](https://github.com/tree-sitter/tree-sitter-go)
- [tree-sitter-ruby](https://github.com/tree-sitter/tree-sitter-ruby/)
- [tree-sitter-c](https://github.com/tree-sitter/tree-sitter-c/)

## Installation
```
npm install tree-sitter-v
```

## Usage [(node-tree-sitter)](https://github.com/tree-sitter/node-tree-sitter)
```javascript
const Parser = require('tree-sitter');
const V = require('tree-sitter-v');

const parser = new Parser();
parser.setLanguage(V);
```

## Usage with V [v-tree-sitter (soon)]
```v
// TODO:
import treesitter
import tree_sitter_v.bindings.v

fn main() {
  mut parser := treesitter.new_parser()
  parser.set_language(v.language)
}
```

## Limitations
1. It does not support all deprecated/outdated syntaxes to avoid any ambiguities and to enforce the one-way philosophy as much as possible.
2. Assembly/SQL code in ASM/SQL block nodes are loosely checked and parsed immediately regardless of the content.
3. Syntaxes specific for implementing JS and native compilation support are not and will not be implemented unless a consensus has been reached. Features from "Compiler magic" are being generalized into different nodes as much as possible.