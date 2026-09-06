# Portable library

The portable library is **not part of L Core**. It is ordinary L source that requires no host modules and is intended to be usable by any implementation that provides Core semantics and a way to resolve the library's logical module names.

This distinction is intentional: an implementation can stop at Core and still have a finite, serious conformance target.

## Current modules

### `arrays`

Small helpers around `[]T`, including cloning and insertion/removal conveniences built on Core `splice`.

### `bytes`

Byte-array operations such as equality, slicing, searching, trimming, and line-boundary helpers. L has no separate string type; these operate on the same `[]u8` representation used for text and binary data.

### `strconv`

Portable integer parsing/formatting helpers.

### `utf8`

UTF-8 interpretation helpers layered over `[]u8`. Unicode is library-level semantics rather than a Core character/string model.

### `json`

A JSON parser/representation written in L.

### `lsp`

Protocol/data helpers shared by the L-written language servers and Lace.

### `slang_syntax`

The L-written lexer/parser currently used by the L language server and `lsyntax`. This is portable compiler/tooling code despite living in the library tree; it does not make compiler support part of Core.

### `algorithms`

Generic array algorithms using ordinary unconstrained type parameters and explicit callbacks:

```l
algorithms.reverse(items);
algorithms.find_by(items, value, equal);
algorithms.contains_by(items, value, equal);
algorithms.equal_by(a, b, equal);
algorithms.sort_by(items, less);
```

`sort_by` is an in-place `O(n log n)` heapsort. A comparator `less(a, b)` should return true exactly when `a` belongs before `b` in the resulting order.

This module is a deliberate test of L's generic philosophy: generic code receives operations as normal `fn(...)` values instead of requiring traits/interfaces/type-set constraints.

### `collections`

Generic source-level collections:

```text
Stack[T]
Queue[T]
Heap[T]
Map[K, V]
Set[T]
```

Representative construction:

```l
var stack: ref collections.Stack[i64] = collections.stack_new();
var queue: ref collections.Queue[i64] = collections.queue_new();
var heap = collections.heap_new(less_i64);
var map: ref collections.Map[i64, []u8] = collections.map_new(hash_i64, equal_i64);
var set = collections.set_new(hash_i64, equal_i64);
```

Maps and sets receive hash/equality functions explicitly. Heaps receive an ordering function explicitly. There is no compiler-recognized `Hashable`, `Comparable`, trait, interface, or generic constraint involved.

The map is a separate-chaining hash table with automatic growth. The queue periodically compacts its consumed prefix using Core `splice` rather than retaining all popped values indefinitely.

## Value and aliasing rules still apply

Library containers use ordinary L assignment semantics.

Scalar/struct values are copied as values. `ref T` and `[]T` are handles, so storing them in a collection preserves aliasing.

This matters particularly for map keys. If a key contains mutable shared state (for example a `[]u8`), mutating that state after insertion may invalidate the caller-supplied hash/equality invariant. `Map` does not secretly deep-copy arbitrary `K`; Core has no generic cloning protocol.

A library/application that needs owned immutable keys should establish that policy explicitly, for example by copying byte keys before insertion.

## Why these are library code rather than Core built-ins

None of these data structures require semantics unavailable to an L program. Making them compiler/runtime primitives would:

- enlarge every independent implementation's mandatory surface;
- hide useful stress tests of generics, function values, refs, GC, and arrays;
- lock API/data-structure choices into the language specification unnecessarily.

Core therefore provides only the primitive dynamic-array operations that cannot be implemented efficiently in ordinary portable L (`len`, `push`, `pop`, `splice`) and managed references for identity/graphs. Collections are built above those mechanisms.

## Testing

`examples/core/collections.l` is an executable stress example. The repository test suite runs it and exercises:

- generic sort/reverse/search/equality;
- stack operations;
- FIFO order across queue compaction;
- heap ordering;
- map insertion, growth/rehash, lookup, update, and removal;
- set insertion/removal.

This is useful both as library regression coverage and as a continuous test that L's deliberately small generic system remains sufficient for real reusable data structures.
