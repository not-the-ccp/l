# L

**L** is an experimental small C-family programming language designed around one constraint:

> be serious enough for ordinary programs, while remaining unusually simple to parse, interpret, compile, embed, and tool.

[![CI](https://github.com/not-the-ccp/l/actions/workflows/ci.yml/badge.svg)](https://github.com/not-the-ccp/l/actions/workflows/ci.yml)

This repository contains the draft language specification, reference/bootstrap implementation, native runtime, portable libraries, conformance tests, source-analysis tooling, LSP servers, and the **Lace** modal terminal editor.

The project is intentionally layered. Implementing **L Core** does **not** require implementing the portable library, operating-system APIs, Lace, or any LSP.

```text
L Core
  syntax + types + semantics + managed memory + logical modules
        |
        +-- optional portable libraries written in L
        +-- optional host modules / hosted environment
        +-- optional tools (compiler, analyzer, LSPs, Lace, ...)
```

## Try it

Requirements for the current bootstrap toolchain:

- Python 3.11+
- a C11 compiler available as `cc` (or set `CC`)
- a POSIX-like environment for Lace and the bundled host modules

No PATH setup is required.

```sh
# Run a hosted program.
./lr examples/hosted/hello.l -- hello world

# Compile to a native executable using the bytecode + C runtime path.
./lc examples/hosted/hello.l -o hello
./hello hello world

# Run the first standalone frontend component written in L itself.
./lsyntax examples/core/linked_list.l

# Open files in Lace. The matching L/JSON/INI LSP is selected automatically.
./lace examples/hosted/hello.l
./lace examples/hosted/config.json
./lace examples/hosted/config.ini
```

`./lace` and `./lsyntax` build their native `-O3` executables into `build/` on first use. To build the bundled native tools explicitly:

```sh
./build.sh
```

Run the complete repository test suite:

```sh
./test.sh
```

Run only the freestanding Core conformance seed:

```sh
python3 conformance/core_conformance.py
```

## Learn the language

If you want to **write L**, start with the [language tour](docs/12-LANGUAGE-TOUR.md).

If you want to **implement L**, start with the [documentation index](docs/README.md), then read the architecture, Core specification, grammar, semantics, and conformance documents.

Useful entry points:

- [Documentation index](docs/README.md)
- [Language tour](docs/12-LANGUAGE-TOUR.md)
- [Architecture / Core boundary](docs/00-ARCHITECTURE.md)
- [Core language specification](docs/01-CORE-LANGUAGE.md)
- [Draft EBNF grammar](docs/02-GRAMMAR.ebnf)
- [Detailed Core semantics](docs/03-CORE-SEMANTICS.md)
- [Conformance](docs/04-CONFORMANCE.md)
- [Implementation guide](docs/07-IMPLEMENTATION-GUIDE.md)
- [Design rationale](docs/09-DESIGN-RATIONALE.md)
- [Open design questions](docs/10-OPEN-QUESTIONS.md)
- [Code analysis and flowcharts](docs/11-CODE-ANALYSIS.md)
- [Roadmap](docs/13-ROADMAP.md)
- [Self-hosting progress](docs/14-SELF-HOSTING.md)

The specification is still a draft. The implementation is evidence, not automatically normative; disagreements between implementation and specification are bugs worth reporting.

## Current implementation

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

Lace, the bundled L/JSON/INI language servers, and `lsyntax` are themselves written in L and are built through this path. `lsyntax` is deliberately the first promoted self-hosting slice: it uses the L-written lexer/parser at runtime and is tested against real and malformed L source. It is a syntax checker, not yet a replacement for the Python semantic frontend.

A fully self-hosted compiler is a major pre-1.0 milestone rather than something the repository currently claims to have.

## Source analysis and flowcharts

The compiler frontend also exposes a reusable source-analysis pipeline:

```sh
# Human-readable metrics/findings.
./lc analyze examples/core/linked_list.l

# Mermaid CFG.
./lc analyze examples/core/linked_list.l --flowchart -o linked-list.mmd

# Graphviz CFG.
./lc analyze examples/core/linked_list.l --view cfg --format dot -o linked-list.dot

# Machine-readable project/function/CFG model.
./lc analyze examples/core/linked_list.l --view model > analysis.json
```

It can emit CFGs, call graphs, metrics, parser ASTs, Mermaid, Graphviz DOT/SVG, and JSON. This is optional tooling, not part of L Core. See [the analysis documentation](docs/11-CODE-ANALYSIS.md).

## Repository layout

```text
bootstrap/       reference lexer/parser/checker/interpreter/bytecode compiler
runtime/         native C VM and tracing runtime
lib/portable/    optional portable libraries written in L
lib/hosted/      optional libraries that depend on host modules
tools/lace/      Lace editor source, written in L
tools/lsp/       L, JSON, and INI LSP servers, written in L
tools/syntax/    standalone L-written syntax frontend tool
conformance/     Core-only implementation tests
tests/           toolchain/editor/LSP integration tests
docs/            language specification, guides, roadmap, tooling docs
review/          material for independent human/AI review
examples/        Core and hosted examples
notes/           historical implementation/user-study evidence
```

Generated native tools live in `build/` and are intentionally ignored by Git.

## L Core versus libraries

The normative goal of L Core is deliberately small. A conforming Core implementation does not need:

- JSON, UTF-8 helpers, maps, heaps, formatting, etc.;
- filesystem, process, terminal, networking, or stdin/stdout APIs;
- a filesystem-based module resolver;
- a `main` convention;
- Lace or any LSP.

Logical modules are part of Core; **how module names resolve to source/host modules is an implementation/embedding concern**.

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

The default policy is **not** to grow Core just because another language has a convenient feature. New mechanisms should be justified by recurring problems demonstrated in real L code and weighed against their cost to interpreters, compilers, formatters, LSPs, and independent implementations.

## Independent review

This repository is intended to be reviewable by people or coding agents without the original design conversation.

For an independent review, start with:

- [`AGENTS.md`](AGENTS.md)
- [`review/AGENT-PROMPT.md`](review/AGENT-PROMPT.md)
- [`review/REVIEW-GUIDE.md`](review/REVIEW-GUIDE.md)
- [`review/FEEDBACK-TEMPLATE.md`](review/FEEDBACK-TEMPLATE.md)

Feedback is not expected to preserve current decisions. Concrete counterexamples, implementation experiments, spec/implementation mismatches, and user-code experience are especially useful.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Core changes should normally include conformance tests and corresponding specification changes.

The project is licensed under the [MIT License](LICENSE).

## Status

Experimental and pre-1.0. The design has been driven by implementation experiments, multiple execution backends, substantial L-written libraries/tooling, and actual editor/LSP usage, but neither the specification nor APIs should be considered stable yet.
