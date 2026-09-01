# Self-hosting progress

The production/bootstrap frontend used by `./lc` is still Python, but self-hosting is being developed incrementally rather than as a flag-day compiler rewrite.

The rule for this work is:

> each self-hosting slice should become an independently useful, tested L-written component before it replaces bootstrap code.

That lets the project compare the L implementation against the mature bootstrap frontend and keeps failures localized.

## Current layers

The L-written frontend is now split into reusable layers:

```text
source bytes
   |
   v
slang_syntax     lexer + syntax parser/recovery
   |
   +---------> slang_index      imports + top-level identities/spans
   |                |
   |                v
   |           slang_project    logical modules + module-scope resolution
   |
   v
slang_decls      structured declaration signatures + recursive type syntax
   |
   v
slang_types      semantic type-name resolution + stable type identities
```

These are ordinary portable L modules. They are currently compiled by the Python bootstrap frontend, so this is **self-hosting progress**, not yet a self-hosted compiler.

### 1. Syntax frontend: `slang_syntax`

`lib/portable/slang_syntax.l` contains the L-written lexer and recursive-descent/precedence syntax parser. It was originally developed for the L language server and is now shared with compiler-front-end work.

`tools/syntax/lsyntax.l` exposes it through a standalone native-running command:

```sh
./lsyntax source.l
```

`./lsyntax` builds on demand to `build/lsyntax` through the same native path used for Lace and the language servers:

```text
L frontend source
  -> Python bootstrap checker/bytecode compiler
  -> generated C + native VM/runtime
  -> cc -O3
  -> native tool
```

At runtime, `lsyntax` itself does not use Python. Successful input exits 0, syntax errors exit 1, and usage/read failures exit 2.

The repository tests require the compiled tool to accept real L source including Lace and reject malformed input.

### 2. Structured module index: `slang_index`

`lib/portable/slang_index.l` builds a stable top-level view from the shared token stream. It records logical imports and aliases, top-level declaration kind/name, `pub` status, declaration/import source extents, and parser errors.

This intentionally remains smaller than a compiler AST. It gives tools stable declaration identities without introducing a second lexer.

The native checker exposes the index for inspection:

```sh
./lsyntax --outline source.l
```

### 3. Project/module resolver: `slang_project`

`lib/portable/slang_project.l` is the first semantic project layer. It operates on already-loaded **logical modules**, keeping filesystem/package lookup outside portable frontend semantics.

It currently checks or exposes:

- import-local names (`import a.b` binds `b`, unless aliased);
- duplicate logical module names;
- duplicate module-scope declarations/import bindings;
- collision with Core builtin names (`len`, `push`, `pop`, `splice`);
- unresolved source/host modules;
- source-module import cycles;
- public/private source member lookup;
- distinct missing-module, missing-member, and private-member results.

The resolver receives the host-module set explicitly. It does not hard-code POSIX files, package paths, repository layout, or the bundled hosted profile into Core semantics.

`examples/portable/resolver_demo.l` exercises these cases and CI runs it through both the bytecode VM and native runtime.

### 4. Structured declarations and type syntax: `slang_decls`

`lib/portable/slang_decls.l` parses the portions of top-level declarations needed for semantic checking rather than treating declarations as source extents only.

It represents:

- declaration generic parameters;
- struct fields and field visibility;
- enum variants and payload types;
- function parameters and return types;
- constant declared types;
- recursive type syntax for unit, named/generic, optional, `ref`, arrays, and function types;
- source spans throughout.

Recursive type syntax is represented with managed `ref Type` nodes, which also gives the self-hosting effort useful pressure on L's managed graph semantics.

Function bodies remain deliberately opaque in this layer. `examples/portable/signatures_demo.l` validates declaration/type parsing under both backends.

### 5. Type-name resolver: `slang_types`

`lib/portable/slang_types.l` resolves structured type syntax to semantic identities. It handles:

- scalar primitive types;
- declaration generic parameters;
- local struct/enum types;
- qualified imported source types and import aliases;
- source visibility;
- generic/type arity;
- explicit host opaque types supplied by the embedding environment;
- non-type declarations used in type position;
- unknown types and duplicate generic parameters.

Resolved type nodes retain their semantic module/name identity, resolved child types, function arity where applicable, and source spans. Later body/type checking should consume these identities rather than repeat string-based lookup.

`examples/portable/type_resolution_demo.l` exercises both valid resolution and the principal failure modes under the VM and native runtime.

## Why develop it in layers?

The frontend is deliberately being built as reusable semantic infrastructure rather than a second monolithic compiler.

The existing slices already exercise byte-oriented source processing, arrays/structs/enums/optionals/managed refs, recursive managed graphs, parser state, diagnostic recovery, source spans, logical modules/visibility, generic identities, and explicit host-environment boundaries.

They also create useful convergence pressure: the compiler, LSP, formatter, analyzer, and editor should progressively share syntax/symbol identity rather than each maintaining approximate private logic.

## Next slices

The next progression is roughly:

1. **Expression/statement AST** — promote the validating parser into the reusable structured representation required for body checking while retaining source spans and recovery.
2. **Lexical/name resolution inside functions** — locals, parameters, pattern bindings, imports, top-level symbols, no-shadowing, and place identity.
3. **Type checker** — expected-type propagation, numeric literals/casts, calls, generic declaration checking, exact generic-call inference, assignments/places, return analysis, and match exhaustiveness.
4. **Checked intermediate representation** — execution/codegen consumes identities/types resolved once by the frontend rather than redoing lookup at runtime.
5. **Bytecode emitter in L** — target the existing bytecode model first so self-hosting is not coupled to inventing another backend.
6. **Bootstrap comparison** — compile the L compiler with the Python bootstrap compiler, then use that compiler to compile itself and compare behavior/artifacts across the conformance corpus.

A filesystem/project loader for the reference command-line profile can be built around these portable layers, but filesystem naming is not itself part of L Core.

## What does not count as self-hosting

The project uses precise terminology:

- A tool **written in L and compiled by the Python bootstrap frontend** is an L-written/native-running tool, not evidence that the compiler is self-hosted.
- The current `L -> bytecode -> generated C + C VM -> executable` path is native execution, but the frontend is still bootstrapped.
- Self-hosting is reached when the L-written compiler can compile the language implementation itself without requiring the Python frontend for ordinary builds.

Until then, the Python implementation remains a useful independent oracle for differential testing rather than something to delete prematurely.
