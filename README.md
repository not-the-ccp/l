# L

**L** is an experimental small C-family programming language designed around one constraint:

> be serious enough for ordinary programs, while remaining unusually simple to parse, interpret, compile, embed, and tool.

This repository contains the language specification, reference/bootstrap implementation, native runtime, portable libraries, conformance tests, LSP servers, and the **Lace** modal terminal editor.

The project is intentionally layered. Implementing **L Core** does **not** require implementing the standard library, operating-system APIs, Lace, or any LSP.

```text
L Core
  syntax + types + semantics + managed memory + logical modules
        |
        +-- optional portable libraries written in L
        +-- optional host modules / hosted environment
        +-- optional tools (compiler, LSPs, Lace, ...)
```

## Try it

Requirements for the current bootstrap toolchain:

- Python 3.11+
- a C11 compiler available as `cc` (or set `CC`)
- POSIX-like environment for Lace and the bundled host modules

No PATH setup is required.

```sh
./lr examples/hosted/hello.l -- hello world

./lc examples/hosted/hello.l -o hello
./hello hello world

./lace examples/hosted/hello.l
./lace examples/hosted/config.json
./lace examples/hosted/config.ini
```

`./lace` builds the native `-O3` editor/LSP executables into `build/` on first use. To build them explicitly:

```sh
./build.sh
```

Run the test suite:

```sh
./test.sh
```

Run only the freestanding Core conformance seed:

```sh
python3 conformance/core_conformance.py
```

## Current implementation status

The frontend used by `./lc` is still **bootstrapped in Python**. It parses, links, type-checks, compiles L to bytecode, embeds that bytecode into a native C VM/runtime, and invokes `cc -O3` to produce a native executable:

```text
L source
  -> Python bootstrap frontend/checker
  -> L bytecode
  -> generated C + native VM/runtime
  -> cc -O3
  -> executable
```

The resulting program does not execute through Python. The native runtime includes tracing garbage collection.

Lace and the bundled L/JSON/INI language servers are themselves written in L and are built through this path.

A fully self-hosted compiler is a future milestone.

## Repository layout

```text
bootstrap/       reference lexer/parser/checker/interpreter/bytecode compiler
runtime/         native C VM and tracing runtime
lib/portable/    optional portable libraries written in L
lib/hosted/      optional libraries that depend on host modules
tools/lace/      Lace editor source, written in L
tools/lsp/       L, JSON, and INI LSP servers, written in L
conformance/     Core-only implementation tests
tests/           toolchain/editor/LSP integration tests
docs/            draft language specification and implementation guidance
review/          material for independent human/AI review
examples/        Core and hosted examples
notes/           historical implementation/user-study evidence
```

Generated native tools live in `build/` and are intentionally ignored by Git.

## L Core versus libraries

The normative goal of L Core is deliberately small. A conforming Core implementation does not need:

- JSON, UTF-8 helpers, maps, heaps, formatting, etc.
- filesystem, process, terminal, networking, or stdin/stdout APIs;
- a filesystem-based module resolver;
- a `main` convention;
- Lace or any LSP.

Logical modules are part of Core; **how module names resolve to source/host modules is an implementation/embedding concern**.

Start with:

1. [`docs/00-ARCHITECTURE.md`](docs/00-ARCHITECTURE.md)
2. [`docs/01-CORE-LANGUAGE.md`](docs/01-CORE-LANGUAGE.md)
3. [`docs/02-GRAMMAR.ebnf`](docs/02-GRAMMAR.ebnf)
4. [`docs/03-CORE-SEMANTICS.md`](docs/03-CORE-SEMANTICS.md)
5. [`docs/04-CONFORMANCE.md`](docs/04-CONFORMANCE.md)

The specification is still a draft. The implementation is evidence, not automatically normative; disagreements between implementation and specification are bugs worth reporting.

## Design snapshot

Some characteristic choices are:

- fixed-width numeric types;
- `()` as unit;
- `ref T` is non-null and can only refer to explicitly allocated `new` objects;
- absence is `?T` with `none` / `some(...)`, not `null`;
- dynamic arrays are `[]T`; byte strings are simply `[]u8`;
- structs and tagged enums;
- small unconstrained parametric generics;
- first-class top-level functions and non-capturing anonymous functions;
- no classes, methods, inheritance, traits/interfaces, exceptions, macros, raw pointers, manual `free`, or capturing closures;
- left-to-right evaluation and very little undefined/implementation-defined behavior;
- line-independent lexing: no multiline strings/comments/continuations;
- host capabilities enter through typed logical modules rather than a standardized C FFI.

See [`docs/09-DESIGN-RATIONALE.md`](docs/09-DESIGN-RATIONALE.md) for reasoning and [`docs/10-OPEN-QUESTIONS.md`](docs/10-OPEN-QUESTIONS.md) for deliberately unsettled areas.

## Independent review

This repository is intended to be reviewable by people or coding agents without the original design conversation.

For an independent review, start with:

- [`AGENTS.md`](AGENTS.md)
- [`review/AGENT-PROMPT.md`](review/AGENT-PROMPT.md)
- [`review/REVIEW-GUIDE.md`](review/REVIEW-GUIDE.md)
- [`review/FEEDBACK-TEMPLATE.md`](review/FEEDBACK-TEMPLATE.md)

Feedback is not expected to preserve current decisions. Concrete counterexamples, implementation experiments, spec/implementation mismatches, and user-code experience are especially useful.

## Initialize a repository

This bundle is deliberately ready to become a new Git repository:

```sh
git init
git add .
git commit -m 'Initial L language snapshot'
git branch -M main
git remote add origin git@github.com:YOU/l.git
git push -u origin main
```

The project is licensed under the MIT License; see [LICENSE](LICENSE) for the full terms.

## Project status

Experimental and pre-1.0. The design has been driven by implementation experiments, multiple execution backends, substantial L-written libraries/tooling, and actual editor/LSP usage, but neither the specification nor APIs should be considered stable yet.
