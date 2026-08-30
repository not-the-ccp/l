# AGENTS.md

This repository contains the L language, its reference/bootstrap implementation, optional libraries, and tooling.

## Before changing language design

Read:

1. `docs/00-ARCHITECTURE.md`
2. `docs/01-CORE-LANGUAGE.md`
3. `docs/03-CORE-SEMANTICS.md`
4. `docs/09-DESIGN-RATIONALE.md`
5. `docs/10-OPEN-QUESTIONS.md`

Then run:

```sh
python3 conformance/core_conformance.py
./test.sh
```

## Boundaries

- `docs/` defines the intended language; the Python implementation is not automatically normative.
- `lib/portable/` is optional library code, not Core.
- `lib/hosted/` and typed host modules are environment-specific, not Core.
- `tools/` must not be used as evidence that every L implementation must provide those capabilities.
- `notes/` is historical/non-normative evidence and may describe superseded designs.

## Review work

For a critical independent review, follow `review/AGENT-PROMPT.md` and `review/REVIEW-GUIDE.md`.

Do not assume current design rationales are correct. Prefer reproducible examples and experiments over taste. Separate language-core issues from library, host-environment, implementation, and tooling issues.

## Implementation notes

The current compiler frontend is Python-bootstrapped. Native outputs use `runtime/native_vm.c` and tracing GC. Lace and the LSP servers are written in L.

Generated files belong under `build/`; do not commit them.
