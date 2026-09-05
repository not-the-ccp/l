# Design decisions and future directions

This file tracks open questions and their resolutions as the language evolves.

## Resolved (v1)

### No-shadowing
**Resolution**: Keep the blanket ban. Zig's approach works without issues in practice. Existing code (~9,000 lines of L) demonstrates no ergonomic pressure to relax this.

### Generic call syntax
**Resolution**: Added `f[T](args)` syntax as an explicit escape hatch when type inference fails. The parser disambiguates `f[T](args)` from `f[expr]` (indexing) by speculatively parsing the bracket content as types followed by `(`.

### Tag-only `is` checks
**Resolution**: `x is some`, `x is TokenVariant` without `(...)` payload patterns are now valid tag-only checks. If the variant has payloads, the pattern implicitly wildcards them. This makes tag inspection less noisy.

### Const array ergonomics
**Resolution**: Keep mutable-by-default for arrays. The existing codebase shows mutable use dominates; `const []T` is the read-only restriction that callers opt into. The implicit `[]T → const []T` qualification makes const-accepting APIs ergonomic without flipping the default.

### Floating-point exactness
**Resolution**: IEEE binary32/binary64, round-to-nearest-even. No FMA contraction. Trap on NaN/infinity for explicit integer casts. Float overflow wraps to infinity. Division by zero follows IEEE semantics (no trap). A normative section will be written in the spec.

### Error propagation
**Resolution**: Deferred. `match` and tag-only `is` are sufficient for v1. A `let-else` statement for `?T` may be added post-v1 based on experience.

### Result type
**Resolution**: `Result[T, E]` is a portable library concern (`enum Result[T, E] { ok(T), err(E) }`), not Core. `?T` serves as the language-level optional primitive. Tag-only `is` sugar (`result is err`) reduces verbosity for library Result types.

### Core primitive budget
**Resolution**: Keep `len`, `push`, `pop`, `splice`. The replacement argument of `splice` accepts `const []T` (any array capability). No change.

### Module constant scope
**Resolution**: Keep scalar-only for v1. Aggregate module constants can be added later if justified by real use cases.

### Module visibility model
**Resolution**: Fine as-is for v1.

### Generic recursion restriction
**Resolution**: Keep the restriction for v1. No real code has been blocked by it.

### Frozen/value arrays
**Resolution**: Deferred to libraries. No language change needed.

## Still open (post-v1)

### Host profile standardization
Core intentionally specifies no OS environment. A future project may want one canonical portable hosted API, versioned separately from Core.

### Package manager and module registry
The RISC-V extension model (formalized in architecture docs) provides the foundation. A package registry and module resolver are post-v1 work.

### Error propagation sugar
The `match` + explicit pattern approach can be verbose for sequential fallible operations. A `let-else` statement or similar sugar may be added after v1 if the pain is demonstrated in real code.