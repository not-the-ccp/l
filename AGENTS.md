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
