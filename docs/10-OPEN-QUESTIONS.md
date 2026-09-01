# Open questions / areas reviewers should attack

The project is deliberately willing to change when real evidence shows a better design.

## Floating-point exactness

The intended model is IEEE binary32/binary64 with deterministic language-level behavior, but a production-quality normative section should scrutinize:

- rounding mode assumptions;
- contraction/FMA;
- NaN payload/sign preservation (if observable at all);
- signaling NaNs;
- exact conversion boundaries;
- reproducibility across C/LLVM/WASM/native backends.

## No-shadowing rule

No shadowing makes resolution/refactoring extremely simple and has not hurt the existing corpus much. Review whether the user ergonomics cost becomes unreasonable in larger programs.

## Generic call syntax

Current generic calls rely entirely on argument/expected-result inference and intentionally provide no `f[T](...)` override. Is this elegantly restrictive, or will real APIs produce unnecessary annotation gymnastics?

## Generic recursion restriction

Mutual generic recursion is rejected largely to guarantee trivial finite monomorphization. Is that the correct language restriction, or should this be an implementation/profile limitation instead?

## Error propagation

Explicit tagged-result matching is verbose. We have intentionally rejected `try`/`?` so far. Review larger real programs and decide whether the cost eventually crosses the line.

## Array identity/equality and immutable data

Arrays are mutable aliasing objects and have no built-in value equality. Strings are therefore mutable arrays too. Is this acceptable long term for map keys/configuration APIs, or does a separate immutable byte-string/value-array concept eventually earn itself?

## Const scope

Scalar-only `const` avoids a compile-time language. Is it too restrictive? Could immutable aggregate constants be added without deep-const semantics and initialization complexity?

## Source/module visibility model

Private-by-default declarations/fields and qualified imports are simple. Re-exports/selective imports/packages are currently omitted. Review how this scales to a larger ecosystem.

## Host profile standardization

Core intentionally specifies no OS environment. A future project may still want one canonical portable hosted API. If so, it should probably be versioned separately from Core.

## Core primitive budget

`len/push/pop/splice` are currently the only generic dynamic-array intrinsics. Review whether `splice` is too high-level for Core or whether another primitive could replace it more cleanly.
