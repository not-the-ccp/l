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

## Why strings are `const []u8`?

The language core does not need Unicode semantics to support byte/text processing. UTF-8 operations can be portable library code, so text does not justify a separate privileged string object.

Treating inferred string literals as mutable `[]u8` made read-only text APIs accidentally expose mutation. `const []T` solves that problem generally rather than special-casing bytes: a string literal normally has type `const []u8`, while the same qualifier can describe read-only arrays of any element type.

The qualifier is deliberately shallow. `const []ref Node` prevents replacing array slots but does not remove mutation capability from the referenced nodes. Likewise, `const [][]u8` leaves each inner `[]u8` mutable. This matches the capability being expressed—the array layer itself is read-only—without introducing transitive const through arbitrary object graphs.

Mutable arrays implicitly qualify to const arrays without copying. A const handle may therefore alias a mutable handle, and mutations through the mutable alias remain visible. L does not claim that `const []T` is globally frozen data.

A string literal can materialize directly as mutable `[]u8` when the literal itself occurs in an explicitly mutable context. This is contextual construction of a fresh array, not a conversion from an existing const value. It preserves simple uses such as passing a literal directly to an API that explicitly asks for a mutable buffer while keeping inferred text read-only.

## Why not transitive or globally immutable arrays?

L has ordinary shared aliasing for managed arrays and refs. Guaranteeing that data can never change through any alias would require copying, runtime freezing, copy-on-write, or an ownership/borrow discipline. Each would substantially change the language and runtime model.

The useful low-cost property is narrower: code with `const []T` cannot mutate that array layer through that handle. True frozen/value arrays can be considered separately if stable hashing, cross-thread sharing, or another concrete use case eventually justifies them.

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
