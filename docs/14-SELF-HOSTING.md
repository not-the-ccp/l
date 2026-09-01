# Self-hosting progress

The production `./lc` frontend is still Python, but the replacement frontend is being built incrementally in L rather than as a flag-day rewrite.

The rule for this work is:

> each self-hosting slice should become an independently useful, tested L-written component before it replaces bootstrap code.

The Python implementation remains an independent semantic oracle until the L-written compiler can compile itself.

## Current frontend

```text
source bytes
   |
   v
slang_syntax     lexer + syntax validation/recovery
   |
   +---------> slang_index      imports + top-level identities/spans
   |                |
   |                v
   |           slang_project    logical modules + module-scope resolution
   |
   v
slang_decls      declarations + types + complete executable body AST
   |
   +---------> slang_names      lexical value-name/scope resolution
   |
   v
slang_types      semantic type identities
   |
   v
slang_check      value/place/body semantic checking
   |
   v
lcheck           native-running L-written checker CLI
```

All of these frontend layers are ordinary L modules. They are currently compiled by the Python bootstrap compiler, so this is **self-hosting progress**, not yet a self-hosted compiler.

## Syntax and structure

`lib/portable/slang_syntax.l` contains the L-written lexer and syntax validator/recovery parser. `lib/portable/slang_index.l` builds the stable top-level import/declaration view used by later tooling.

`./lsyntax` exposes these layers as a native-running tool:

```sh
./lsyntax source.l
./lsyntax --outline source.l
./lsyntax --ast source.l
```

The repository tests require the compiled tool to parse substantial real source including Lace, not only synthetic parser examples.

`lib/portable/slang_decls.l` now carries the complete structured syntax needed for semantic checking: declaration generic parameters, recursive type syntax, constant initializers, function bodies, expressions, statements and patterns, all with source spans. This includes calls/indexing, operators, casts, `new`/dereference, struct literals, anonymous functions, assignments, loops, conditionals and matches.

## Project and name resolution

`lib/portable/slang_project.l` resolves already-loaded **logical modules**. Filesystem/package lookup deliberately remains outside the portable frontend and outside L Core.

It handles import bindings and aliases, duplicate module/module-scope names, builtin collisions, unresolved modules, import cycles and source visibility.

`lib/portable/slang_names.l` resolves runtime names inside executable bodies. It represents parameters, locals, loop and pattern bindings, anonymous-function parameters, top-level values, imports and builtins with stable identities. It enforces L's no-shadowing rule and the noncapturing anonymous-function rule, including the prohibition on silently shadowing an enclosing runtime name inside an anonymous function.

## Type identities

`lib/portable/slang_types.l` resolves syntax types into semantic `ResolvedType` trees. It handles primitives, generic parameters, local nominal types, imported source types, visibility, type arity, function types and explicit host opaque types supplied by the embedding environment.

Generic parameters remain abstract semantic types. This is important: generic declarations are checked once under abstract `T`, rather than being accepted or rejected only after a particular monomorphization.

## Semantic checker and `lcheck`

`lib/portable/slang_check.l` is now a real value/place/body checker rather than a syntax demo. `./lcheck FILE` exposes it as a native-running command:

```sh
./lcheck examples/core/linked_list.l
./lcheck examples/core/generic_queue.l
```

The checker currently covers the core value/place machinery needed by substantial programs: contextual numeric literals, arrays, optionals, refs, struct fields, builtins, function values, noncapturing anonymous functions, assignments and compound assignments, loops, returns, pattern bindings and nominal enum values.

Generic semantics are implemented structurally over semantic type trees:

- generic function bodies are checked abstractly;
- generic function calls infer arguments from call arguments and, when available, the expected result type;
- generic struct literals infer type arguments from fields and/or an expected nominal type;
- generic enum payloads and patterns substitute their subject/constructor arguments;
- generic nominal field access substitutes the receiver's actual type arguments;
- conflicting or incomplete inference is rejected;
- direct recursive generic calls may not change their type parameters;
- generic functions remain non-first-class values.

This is exercised by the real `examples/core/generic_queue.l` and by `tests/selfhost_checker_diff.py`.

### Differential testing

The Python checker is intentionally used as an oracle while the L checker is incomplete. The differential suite compares **accept/reject semantics**, not diagnostic wording, for representative programs and failure cases.

The corpus includes refs/optionals, nested places, arrays, enums/patterns, ordinary and anonymous function values, bad assignments/returns/arity/captures, generic identity/result inference, generic structs/enums, the generic queue example, conflicting/unconstrained inference and type-changing recursive generic calls.

A new semantic feature should normally add differential cases before it is considered complete.

## Runtime status

The frontend tools themselves run natively through the existing path:

```text
L tool/frontend source
  -> Python bootstrap checker + bytecode compiler
  -> bytecode embedded in generated C + native VM/runtime
  -> cc -O3
  -> native executable
```

Python is therefore still required to **build** the current L-written frontend, but not to execute the produced `lsyntax`, `lcheck`, Lace or LSP binaries.

## Remaining route to self-hosting

The highest-value remaining semantic work is to close the gap between `lcheck` and the Python Core checker rather than add unrelated language features. In particular:

1. **Complete checker semantics** — match exhaustiveness, remaining generic-recursion restrictions, imported source/host value members, constants, visibility details, and exact numeric/cast edge rules.
2. **Project-level `lcheck`** — feed multiple logical source modules and host declarations through the already-portable project/type/name layers instead of checking only one source module from the CLI.
3. **Checked IR** — lower the resolved AST to a representation in which symbol identity, types, places and generic instantiations are decided once. Backends should not repeat source lookup/type inference.
4. **Bytecode emitter in L** — target the existing bytecode/VM model first. Self-hosting should not depend on simultaneously inventing a second native backend.
5. **Bootstrap comparison** — use the Python compiler to build compiler C1; use C1 to compile the compiler again into C2; compare behavior and, where practical, deterministic artifacts across the conformance corpus.
6. **Tool convergence** — progressively move the LSP/analyzer onto the same syntax/symbol/type frontend so approximate duplicate parsers/resolvers can be deleted.

A direct C/native backend can remain a later independent backend. The existing VM is useful for bootstrapping, differential testing, teaching and debugging.

## What does not count as self-hosting

The project uses precise terminology:

- A tool **written in L and compiled by the Python bootstrap frontend** is L-written/native-running, not proof that the compiler is self-hosted.
- `L -> bytecode -> generated C + C VM -> executable` is native execution, but today the frontend producing that bytecode is still bootstrapped.
- Self-hosting is reached when the L-written compiler can compile the language implementation itself without the Python frontend for ordinary builds.

Until then, keeping the Python implementation is useful: it gives the project an independent oracle instead of letting the emerging self-hosted implementation silently define semantics by its own bugs.
