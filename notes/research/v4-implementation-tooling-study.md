# v4 implementation/tooling study

This directory is a self-contained implementation study for the current candidate language.
It intentionally tries to expose costs that toy implementations usually skip: real cyclic
reclamation, modules/privacy, generic specialization, exact evaluation order, nested pattern
exhaustiveness, formatting/comments, diagnostic recovery, and native GC cooperation.

## Implementations and tools

- `core.py` — lexer, parser, static checker, source-module linker, host-module API,
  tree-walking interpreter. Runtime objects use Python's real cyclic GC; weak tracking is used
  in tests to verify unreachable language cycles are reclaimed.
- `bytecode.py` — AST-to-stack-bytecode compiler and VM. Lexical scope-unwind instructions
  ensure `break`/`continue` stop dead locals from remaining GC roots.
- `monomorph.py` — native-backend specialization experiment for unconstrained generics.
- `gc_analysis.py` — post-specialization tracing/root-shape analysis for a precise native GC.
- `gc_runtime.[ch]` — standalone native mark/sweep runtime with explicit roots and traced arrays.
- `gc_demo.c` — cyclic native object/array stress; allocates and reclaims all objects.
- `gc_root_hazard.c` — demonstrates why native ordered-expression temporaries containing heap
  handles must be rooted across calls/allocations.
- `tooling.py` — token-preserving formatter, lexical highlighting, LSP UTF-16 coordinate adapter,
  diagnostics rendering, public-API extraction, test discovery/runner.
- `recovery.py` — declaration-level syntax recovery experiment for editor diagnostics.
- `conformance.py` — 60-case feature matrix run through both tree interpreter and bytecode VM.
- `stress.py` — 250 randomized arithmetic differentials plus modules, GC, patterns, formatting,
  floats, lvalue/evaluation-order tests.

## Current empirical status

Commands used:

```sh
python3 test_core.py
python3 test_bytecode.py
python3 test_tooling.py
python3 stress.py
python3 conformance.py
python3 recovery.py
python3 gc_analysis.py
cc -std=c11 -Wall -Wextra -Werror gc_runtime.c gc_demo.c -o gc_demo && ./gc_demo
cc -std=c11 -Wall -Wextra -Werror gc_runtime.c gc_root_hazard.c -o gc_root_hazard && ./gc_root_hazard
```

Observed headline results:

- 60/60 feature-matrix cases pass in both tree and bytecode engines.
- 250 randomized fixed-width integer programs agree between both engines.
- Unreachable ref-only and ref/array cyclic graphs are reclaimed by both engines.
- Native GC demo: `allocated=20004 freed=20004 live=0`.
- Generic specialization tested for `Queue[T]`, generic `Result` mapping with callbacks,
  anonymous functions inside generic functions, and recursive `Node[T]` through `ref`; the
  specialized AST rechecks and agrees in tree + bytecode execution.
- Formatter preserves token meaning and comments and is idempotent in fuzz tests; a discovered
  raw-literal-loss bug was fixed by preserving raw token spelling separately from decoded value.

## Important pitfalls found

1. **Runtime must never re-enter type/name resolution.** Enum constructor identity must be
   resolved and annotated during checking. Re-resolving at runtime failed inside generic code
   when constructor arguments referenced lexical locals.
2. **Compiler AST and tooling CST have different needs.** A formatter must preserve raw literal
   spelling/trivia; decoded-only tokens are insufficient. Rename/navigation additionally need
   per-name spans and stable symbol identities, not just whole dotted-chain spans.
3. **LSP coordinates differ from compiler coordinates.** UTF-8 source still needs UTF-16
   line/column conversion at the LSP boundary (e.g. emoji).
4. **Canonical declaration identity must not be source spelling or mangled output name.** Import
   aliases and monomorphized names exposed bugs when semantic ownership was inferred from strings.
5. **Source no-shadowing must be checked before/independently of internal module renaming.**
6. **GC roots interact with control flow.** Tree scopes need guaranteed cleanup on return/break/
   trap. Bytecode break/continue must unwind lexical root scopes.
7. **GC roots interact with evaluation order.** Native temporaries holding refs/arrays must remain
   rooted while later arguments/fields/elements are evaluated; any later allocation may collect.
8. **Nested patterns need a real exhaustiveness algorithm.** Outer-constructor-only checking is
   incorrect for cases such as `?E`; a small constructor-pattern matrix fixed this.
9. **Assignable expressions are about storage identity, not syntax alone.** `get_ref().field = x`
   can be valid while mutating a field of a temporary value struct is not.
10. **Contextual typing must propagate through transparent constructors.** `return new Queue {
    items: [] }` inside a known `ref Queue[T]` result context exposed this.
11. **Signed-min literals are a contextual unary-minus corner.** `-128` must fit `i8` even though
    the positive sub-literal `128` does not.
12. **Compile-time and runtime scalar semantics must be shared.** Separate `const` arithmetic had
    already drifted on invalid shifts and IEEE division; it was consolidated.
13. **Runtime faults and compile-time errors are distinct.** Invalid runtime float-to-int casts
    trap; the same invalid operation in a constant initializer is a compile-time error.
14. **Host retention crosses the GC boundary.** Native hosts that retain language heap values must
    register roots; opaque values are otherwise atomic with respect to language tracing.
15. **Generic AOT specialization needs finite-instantiation rules.** Direct recursive generic calls
    preserve type arguments; polymorphic and mutual generic recursion are rejected.

## Size snapshot (not a quality metric)

The code is intentionally very compressed, so these counts understate a readable implementation:

- `core.py`: ~1.6k physical lines
- `bytecode.py`: ~320
- `monomorph.py`: ~160
- `gc_analysis.py`: ~116
- native GC runtime header+source: ~131
- `tooling.py`: ~166
- declaration recovery experiment: ~65

The more useful observation is conceptual: lexer/parser/runtime execution are not the dominant
parts. Static semantics + module identity/privacy + exact control-flow/place rules dominate a
portable interpreter; precise GC-root lowering + native numeric semantics dominate native AOT;
CST/error recovery/symbol identity dominate serious editor tooling.
