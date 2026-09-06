# L documentation

This directory contains the current draft specification, implementation guidance, tooling documentation, and design notes for **L**.

The project deliberately separates **L Core** from optional libraries, host capabilities, and tools. Read the documents appropriate to what you are trying to do rather than assuming the entire repository is part of the language.

## I want to try L

Start here:

1. [`language/12-language-tour.md`](language/12-language-tour.md) — a compact user-oriented tour.
2. [`../examples/core/linked_list.l`](../examples/core/linked_list.l), [`../examples/core/generic_queue.l`](../examples/core/generic_queue.l), and [`../examples/core/collections.l`](../examples/core/collections.l) — freestanding examples from linked data structures through reusable generics.
3. [`../README.md`](../README.md) — commands for `./lc`, `./lr`, Lace, and the bundled tools.

For the exact language rules, continue with [`language/01-core-language.md`](language/01-core-language.md) and [`language/03-core-semantics.md`](language/03-core-semantics.md).

## I want to implement L

A conforming implementation only needs **L Core**. It does not need the portable library, filesystem/process APIs, the bundled command-line host profile, Lace, or any LSP.

Recommended reading order:

1. [`architecture/00-architecture.md`](architecture/00-architecture.md) — what is Core and what is not.
2. [`language/01-core-language.md`](language/01-core-language.md) — compact language definition.
3. [`language/02-grammar.ebnf`](language/02-grammar.ebnf) — draft grammar.
4. [`language/03-core-semantics.md`](language/03-core-semantics.md) — operational details and edge cases.
5. [`language/04-conformance.md`](language/04-conformance.md) — what conformance means.
6. [`guides/07-implementation-guide.md`](guides/07-implementation-guide.md) — non-normative implementation advice and traps found by the reference implementations.

Then run:

```sh
python3 tests/core_conformance.py
```

The conformance suite is still growing. Passing the current seed is evidence, not a claim that every unspecified corner has been standardized.

## I want to use or extend the portable library

Read:

- [`architecture/06-libraries.md`](architecture/06-libraries.md) — layering/policy;
- [`architecture/15-portable-library.md`](architecture/15-portable-library.md) — current source-level modules, collections, algorithms, semantics, and tests.

The portable library is ordinary L and remains optional for Core implementations.

## I want to embed L or provide host APIs

Read:

- [`architecture/00-architecture.md`](architecture/00-architecture.md)
- [`language/05-host-module-interface.md`](language/05-host-module-interface.md)
- [`architecture/06-libraries.md`](architecture/06-libraries.md)

Core module names are logical names. Files, paths, package repositories, `main`, command-line arguments, processes, terminals, and networking are environment choices rather than Core semantics.

## I want to work on the compiler or tools

Read:

- [`guides/07-implementation-guide.md`](guides/07-implementation-guide.md)
- [`guides/08-toolchain-and-status.md`](guides/08-toolchain-and-status.md)
- [`guides/11-code-analysis.md`](guides/11-code-analysis.md)
- [`guides/13-roadmap.md`](guides/13-roadmap.md)
- [`guides/14-self-hosting.md`](guides/14-self-hosting.md)

The current bootstrap frontend is Python. Native executables use the C VM/runtime with tracing GC. Lace and the bundled L/JSON/INI language servers are written in L. The standalone `lsyntax` checker is the first L-written compiler-frontend component promoted into a native command-line tool.

## I want to review the design

Read the specification first, then the rationale and open questions:

- [`design/09-design-rationale.md`](design/09-design-rationale.md)
- [`design/10-open-questions.md`](design/10-open-questions.md)
- [`../review/AGENT-PROMPT.md`](../review/AGENT-PROMPT.md)
- [`../review/REVIEW-GUIDE.md`](../review/REVIEW-GUIDE.md)

The implementation is not automatically normative. A mismatch between the implementation, grammar, prose specification, tests, and examples is a useful bug report.

## Document status

L is pre-1.0. These documents describe the current design snapshot and are expected to evolve from implementation experience and review.

The rough authority order is:

1. deliberate Core specification text;
2. explicit conformance decisions/tests;
3. clarified design decisions recorded in the repository;
4. current implementation behavior as evidence only.

Historical material under `notes/` is non-normative and may describe superseded versions of the language.
