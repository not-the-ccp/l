# Roadmap

L is pre-1.0. This roadmap is a development direction, not a compatibility promise.

The project is intentionally resisting feature accumulation. The next milestones are mostly about making the existing language easier to implement independently, making the toolchain self-hosting, and increasing the amount of real software written in L.

## 1. Tighten the Core specification and conformance suite

The immediate goal is to make “implement L Core” a crisp, finite target.

Work includes:

- expand positive/negative/trap conformance cases;
- keep tree, bytecode, and native reference paths differentially tested;
- turn previously implicit edge cases into written decisions;
- detect specification/implementation disagreements automatically where practical;
- test parser/lexer invariants such as whitespace independence and line-independent lexing;
- add more module/visibility/generic-recursion cases;
- deepen numeric edge testing, especially floats and casts.

A new implementation should be able to run the Core suite without implementing any portable library or hosted API.

## 2. Self-host the compiler frontend

The current `./lc` frontend is Python-bootstrapped. L already contains substantial compiler-like code and is capable of writing its own lexer/parser infrastructure.

The next compiler milestone is an L-written frontend with approximately this pipeline:

```text
L source
  -> L lexer/parser
  -> resolver + type checker
  -> checked representation
  -> bytecode
  -> existing native VM/runtime
```

The first self-hosted compiler does not need a new machine-code backend. Reusing the existing bytecode/native-runtime path keeps the self-hosting project focused on the language implementation itself.

A useful bootstrap criterion is:

```text
bootstrap compiler C0
  compiles L compiler C1
C1
  compiles its own source into C2
C1 and C2
  agree on the conformance corpus and reproducible artifacts
```

## 3. Share one semantic frontend between the compiler and L LSP

The L language server should eventually consume the same L-written syntax/resolution/type information as the self-hosted compiler rather than maintaining parallel language knowledge.

That enables precise:

- diagnostics;
- hover/type display;
- completion;
- definitions and references across modules;
- rename;
- document/workspace symbols;
- semantic tokens;
- code-analysis/CFG integration.

This is also a strong test of whether the compiler frontend exposes clean reusable data structures rather than being a monolithic batch compiler.

## 4. Grow the portable source library through use

The portable library should remain ordinary L wherever possible and should not become a hidden second language runtime.

Useful areas include:

```text
arrays / bytes / ASCII / UTF-8 helpers
sorting / searching
option/result utilities
stack / queue / deque / heap
map / set
hashing
numeric conversion and formatting
JSON / INI / CSV
hex / base encodings
simple parsing utilities
regex/glob experiments
testing helpers
```

Library work is expected to feed back into language review. If a recurring problem is genuinely awkward in ordinary L, document it with real examples before proposing a Core feature.

## 5. Develop L using Lace

Lace should become good enough that work on the compiler and portable library can be done in it for extended periods without switching editors out of frustration.

Likely additions should be driven by that use rather than feature parity with Vim/Helix/Kakoune. Plausible pressure points are:

- multiple buffers;
- jump/history list;
- project/file picker;
- diagnostic/quickfix list;
- project search;
- improved completion presentation;
- richer LSP navigation;
- persistent editor state where it clearly pays off.

Lace is still optional tooling. Its needs do not automatically become Core language requirements.

## 6. Write non-tooling applications

Compiler/editor/LSP work stresses many useful language properties but can bias the design toward language tooling.

The project should increasingly test L on unrelated programs such as:

- grep/sed-like byte-processing tools;
- data converters and JSON query tools;
- Advent-of-Code style algorithmic workloads;
- parsers and small interpreters;
- static-site/build utilities;
- archive/database experiments;
- networking applications under an optional host profile.

Track friction rather than merely proving expressibility.

## 7. Native backend experiments after self-hosting

The current native executable path embeds L bytecode in a C VM/runtime. That is deliberately practical and keeps the bootstrap small.

Once the self-hosted frontend is stable, additional backends are useful experiments:

```text
checked L -> C11
checked L -> LLVM IR
checked L -> small direct native backend
```

A native backend must preserve L's defined left-to-right evaluation, wrapping integer semantics, traps, and managed-reference GC roots. A backend becoming complicated is useful design feedback, but C/LLVM implementation convenience is not itself the language specification.

## Feature policy before 1.0

New Core features have a deliberately high bar.

A proposal should normally include:

1. a recurring problem demonstrated in real L code;
2. why a portable library or host module is insufficient;
3. the effect on the grammar and static semantics;
4. costs for a tree interpreter, bytecode VM, native compiler, formatter, and LSP;
5. interactions with generics, managed references, modules, and evaluation order;
6. alternatives, including doing nothing.

Features specifically worth re-evaluating only if real pressure appears include capturing closures, richer error propagation, generic constraints, additional collection/view types, and more expressive pattern matching.

The default outcome is not “add it.” A successful review may conclude that explicit code is cheaper than a new permanent language mechanism.

## Near-term definition of success

A particularly useful combined milestone is:

> L compiles its own compiler, the L LSP uses that compiler frontend, and Lace is comfortable enough to develop the compiler and portable library in L itself.

That would simultaneously exercise language usability, implementation simplicity, generics, GC, modules, diagnostics, tooling APIs, editor performance, and bootstrap reproducibility without requiring substantial new Core features.
