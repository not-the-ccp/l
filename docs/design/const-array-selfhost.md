# Self-hosted const-array representation

The L-written frontend represents the read-only capability of an array layer explicitly.

- `[]T` parses as `TypeKind.array` and resolves as `ResolvedKind.array`.
- `const []T` parses as `TypeKind.const_array` and resolves as `ResolvedKind.const_array`.
- The qualifier applies to exactly one array layer. For example, `const [][]T` is a read-only outer array whose elements are mutable arrays, while `[]const []T` is a mutable outer array whose elements are read-only arrays.
- Element types are resolved recursively, so generics, references, optionals, functions, and nested arrays retain their ordinary identity below the qualified layer.

This representation is static only. Mutable and const arrays keep the same runtime storage representation; capability enforcement belongs to semantic checking rather than layout or code generation.
