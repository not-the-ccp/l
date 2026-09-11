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
- `lib/core/` is optional library code, not Core.
- `lib/host/` and typed host modules are environment-specific, not Core.
- `tools/` must not be used as evidence that every L implementation must provide those capabilities.

## Implementation notes

The current compiler frontend is Python-bootstrapped. Native outputs use `src/vm/vm.c` and tracing GC. Lace, the LSP servers, `lsyntax`, and `lcheck` are written in L.

Generated files belong under `build/`; do not commit them.
