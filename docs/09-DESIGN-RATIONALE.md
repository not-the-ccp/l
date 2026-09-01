# Selected design rationale

## Why C-like but not C-compatible?

“C-like” means familiar braces, calls, expressions, static types, and imperative control flow. It does not mean inheriting C declarators, integer promotions, pointer arithmetic, preprocessor semantics, UB, array decay, unspecified evaluation order, or header/build conventions.

The goal is implementation simplicity, not C source/ABI compatibility.

## Why managed `ref` instead of raw pointers?

Normal educational/real programs need linked lists, trees, graphs, ASTs, shared mutation, and cycles. Removing all indirection made those examples artificially awkward.

`ref T` provides object identity while deleting the hardest pointer semantics: no addresses, no stack references, no pointer arithmetic, no explicit free, no dangling pointers, no provenance/aliasing UB.

## Why `?T` rather than nullable refs?

`ref T` then has a strong invariant: it is always a valid reference. Absence is explicit and generic (`?ref Node`, `?i64`, `?[]u8`) rather than infecting every reference with an implicit null state.

There is deliberately no force unwrap; pattern matching keeps the distinction explicit.

## Why strings are `[]u8`?

The language core does not need Unicode semantics to support byte/text processing. UTF-8 operations can be portable library code. Real tooling (LSP, JSON, editor, terminal handling) has so far remained practical with bytes plus libraries.

## Why generics after initially rejecting them?

Writing a credible library exposed massive duplication without them: `Queue[T]`, `Map[K,V]`, `Result[T,E]`, sorting/searching, etc.

The adopted form is deliberately smaller than Go/Rust/C++ generic systems: unconstrained opaque type parameters only. Behavior is passed as ordinary function values. There are no traits/type sets/constraints/specialization.

## Why function values and anonymous functions but no closures?

Callbacks are genuinely useful for generic libraries. Noncapturing anonymous functions can compile as hidden top-level functions and preserve a simple function-value representation.

Capturing closures introduce environments, capture/mutation/lifetime semantics, allocation, and a more complex representation for every function value. Real editor/LSP/library work has not yet justified that cost.

## Why no methods/classes/interfaces?

Ordinary functions plus structs/enums/generics/function callbacks have been sufficient for substantial code. Avoiding method lookup/receiver rules/interface dispatch also keeps parsing, resolution, and tooling simpler.

## Why no exceptions / `?` propagation?

Tagged enums can represent recoverable errors in normal data. Convenience propagation syntax would either privilege a library `Result` type or introduce a new hidden early-return protocol. Real code is somewhat verbose here, but the implementation/semantic budget has not yet been justified.

## Why line-independent lexing?

It makes lexers, syntax highlighters, incremental editors, and range semantic-token requests unusually robust. This became a concrete performance/product benefit in Lace/LSP work.

## Why no filesystem-defined module semantics?

An embedded interpreter, browser runtime, archive-backed compiler, database-backed system, or build tool should be able to supply modules without pretending they are files. Filesystem mapping belongs in a hosted profile/toolchain.
