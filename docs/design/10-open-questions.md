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
**Resolution**: Adopted (S5). `match` and tag-only `is` remain, and a `let-else`
statement for `?T` was added once the `tools/lsp/server.l` `change_document`
chain demonstrated the nesting pain. Payload-enum generalization stays parked.

### Let-else statement
**Resolution**: Adopted (S5). `let PAT = SCRUT else DIVERGES;` desugars to a
match over a hygienic fresh temporary with single scrutinee evaluation, a
`?T`-only pattern restriction, and a sufficient syntactic Diverges criterion
for the `else` block. `?`-propagation, implicit `T -> ?T`, new runtime
semantics, and new trap kinds were explicitly rejected.

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

### Place revalidation at write
**Resolution**: Shipped. Compound assignment evaluates place-identifying
subexpressions once, left to right, then the RHS, then revalidates
array-element places at write time; a RHS that shrinks the array turns a
stale index into an array-bounds trap (see `01-core-language.md` Assignment
and places). Integer semantics likewise pinned: exact widths, two's
complement, wrapping `+`/`-`/`*`, truncating division, and the eight-family
trap inventory in `03-core-semantics.md`.

## Parked (post-v1, each with entry criteria)

These are explicitly not open design work; each names what evidence would
reopen it. This section is the counterpart of the closed-set doctrine in
`09-design-rationale.md`.

### Core str
Parked. Entry criterion: a portable library demonstrates text handling
(graphemes, normalization, case folding) that cannot be expressed over
`const []u8` bytes. Until then, text stays a library interpretation.

### Deep subtyping
Parked. Entry criterion: a recurring program problem needs more than the
single-layer `[]T -> const []T` qualification (e.g. transitive/deep const).
No such case has been demonstrated.

### ?T-lift
Parked and rejected for v1 (review decision D-T2). Entry criterion: shipped
code shows `some(...)` wrapping dominating handlers without hiding
`none`-paths. Unwrap explicitly with `is`/`match` until then.

### Implicit T->?T / postfix-?
Parked with ?T-lift above. Entry criterion: demonstrated ergonomic pressure
from shipped code for either the implicit conversion or `?` sugar; a
proposal must show the `none`-path stays explicit.

### defer
Parked. Entry criterion: resource-cleanup patterns in real code that
`match`/early-return cannot express cleanly. No such pattern has been shown.

### host-v1
Parked under "Host profile standardization" below. Entry criterion: two
independent embeddings need the same portable surface, versioned separately
from Core.

### Captures
Parked. Entry criterion: editor/LSP/library work demonstrably blocked
without closure environments (see `09-design-rationale.md`: noncapturing
anonymous functions compile as hidden top-level functions; captures would
change every function value's representation).

### Variance
Parked. Entry criterion: real generic code blocked by invariance under the
current structural-unification rules.

### Frozen arrays
Parked (see "Frozen/value arrays" above). Entry criterion: a stable-hashing
or cross-thread sharing use case with measurements justifying copy, freeze,
or ownership machinery over the current shallow `const []T`.

## Still open (post-v1)

### Host profile standardization
Core intentionally specifies no OS environment. A future project may want one canonical portable hosted API, versioned separately from Core.

### Package manager and module registry
The RISC-V extension model (formalized in architecture docs) provides the foundation. A package registry and module resolver are post-v1 work.

### Error propagation sugar
Resolved (S5): the `let-else` statement covers the sequential-fallible-operation
shape for `?T` (see Resolved above). Broader sugar (e.g. for library `Result`
types or payload enums) still needs demonstrated pain before adoption.