# L documentation

This directory contains the current draft specification, implementation guidance, tooling documentation, and design notes for **L**.

The project deliberately separates **L Core** from optional libraries, host capabilities, and tools. Read the documents appropriate to what you are trying to do rather than assuming the entire repository is part of the language.

## I want to try L

Start here:

1. [`12-LANGUAGE-TOUR.md`](12-LANGUAGE-TOUR.md) — a compact user-oriented tour.
2. [`../examples/core/linked_list.l`](../examples/core/linked_list.l) and [`../examples/core/generic_queue.l`](../examples/core/generic_queue.l) — small freestanding programs.
3. [`../README.md`](../README.md) — commands for `./lc`, `./lr`, Lace, and the bundled tools.

For the exact language rules, continue with [`01-CORE-LANGUAGE.md`](01-CORE-LANGUAGE.md) and [`03-CORE-SEMANTICS.md`](03-CORE-SEMANTICS.md).

## I want to implement L

A conforming implementation only needs **L Core**. It does not need the portable library, filesystem/process APIs, the bundled command-line host profile, Lace, or any LSP.

Recommended reading order:

1. [`00-ARCHITECTURE.md`](00-ARCHITECTURE.md) — what is Core and what is not.
2. [`01-CORE-LANGUAGE.md`](01-CORE-LANGUAGE.md) — compact language definition.
3. [`02-GRAMMAR.ebnf`](02-GRAMMAR.ebnf) — draft grammar.
4. [`03-CORE-SEMANTICS.md`](03-CORE-SEMANTICS.md) — operational details and edge cases.
5. [`04-CONFORMANCE.md`](04-CONFORMANCE.md) — what conformance means.
6. [`07-IMPLEMENTATION-GUIDE.md`](07-IMPLEMENTATION-GUIDE.md) — non-normative implementation advice and traps found by the reference implementations.

Then run:

```sh
python3 conformance/core_conformance.py
```

The conformance suite is still growing. Passing the current seed is evidence, not a claim that every unspecified corner has been standardized.

## I want to embed L or provide host APIs

Read:

- [`00-ARCHITECTURE.md`](00-ARCHITECTURE.md)
- [`05-HOST-MODULE-INTERFACE.md`](05-HOST-MODULE-INTERFACE.md)
- [`06-LIBRARIES.md`](06-LIBRARIES.md)

Core module names are logical names. Files, paths, package repositories, `main`, command-line arguments, processes, terminals, and networking are environment choices rather than Core semantics.

## I want to work on the compiler or tools

Read:

- [`07-IMPLEMENTATION-GUIDE.md`](07-IMPLEMENTATION-GUIDE.md)
- [`08-TOOLCHAIN-AND-STATUS.md`](08-TOOLCHAIN-AND-STATUS.md)
- [`11-CODE-ANALYSIS.md`](11-CODE-ANALYSIS.md)
- [`13-ROADMAP.md`](13-ROADMAP.md)
- [`14-SELF-HOSTING.md`](14-SELF-HOSTING.md)

The current bootstrap frontend is Python. Native executables use the C VM/runtime with tracing GC. Lace and the bundled L/JSON/INI language servers are written in L. The standalone `lsyntax` checker is the first L-written compiler-frontend component promoted into a native command-line tool.

## I want to review the design

Read the specification first, then the rationale and open questions:

- [`09-DESIGN-RATIONALE.md`](09-DESIGN-RATIONALE.md)
- [`10-OPEN-QUESTIONS.md`](10-OPEN-QUESTIONS.md)
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
