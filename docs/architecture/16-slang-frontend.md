# lib/slang: the L-written self-hosting frontend

`lib/slang/` holds the replacement compiler frontend, written in L. It is
ordinary portable library code — not L Core — and it is still compiled by the
Python bootstrap frontend, so this is self-hosting *progress*, not yet a
self-hosted compiler. See `../guides/14-self-hosting.md` for the full
pipeline narrative and remaining route; this page fixes the layer role and
module map.

## Layer role

- `lib/slang/` modules use only L Core plus other portable libraries
  (notably `lib/std/`). They require no host capability.
- Filesystem/package lookup stays outside the portable frontend: `project`
  resolves already-loaded **logical modules** supplied by the embedding
  environment (see `../guides/14-self-hosting.md`).
- The Python implementation in `src/lang/` remains the independent semantic
  oracle until the L-written frontend can compile itself. Differential
  accept/reject testing (`tests/selfhost_checker_diff.py`) compares the two;
  diagnostic wording is not compared.
- Native execution (`build/lsyntax`, `build/lcheck`) proves the L code runs
  natively, not that the compiler is self-hosted: the bytecode those binaries
  embed is still produced by the Python bootstrap checker and compiler.

## Module map (pipeline order)

| Module | File | Role |
|---|---|---|
| `slang_syntax` | `syntax.l` | Lexer plus syntax validation/recovery parser |
| `slang_index` | `index.l` | Stable top-level import/declaration view (identities, spans) |
| `slang_project` | `project.l` | Logical-module resolution: bindings, aliases, duplicates, cycles, visibility |
| `slang_decls` | `decls.l` | Full structured declarations: generics, recursive type syntax, constant initializers, complete executable bodies with spans |
| `slang_names` | `names.l` | Lexical value-name/scope resolution; enforces no-shadowing and noncapturing anonymous functions |
| `slang_types` | `types.l` | Syntax types resolved to semantic type trees (generics stay abstract) |
| `slang_check` | `check.l` | Value/place/body semantic checker |

Because `lib/slang/` filenames are pipeline-stage names, the host layer
imports them under historical `slang_*` module names
(`src/hosts/run.py:COMMON`, `src/tools/_sdk_cli.py:SLANG_MODULE_NAMES`).

## Current limits

- `slang_check` covers the core value/place machinery (arrays, optionals,
  refs, structs, builtins, function values, noncapturing anonymous functions,
  assignments, loops, returns, patterns, nominal enums, structural generics)
  but the Python checker remains the oracle for the gap: match
  exhaustiveness, remaining generic-recursion restrictions, imported
  source/host value members, top-level `const` declarations and constant
  evaluation, visibility details, and exact numeric/cast edge rules.
- `scripts/lcheck` checks a single source module from the CLI; project-level
  checking across multiple logical modules plus host declarations is still on
  the roadmap in `../guides/14-self-hosting.md`.
