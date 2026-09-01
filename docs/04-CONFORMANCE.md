# L Core conformance target

The purpose of this profile is to give an implementer a **small, finite target** independent of libraries and operating-system services.

## Required for Core conformance

A Core implementation must implement the syntax/static/runtime semantics in the Core specification, including:

- all Core scalar and compound types;
- `?T`, `ref T`, and `[]T`;
- real reachability safety for managed objects (indefinite leaking is not considered an acceptable production/conformance memory implementation for this project goal);
- structs/enums;
- unconstrained generics and the current recursion restrictions;
- top-level function values and noncapturing anonymous functions;
- modules, imports, `pub`, private fields, and cycle rejection;
- array core operations `len`, `push`, `pop`, `splice`;
- exact arithmetic/trap/evaluation-order/place semantics;
- pattern/exhaustiveness rules.

## Explicitly not required

A Core implementation need not provide:

- any particular library module;
- `arrays`, `bytes`, `json`, `utf8`, etc.;
- file I/O;
- stdin/stdout;
- command-line arguments;
- `main`;
- process/terminal APIs;
- a package manager;
- a file-to-module naming convention;
- LSP or an editor;
- native code generation;
- C interoperability.

## Embedding model

A minimal conformance harness may provide source modules from an in-memory mapping:

```text
("math",) -> source string
("test",) -> source string
```

and invoke a named function directly after checking/linking.

This is enough to test Core without inventing an OS profile.

## Memory conformance

The semantic requirement is no dangling reachable references and correct handling of cycles/aliasing. A host-language interpreter may rely on the host's tracing collector if it actually reclaims unreachable cycles.

For native/long-running implementations, permanently leaking all `new`/array objects is deliberately **not** accepted as satisfying the implementation goal, even though collection timing is semantically invisible.

## Test layout in this bundle

`conformance/core_conformance.py` is a core-only executable smoke/conformance suite against the included Python reference implementation. It deliberately supplies:

```text
portable libraries: none
host modules:       none
```

The suite is intended as a seed, not yet a formal language certification corpus. Reviewers are encouraged to add adversarial cases.

## Recommended independent implementation progression

1. lexer + parser;
2. resolver/type checker;
3. tree interpreter using host GC;
4. module linker;
5. bytecode compiler + VM;
6. independent conformance cross-check;
7. optional native backend and collector.

A complete tree interpreter is a valid serious Core implementation; native code generation is not required for language conformance.
