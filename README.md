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
scripts/lr examples/hosted/hello.l -- hello world

# Compile to a native executable using the bytecode + C runtime path.
scripts/lc examples/hosted/hello.l -o hello
./hello hello world

# Run the first standalone frontend component written in L itself.
scripts/lsyntax examples/core/linked_list.l

# Open files in Lace. The matching L/JSON/INI LSP is selected automatically.
scripts/lace examples/hosted/hello.l
scripts/lace examples/hosted/config.json
scripts/lace examples/hosted/config.ini
```

`scripts/lace` and `scripts/lsyntax` build their native `-O3` executables into `build/` on first use. To build the bundled native tools explicitly:

```sh
scripts/build.sh
```

Run the complete repository test suite:

```sh
scripts/test.sh
```

Run only the freestanding Core conformance seed:

```sh
python3 tests/core_conformance.py
```

## Learn the language

If you want to **write L**, start with the [language tour](docs/language/12-language-tour.md).

If you want to **implement L**, start with the [documentation index](docs/index.md), then read the architecture, Core specification, grammar, semantics, and conformance documents.

Useful entry points:

- [Documentation index](docs/index.md)
- [Language tour](docs/language/12-language-tour.md)
- [Architecture / Core boundary](docs/architecture/00-architecture.md)
- [Core language specification](docs/language/01-core-language.md)
- [Draft EBNF grammar](docs/language/02-grammar.ebnf)
- [Detailed Core semantics](docs/language/03-core-semantics.md)
- [Conformance](docs/language/04-conformance.md)
- [Implementation guide](docs/guides/07-implementation-guide.md)
- [Design rationale](docs/design/09-design-rationale.md)
- [Open design questions](docs/design/10-open-questions.md)
- [Code analysis and flowcharts](docs/guides/11-code-analysis.md)
- [Roadmap](docs/guides/13-roadmap.md)
- [Self-hosting progress](docs/guides/14-self-hosting.md)

The specification is still a draft. The implementation is evidence, not automatically normative; disagreements between implementation and specification are bugs worth reporting.

## Current implementation

The frontend used by `scripts/lc` is still **bootstrapped in Python**. It parses, links, type-checks, compiles L to bytecode, embeds that bytecode into a native C VM/runtime, and invokes `cc -O3` to produce a native executable:

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
scripts/lc analyze examples/core/linked_list.l

# Mermaid CFG.
scripts/lc analyze examples/core/linked_list.l --flowchart -o linked-list.mmd

# Graphviz CFG.
scripts/lc analyze examples/core/linked_list.l --view cfg --format dot -o linked-list.dot

# Machine-readable project/function/CFG model.
scripts/lc analyze examples/core/linked_list.l --view model > analysis.json
```

It can emit CFGs, call graphs, metrics, parser ASTs, Mermaid, Graphviz DOT/SVG, and JSON. This is optional tooling, not part of L Core. See [the analysis documentation](docs/guides/11-code-analysis.md).

## Repository layout

```text
src/             reference lexer/parser/checker/interpreter/bytecode compiler (src/lang),
                 hosted command-line profiles (src/hosts), Python tooling (src/tools)
src/vm/          native C VM and tracing runtime (src/vm/vm.c)
lib/core/        optional portable libraries written in L
lib/host/        optional libraries that depend on host modules
lib/slang/       L-written self-hosting frontend slices (syntax through checking)
tools/lace/      Lace modal terminal editor, written in L
tools/lsp/       L, JSON, and INI LSP servers, written in L
tools/check/     L-written syntax and semantic checker tools
tools/shell/     L-written shell, written in L
scripts/         repository launchers (lr, lc, lsyntax, lcheck, lace, LSPs) and test/build scripts
tests/           Core conformance seed plus toolchain/editor/LSP integration tests
docs/            language specification, guides, roadmap, tooling docs
examples/        Core and hosted examples
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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Core changes should normally include conformance tests and corresponding specification changes.

The project is licensed under the [MIT License](LICENSE).

## Status

Experimental and pre-1.0. The design has been driven by implementation experiments, multiple execution backends, substantial L-written libraries/tooling, and actual editor/LSP usage, but neither the specification nor APIs should be considered stable yet.
