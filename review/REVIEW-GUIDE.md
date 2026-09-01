# How to review L

Please review this as a programming language design and implementation project, not merely as source-code style.

## Project goals

L should be:

- simple enough that a learner can understand/implement the entire frontend and a serious interpreter;
- easy to parse and tool correctly;
- C-family/familiar in surface syntax without cloning C semantics;
- deterministic and mostly free of UB/implementation-defined behavior;
- serious enough for normal algorithms, linked structures, parsers/compilers, small utilities, reusable libraries, and substantial tooling;
- environment-independent at the Core level;
- extensible through ordinary libraries and typed host modules rather than language special cases.

If a feature makes implementation/tooling substantially more complex, it needs correspondingly strong real-program benefit.

## Suggested review procedure

1. Read `docs/00-ARCHITECTURE.md` and verify the Core/library/host split makes sense.
2. Read the Core spec and grammar independently of the implementation.
3. Run `conformance/core_conformance.py`.
4. Inspect `bootstrap/core.py`; look for places where implementation behavior disagrees with the docs.
5. Try writing several programs yourself.
6. If relevant, implement a second tiny parser/interpreter/type checker for a subset to test whether claimed simplicity holds.
7. Inspect the portable libraries to see which inconveniences are merely library concerns versus language deficiencies.
8. Treat Lace/LSP/tooling failures as evidence, but do not automatically promote application needs into Core features.

## High-value feedback

Good findings include:

- ambiguous or context-sensitive grammar;
- hidden inference complexity;
- semantic rules that are hard to implement independently;
- surprising value/aliasing behavior;
- unsound or underspecified memory semantics;
- backend portability traps;
- features that should be library code instead;
- missing features that repeatedly simplify real code enough to justify their cost;
- contradictions between spec and reference implementation;
- ways to shrink Core while preserving ordinary programming;
- ways an ostensibly simple rule causes serious tooling pain.

## Please distinguish layers

For every proposal, say whether it belongs in:

- **Core language**
- **portable library**
- **hosted profile / host module**
- **tooling/editor/compiler implementation only**

A terminal signal-handling problem, for example, is usually not evidence that Core needs exceptions/RAII.

## Be adversarial

Do not preserve a design decision merely because the bundle explains why it exists. Try to falsify the rationale.

Likewise, do not propose familiar mainstream features solely because they are familiar. Show the concrete L code that becomes bad without them and explain the implementation/tooling cost of adding them.
