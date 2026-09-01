# L layering and architecture

## 1. L Core

**L Core** is the language proper. A conforming Core implementation provides:

- UTF-8 source decoding and the lexical grammar;
- parsing of declarations, statements, expressions, patterns, and types;
- static name/type checking;
- logical source modules and visibility rules;
- fixed-width scalar semantics;
- structs, enums, optionals, dynamic arrays, managed references, functions, and unit;
- unconstrained parametric generics;
- deterministic left-to-right evaluation;
- bounds/trap semantics;
- managed reachability semantics for `ref T` and `[]T`;
- the four core dynamic-array operations `len`, `push`, `pop`, and `splice`.

L Core does **not** define:

- a filesystem;
- source filename extensions or directory layout;
- a command called `lc`, `l`, or anything else;
- a mandatory `main` function;
- standard input/output;
- environment variables;
- processes;
- networking;
- threads or async;
- a C ABI;
- JSON, Unicode text operations, collections such as maps, or any other library module.

A core implementation may be an embedded evaluator whose host supplies source modules from memory and directly invokes an exported function.

## 2. Portable L libraries

Portable libraries are ordinary L source code using only L Core and other portable libraries.

The current bundle includes examples such as:

- `arrays`
- `bytes`
- `strconv`
- `utf8`
- `json`
- `lsp` (protocol data/framing helpers, without process I/O)
- `slang_syntax` (an L syntax frontend written in L)

These are **not required for L Core conformance**. An implementation can ship none of them, a subset, replacements, or a larger ecosystem.

The long-term intent is that most reusable algorithms and data structures live here rather than becoming compiler intrinsics.

## 3. Host modules

A host or embedding environment may provide typed modules whose implementation is not L source.

Examples in the reference hosted environment are:

- `stdio`
- `fs`
- `sys`
- `proc`
- `term`

The language specification defines the *shape of the boundary*, not these module names or APIs. A microcontroller implementation might expose `gpio` and `uart`; a browser implementation could expose entirely different modules; a puzzle runner may expose nothing except an entry function.

Host modules may also expose opaque nominal types such as a process handle. Their representation is never visible to L code.

## 4. Hosted profiles

A distribution may define a **hosted profile**: a convention about available host modules, entry points, file-to-module resolution, command-line behavior, and library selection.

The current Unix-like reference profile maps logical module `foo.bar` to `foo/bar.l`, expects an entry `main`, and supplies process/filesystem/terminal modules. None of those conventions are part of L Core.

## 5. Tools

Tools are programs built around or in L:

- bootstrap compiler/runner;
- bytecode VM and native VM;
- L/JSON/INI LSP servers;
- Lace modal editor;
- formatters, tests, etc.

Tool requirements should not silently become language requirements. In particular, terminal display width, process signaling, filesystem semantics, and LSP UTF-16 coordinates belong at host/tool boundaries.

## 6. Why make the split this strict?

The project began with the goal that an implementer should be able to build a complete serious interpreter/compiler as a learning exercise without first implementing a giant standard environment.

The split also keeps experimentation cheap. A new collection API, regex engine, shell/process convention, or Unicode library can evolve without changing every L compiler.
