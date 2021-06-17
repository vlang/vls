# analyzer
A VLS submodule dedicated for analyzing and extracting information from the Tree-Sitter trees. 

## Functions
The following are the functions covered by the analyzer module:

1. Symbol extraction
2. Further semantic/type analysis (aka diagnostics).
3. Extract imports and import the necessary modules.
4. Storing symbol and import info.

## Why
We're using the Tree-sitter parser to gracefully handle such operations that the current V tooling cannot do at this moment and because of this, we are recreating the whole process due to its incompatibility with the existing tools.

## Goals
One of the goals of this new analyzer is to be efficient, reliable, and most importantly can handle the workloads similar to Tree-sitter thus having the ability to partially analyze what's changed in the syntax tree.

## Flow
![flow](./readme_assets/vls-flow.jpg)

*Flow is not yet finalized and will be subject to changes.*

1. Import Extraction
  - Scans the import declarations inside the AST.
  - Analyzer will find the module paths and returns the resolved paths.
  - TODO
2. Top-level Symbol declaration
  - Registers all the top-level nodes (enums/functions/structs/consts/globals) into the store.
    - In import mode, non-public nodes are skipped
  - Creates a scope tree for each block
    - Skipped in import mode
3. Semantic / type checking
  - Follows the rules implemented in `v.checker`
  - Type checking in blocks might be skipped in import mode

## Roadmap
*Target: Before/After July 2021 (Estimated)*

- [ ] Planning
- [ ] Feature Implementation
  - [ ] Import extraction
  - [ ] Top-level symbol extraction
  - [ ] Semantic / type checking