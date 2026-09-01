# Self-hosting progress

The production/bootstrap frontend used by `./lc` is still Python, but self-hosting is being developed incrementally rather than as a flag-day compiler rewrite.

The rule for this work is:

> each self-hosting slice should become an independently useful, tested L-written component before it replaces bootstrap code.

That lets the project compare the L implementation against the mature bootstrap frontend and keeps failures localized.

## Current layers

The self-hosting frontend now has three L-written layers:

```text
source bytes
   |
   v
slang_syntax     lexer + syntax parser/recovery
   |
   v
slang_index      imports + top-level declaration identities/spans
   |
   v
slang_project    logical modules + module-scope resolution
```

All three are ordinary L source modules. They are currently compiled by the Python bootstrap frontend, so this is **self-hosting progress**, not yet a self-hosted compiler.

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

`lib/portable/slang_index.l` builds a stable top-level view from the shared token stream. It records:

- logical imports and aliases;
- top-level declaration kind/name;
- `pub` status;
- declaration/import source extents;
- parser errors.

This is intentionally smaller than a compiler AST. It gives tools stable declaration identities without introducing a second lexer or pretending expression/type structure is available before it actually is.

The native checker exposes the index for inspection:

```sh
./lsyntax --outline source.l
```

### 3. Project/module resolver: `slang_project`

`lib/portable/slang_project.l` is the first semantic layer. It operates on already-loaded **logical modules**, keeping filesystem/package lookup outside portable frontend semantics.

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

`examples/portable/resolver_demo.l` exercises these cases and CI runs it through both the bytecode VM and the native compiler/runtime.

## Why develop it in layers?

The frontend is deliberately being built as reusable semantic infrastructure rather than a second monolithic compiler.

The existing slices already exercise:

- byte-oriented source processing;
- arrays, structs, enums, optionals, and managed refs;
- parser state and recursive descent;
- diagnostic recovery;
- shared source spans;
- logical modules and visibility;
- explicit host-environment boundaries;
- substantial portable L code under both execution backends.

They also create useful convergence pressure: the compiler, LSP, formatter, analyzer, and editor should progressively share syntax/symbol identity rather than each maintaining approximate private logic.

## Next slices

The next progression is roughly:

1. **Structured declaration signatures and type syntax** — represent generic parameters, struct fields, enum payloads, function parameters/returns, constant types, and recursive type syntax in L rather than only their source extents.
2. **Type-name resolution** — resolve builtins, generic parameters, local nominal types, and qualified imported types to stable identities; enforce type arity and visibility.
3. **Expression/statement AST** — promote the validating parser into the reusable structured representation required for body checking while retaining source spans and recovery.
4. **Lexical/name resolution inside functions** — locals, parameters, pattern bindings, imports, top-level symbols, no-shadowing, and place identity.
5. **Type checker** — expected-type propagation, numeric literals/casts, calls, generic declaration checking, exact generic-call inference, assignments/places, return analysis, and match exhaustiveness.
6. **Checked intermediate representation** — execution/codegen consumes identities/types resolved once by the frontend rather than redoing lookup at runtime.
7. **Bytecode emitter in L** — target the existing bytecode model first so self-hosting is not coupled to inventing another backend.
8. **Bootstrap comparison** — compile the L compiler with the Python bootstrap compiler, then use that compiler to compile itself and compare behavior/artifacts across the conformance corpus.

A filesystem/project loader for the reference command-line profile can be built around these portable layers, but filesystem naming is not itself part of L Core.

## What does not count as self-hosting

The project uses precise terminology:

- A tool **written in L and compiled by the Python bootstrap frontend** is an L-written/native-running tool, not evidence that the compiler is self-hosted.
- The current `L -> bytecode -> generated C + C VM -> executable` path is native execution, but the frontend is still bootstrapped.
- Self-hosting is reached when the L-written compiler can compile the language implementation itself without requiring the Python frontend for ordinary builds.

Until then, the Python implementation remains a useful independent oracle for differential testing rather than something to delete prematurely.
