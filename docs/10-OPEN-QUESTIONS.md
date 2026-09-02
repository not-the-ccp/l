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

## Frozen/value arrays

`const []T` provides shallow read-only access through one handle, but mutable aliases may still change the same array object. It therefore does not make an array a stable content-hashed key or immutable value.

Do real map-key, configuration, concurrency, interning, or persistence use cases eventually justify a separate frozen/value-array concept? If so, the design must make its construction cost and aliasing consequences explicit rather than silently turning qualification into copying or runtime freezing.

## Const-array ergonomics

Mutable arrays implicitly qualify to `const []T`, and string literals infer `const []u8` unless the literal itself is contextually required to be mutable. Review dogfooded APIs for cases where preserving or returning the caller's array capability would require qualifier polymorphism. Avoid adding permission-generic machinery until concrete APIs demonstrate the need.

## Module `const` scope

Module `const` declarations remain scalar-only and are separate from the `const []T` type qualifier. Scalar-only declarations avoid introducing a compile-time language. Is that too restrictive? Could aggregate module constants be added without deep-const semantics and initialization complexity?

## Source/module visibility model

Private-by-default declarations/fields and qualified imports are simple. Re-exports/selective imports/packages are currently omitted. Review how this scales to a larger ecosystem.

## Host profile standardization

Core intentionally specifies no OS environment. A future project may still want one canonical portable hosted API. If so, it should probably be versioned separately from Core.

## Core primitive budget

`len/push/pop/splice` are currently the only generic dynamic-array intrinsics. Review whether `splice` is too high-level for Core or whether another primitive could replace it more cleanly.
