# Self-hosting progress

The production/bootstrap frontend used by `./lc` is still Python, but self-hosting is being developed incrementally rather than as a flag-day compiler rewrite.

The rule for this work is:

> each self-hosting slice should become an independently useful, tested L-written tool before it replaces bootstrap code.

That lets the project compare the L implementation against the mature bootstrap frontend and keeps failures localized.

## Current first slice: `lsyntax`

`lib/portable/slang_syntax.l` contains an L-written lexer and recursive-descent/precedence parser for L syntax. It was originally developed for the L language server.

`tools/syntax/lsyntax.l` now turns that parser into a standalone command-line checker written in L:

```sh
./lsyntax source.l
```

`./lsyntax` builds on demand to `build/lsyntax` through the same native path used for Lace and the language servers:

```text
lsyntax.l + portable L parser
  -> Python bootstrap checker/bytecode compiler
  -> generated C + native VM/runtime
  -> cc -O3
  -> build/lsyntax
```

At runtime, `lsyntax` itself does not use Python. It reads the source through the typed `fs` host module and diagnoses it with the L-written lexer/parser.

Successful input exits 0. Syntax errors exit 1 and use conventional diagnostics:

```text
file.l:12:8: error: expected token
```

Usage/read failures exit 2.

The repository test suite checks that the compiled tool:

- accepts freestanding Core examples;
- accepts the substantial Lace editor source;
- rejects malformed source.

This is intentionally a **syntax** checker. It does not yet resolve names or type-check programs, and it is not a replacement for `./lc --check`.

## Why start here?

The syntax frontend is a good first self-hosted component because it exercises a large part of the language without creating a bootstrap cycle around semantic typing:

- byte-oriented source processing;
- arrays and structs;
- enums;
- parser state through `ref`;
- ordinary loops and recursive-descent functions;
- error accumulation/recovery;
- portable library modules;
- host I/O only at the CLI boundary.

It also creates immediate reuse pressure: the compiler, LSP, formatter, analysis tools, and future self-hosted checker should converge on one syntax representation rather than each acquiring a private parser.

## Next slices

The intended progression is roughly:

1. **Structured syntax tree** — extend the L parser from syntax validation to a reusable parsed representation with source spans and stable declaration/name nodes.
2. **Module/name resolution** — canonical declaration identities, imports/visibility, lexical scopes, and no-shadowing checks.
3. **Type representation and checker** — implement current Core type rules, expected-type propagation, generic declaration checking, exact generic-call inference, places, return analysis, and match exhaustiveness.
4. **Checked intermediate representation** — execution/codegen must consume identities/types resolved once by the frontend rather than redoing lookup at runtime.
5. **Bytecode emitter in L** — produce the existing bytecode model first so self-hosting is not coupled to inventing another backend.
6. **Bootstrap** — compile the L compiler with the bootstrap compiler, then have that compiler compile itself and compare behavior/artifacts on the conformance corpus.

The L language server should migrate onto the same structured/resolved frontend as these pieces become available.

## What does not count as self-hosting

The project tries to use precise terminology:

- A tool **written in L and compiled by the Python bootstrap frontend** is an L-written/native-running tool, not evidence that the compiler is self-hosted.
- The current `L -> bytecode -> generated C + C VM -> executable` path is native execution, but the frontend is still bootstrapped.
- Self-hosting is reached when the L-written compiler can compile the language implementation itself without requiring the Python frontend for ordinary builds.

Until then, the Python implementation remains an important independent oracle for differential testing rather than something to delete prematurely.
