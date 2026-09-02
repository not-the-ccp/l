# L Core semantic rules

This file highlights rules that are easy for independent implementations to accidentally get wrong.

## Evaluation order

Evaluation order is always **left to right**.

For `f(a(), b(), c())`, the three argument expressions run in that order before the call.

Array elements, struct-literal field expressions, binary operands, and other multi-expression constructs likewise evaluate in source order.

Logical `&&` and `||` short-circuit.

## Value copying and identity

Function arguments, local assignment, and returns use value semantics.

- scalars copy their scalar value;
- structs/enums copy their value recursively;
- `ref T` copies a reference handle, preserving object identity;
- `[]T` and `const []T` copy an array handle, preserving array identity and the static capability of that handle;
- function values copy the callable value;
- optionals copy their contained value according to the same rules.

Thus copying a struct containing an array produces two independent structs that refer to the same array object.

`[]T` and `const []T` have the same runtime representation. A mutable handle may be implicitly qualified as `const []T` without allocation or copying. Qualification cannot be removed from an existing const handle.

## Places and mutation

An implementation should distinguish evaluating an expression for its **value** from evaluating an expression as an assignable **place**.

This matters for value structs:

```text
outer.inner.point.x = 3;
array[i].field += 1;
```

The intermediate value-struct fields must not be accidentally copied and mutated as temporaries.

An element reached through `const []T` is not an assignable place. The qualifier is shallow: if reading an element yields a mutable `[]U` or a `ref U`, that value retains its own mutation capability. Thus `rows[0][0] = x` is valid for `rows: const [][]T`, while `rows[0] = other` is not. Likewise, a field reached through a `ref` stored in a const array may be mutated.

For compound assignment, place-identifying subexpressions are evaluated once. For example, `a[f()] += g()` calls `f()` once.

A field on a temporary value struct is not assignable merely because the same field on a ref-returning expression would be. Storage identity matters.

## Integers

Integer widths are exact and representation is two's complement for signed types.

`+`, `-`, and `*` wrap modulo `2^N` at the destination width, for signed and unsigned integers.

Integer division truncates toward zero. Division or remainder by zero traps.

The signed minimum divided by `-1` follows the fixed-width wrapping model: quotient is the signed minimum and remainder is zero.

Bitwise operators require matching integer types.

Shift LHS may be any integer type. Shift count has type `u64`. A shift count greater than or equal to the LHS width traps. Signed right shift is arithmetic; unsigned right shift is logical.

There are no C-style integer promotions.

## Numeric literals and conversions

Numeric literals are contextual mathematical literals rather than pre-typed machine values.

The expected operand/declaration type may type a literal on either side of an operation. If no numeric context exists, integer literals default to `i64` and floats to `f64`.

This does not create general variable/type inference.

There are no implicit numeric conversions between runtime values. Use `as`.

Integer-to-integer casts are defined by the target-width bit representation (modulo `2^N`). Float-to-integer casts truncate toward zero and trap if NaN/infinity/out of target range. Integer-to-float and float-width casts follow the target floating representation.

## Floating point

`f32` and `f64` are intended to follow ordinary IEEE binary32/binary64 behavior, including NaN and infinities. `f32` is rounded to binary32 after each language operation.

Float division by zero follows floating-point semantics rather than trapping. `%` is integer-only.

A fully normative floating-point section is still an area reviewers are invited to scrutinize; see `10-OPEN-QUESTIONS.md`.

## Arrays

Arrays are non-null shared managed objects. A handle has either mutable capability `[]T` or shallow read-only capability `const []T`.

The implicit qualification conversion is exactly:

```text
[]T -> const []T
```

It is zero-cost and preserves array identity. There is no general inverse conversion.

Constness applies to only the qualified array layer. It does not recursively alter `T`. In particular, `const []ref Node` contains ordinary `ref Node` values, and `const [][]u8` contains ordinary mutable `[]u8` values.

A const handle does not freeze the underlying object. If mutable and const handles alias the same array, mutation through the mutable handle is visible through the const handle. Consequently, an implementation must not treat reads through `const []T` as invariant across calls or other operations that may mutate an alias.

`push`, `pop`, indexed assignment, compound indexed assignment, and the target of `splice` require a mutable array handle. `len`, indexing for value, `for` iteration, and the replacement argument of `splice` accept const arrays; mutable arrays can satisfy those read-only uses through qualification.

`push` and `splice` mutate the array object visible through all aliases. `pop` removes and returns the last element.

`[expr; n]` evaluates `expr` once and copies that value `n` times. If `expr` is a `ref`, `[]T`, or `const []T`, all repeated entries therefore share the same referenced object/array.

Indexing is bounds checked and traps on failure.

Ordinary array literals infer mutable arrays. A string literal has default/inferred type `const []u8`. When the expected type at the literal itself is mutable `[]u8`, the literal may materialize directly as a fresh mutable array. This contextual literal rule does not permit an existing `const []u8` value to become mutable.

`const []T` provides read-only access, not global immutability. It does not establish stable content hashing, uniqueness, absence of aliases, or thread-safety guarantees.

## Managed memory

`new` creates fresh object identity.

The implementation must ensure that every reachable managed object/array remains alive. It may use a host GC, tracing GC, copying GC, refcounting plus any needed cycle handling, or another strategy. It may not expose dangling references.

The language provides no finalization, weak-reference observation, raw address, deallocation, or object-layout operation, so collection timing and relocation are not observable.

Resource exhaustion is an implementation/environment failure and is not made into a catchable language exception.

## Recursive layouts

Direct recursive value storage is invalid:

```text
struct Bad { next: Bad }
struct AlsoBad { next: ?AlsoBad }
```

`?T` does not add storage indirection.

`ref`, `[]`, and `const []` break layout recursion:

```text
struct Node { next: ?ref Node }
struct Tree { children: []Tree }
struct ReadTree { children: const []ReadTree }
```

## Optionals and patterns

`?T` has exactly two logical cases: `none` and `some(T)`.

There is no implicit `T -> ?T` conversion in the current design; write `some(value)`.

Binding pattern tests are deliberately scoped narrowly:

```text
if (x is some(v)) { ... }
while (x is SomeVariant(v)) { ... }
```

A binding `is` pattern must be the entire condition, avoiding flow-sensitive binding rules inside arbitrary boolean expressions.

Non-binding pattern tests may occur in ordinary boolean expressions.

`match` over optional/enum/bool must be exhaustive unless `_` covers the remainder. Integer/byte matches require `_` for exhaustiveness.

Patterns are shallow; payload positions bind names or `_` rather than recursively destructuring nested constructors.

## Functions and capture

All parameters have explicit types. Return type defaults to unit.

Anonymous functions are noncapturing. Referencing an enclosing runtime local is a compile error. This permits function values to remain ordinary code/function identities without mandatory closure environments.

## Generics

A generic declaration is checked while type parameters are abstract. Validity does not depend on particular instantiations.

Inference is structural. Mutable and const array capabilities remain distinct types, with `[]T -> const []T` available when satisfying a read-only array parameter. Qualification does not flow in the opposite direction.

If a type parameter cannot be determined from arguments and expected result type, the call is invalid; Core currently has no explicit generic-call type-argument syntax as an escape hatch.

Because Core intentionally permits simple monomorphizing native implementations, mutually recursive generic functions are rejected, and direct generic recursion must use the same type parameters unchanged.

## Names and shadowing

The current design rejects shadowing rather than maintaining overlapping source namespaces. A visible local/module/function/type/import/builtin name cannot be silently rebound in an inner scope.

Internally, implementations should use stable declaration/symbol identity and keep source spelling separate from backend name mangling.

## Traps

Core operations either:

1. produce their specified result;
2. are rejected statically; or
3. trap at runtime.

Typical traps include array bounds errors, empty `pop`, invalid `splice` ranges, invalid shifts, integer division by zero, and invalid float-to-integer conversion.

Traps are not catchable in Core.
