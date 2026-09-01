# Contributing

L is still experimental. Small, well-supported changes are preferred over feature accumulation.

Before proposing a language feature, show a real problem in L code and consider whether it belongs in:

1. Core language semantics;
2. a portable L library;
3. an optional host module;
4. tooling only.

Changes to Core should normally include conformance tests and updates to the relevant specification documents.

For substantial design proposals, `review/CHANGE-PROPOSAL-TEMPLATE.md` is a useful format.

Run before submitting changes:

```sh
./test.sh
```
