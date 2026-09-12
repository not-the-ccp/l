# AGENTS.md

This repository contains the L language, its reference/bootstrap implementation, optional libraries, and tooling.

## Before changing language design

Read:

1. `docs/architecture/00-architecture.md`
2. `docs/language/01-core-language.md`
3. `docs/language/03-core-semantics.md`
4. `docs/design/09-design-rationale.md`
5. `docs/design/10-open-questions.md`

Then run:

```sh
python3 tests/core_conformance.py
scripts/test.sh
```

## Boundaries

- `docs/` defines the intended language; the Python implementation is not automatically normative.
- `lib/std/` is optional library code, not Core.
- `lib/host/` and typed host modules are environment-specific, not Core.
- `tools/` must not be used as evidence that every L implementation must provide those capabilities.

## Implementation notes

The current compiler frontend is Python-bootstrapped. Native outputs use `src/vm/vm.c` and tracing GC. Lace, the LSP servers, `lsyntax`, and `lcheck` are written in L.

Generated files belong under `build/`; do not commit them.
`build/` and `__pycache__/` are generated and never committed;
`./scripts/build.sh clean` clears `build/`. Test and build runs set
`PYTHONDONTWRITEBYTECODE=1` (plus `sys.dont_write_bytecode` in the
`scripts/lc`/`scripts/lr` launchers) so no `__pycache__` is left in the tree.

The `VERSION` file at the repository root is the single source of truth for
the toolchain version. `src/lang/cli_common.py` reads it at import time for
`scripts/lc --version` / `scripts/lr --version`; do not duplicate the
version string anywhere else.

## Docs-coherence rule (binding)

Any commit changing language semantics, stdlib API, host API, or toolchain
behavior MUST update the corresponding docs in the SAME commit, or the commit
is subject to revert on review. Mapping:

- Core semantics/grammar/checker/VM behavior -> `docs/language/01-core-language.md`
  + `docs/language/02-grammar.ebnf` (if syntax) + `docs/language/03-core-semantics.md`
  + `docs/language/12-language-tour.md` (if user-visible) + conformance vectors.
- Rationale/considered-alternatives -> `docs/design/09-design-rationale.md`.
- Open/deferred questions -> `docs/design/10-open-questions.md` (move on resolve).
- Stdlib API/behavior (`lib/std/`, `lib/slang/`) -> the module's doc header
  + hosted/tour examples that use it.
- Host/toolchain API or behavior (`lib/host/`, `src/hosts/`, `src/vm/`,
  `tools/`, `scripts/`) -> `docs/language/05-host-module-interface.md`
  (boundary) or `docs/architecture/00-architecture.md` (layering) + tool docs.
- Note: host files live at `src/vm/embed.c` + `src/vm/embed.h`, `src/hosts/`, `lib/host/`.
- New privileged text/string representation or freezing rule -> architecture doc
  §1/`09` rationale entry (text is currently deliberate non-Core; changing that
  is a layering change, not a patch).

Review checklist (reviewer verifies all that apply):
[ ] spec + grammar + semantics + tour agree (no stale sentence left);
[ ] `tests/check_docs.py` and `python3 tests/core_conformance.py` pass;
[ ] `./scripts/test.sh` passes from repo root;
[ ] stdlib/host renames carry the deprecation alias for one release;
[ ] `10-open-questions.md` updated (resolved moved, deferred recorded w/ trigger).

## Test conventions

- Tests live in `tests/`: `core_conformance.py` (Core conformance seed),
  `check_docs.py` (documentation reference gate), plus toolchain/editor/LSP
  integration tests (`*_test.py`, `test_*.py`, `check_*.py`).
- Run the full suite with `./scripts/test.sh` from the repository root. It
  self-bootstraps `PYTHONPATH` to `src/` and wires every gate, including
  `python3 tests/core_conformance.py` and `python3 tests/check_docs.py`,
  which can also be run individually as above.
- Naming: `tests/check_*.py` are gates that fail the suite on violation;
  `tests/*_test.py` and `tests/test_*.py` are behavioral integration tests;
  `examples/core/*.l` are freestanding Core programs also exercised by the
  native `lsyntax`/`lcheck` smoke checks in `scripts/test.sh`.
- Library module names are logical names resolved from `lib/std/` (portable),
  `lib/slang/` (self-hosting frontend slices), and `lib/host/` (host-dependent).
  Do not use the pre-rename core-library path; `tests/check_docs.py` forbids it.
