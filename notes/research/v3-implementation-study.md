# v3 language design experiments

Target: a serious small C-family language that is easy to parse, type-check, interpret, compile, and tool.

## Experiments in this pass

- Candidate grammar with generic functions/types, function types, inferred locals, anonymous non-capturing functions, `trap`, comma-separated type members, trailing commas, and strict numeric literals builds with LALR and parses generated examples.
- 500 generated expression/function snippets parsed with both LALR and Earley without grammar ambiguity when using the intended keyword/maximal-munch lexer.
- Numeric literal grammar was cross-checked by regex and independent hand recognizer over 50,000 random strings. This caused removal of the unnecessary no-leading-zero decimal restriction.
- Generic first-order unification was tested through arrays, generic named types, and function-value parameters.
- Generic recursion rule tested with SCC detection: generic SCCs larger than one rejected; self-recursion allowed only with identical type parameters.
- Anonymous non-capturing function lowered to an ordinary C function pointer and compiled/executed successfully.
- Capturing closure comparison required code pointer + environment pointer + generated environment struct/thunk/allocation; a small C model used 18 nonblank support lines versus 4 for plain function values and changes the representation of the function-value type.
- Explicit runtime callback context (`fn(..., C)` plus a context argument) compiled/executed successfully and preserves plain function pointers.
- UTF-8 source + byte-only language strings tested: raw non-ASCII in a string contributes its UTF-8 bytes; `\xHH` supplies arbitrary bytes; byte literals require exactly one resulting byte.
- Module-private-by-default + `pub` declaration/field model prototyped and grammar-checked.
- Signed MIN/-1 division overflow changed from trap to wrapping MIN (remainder 0); portable C lowering tested.
- Corpus check: all actual expression statements in the existing user-study programs are function calls, supporting a calls-only expression-statement rule.
- `copy` intrinsic is unnecessary: a generic shallow array copy is expressible using `len` + `push`.

## Current recommended changes

1. Keep `ref T` non-null; absence is `?T` with `none`/`some`.
2. Keep unconstrained parametric generics only; no traits/interfaces/type sets/constraints.
3. Generic calls use first-order inference from arguments + expected result; no explicit type arguments in call syntax.
4. Reject mutually recursive generic functions; direct generic recursion must preserve type parameters exactly.
5. Keep first-class top-level functions.
6. Add anonymous **non-capturing** function expressions: `fn(a: T) -> U { ... }`.
7. Do not add capturing closures/lambdas in v1.
8. For runtime callback state, pass an explicit context value/ref to a callback-taking library function.
9. Module-private by default; `pub` exports declarations and selected struct fields.
10. Public enums expose all variants; no per-variant visibility in v1.
11. Use commas (with optional trailing comma) for struct fields and enum variants; semicolons terminate statements.
12. Zero-payload enum variants are values (`Token.eof`), not zero-argument calls (`Token.eof()`).
13. Source is UTF-8; language strings remain `[]u8`.
14. Decimal leading zeroes are ordinary decimal: `00`, `01`, `1.005`, `1e007` are valid.
15. Numeric underscores are permitted only between digits.
16. Float literals are decimal only; no `NaN`/`inf` literals or hex floats.
17. Integer division by zero traps; signed MIN/-1 wraps to MIN and remainder 0.
18. Shift RHS is always `u64`; count >= width traps.
19. Restrict expression statements to calls.
20. Remove core `copy`; keep only essential array primitives such as `len`, `push`, and `pop`.
21. No source-level `void` type; omitted function return means no result, and `fn(T)` is a no-result function type.
22. Keep explicit `Result`/enum matching; no special propagation operator yet.
23. No core slice/view type yet; a generic source-library `Span[T]` is feasible and keeps backing-array lifetime safe.
