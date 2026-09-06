# Implementation guide and known pitfalls

This is non-normative advice derived from several independent prototype implementations: tree interpreter, bytecode VM, C AOT, LLVM JIT experiments, native VM/GC, formatter, LSP, and editor.

## Parser

The grammar is designed for ordinary recursive descent plus Pratt/precedence parsing. Parsing must not depend on a symbol table.

Do not lex `[]` as one token; `[]T` and `[ ]T` should be identical.

Treat dotted access uniformly in the syntax tree and let name resolution decide whether a segment is module qualification, enum qualification, or field selection.

Keep raw literal spelling in lossless/tooling tokens separately from decoded semantic bytes.

## Resolver

Do not identify nominal types/functions by source spelling or mangled output names. Use stable internal symbol/declaration IDs plus explicit owner-module metadata.

Do not let internal mangling accidentally bypass no-shadowing or privacy rules.

Resolve names/constructors during the static phase and annotate AST/IR. The runtime should not call back into the type checker to rediscover enum constructors or functions.

## Type checker

Keep generic inference first-order and structural.

Expected type propagation is important through transparent constructs such as `new`, `some`, numeric literals, arrays, and struct literals. Missing it makes otherwise obvious generic code fail.

Special-case contextual signed-minimum literals correctly (`-128` for `i8` must work even though positive `128` does not fit `i8`).

Use the same scalar semantic routines for constant evaluation and runtime behavior to avoid drift.

## Places

Implement an explicit place/lvalue concept. A naive interpreter that evaluates an intermediate struct field to a copied value will silently lose mutations such as `array[i].field = x`.

Compound assignment must evaluate place subexpressions exactly once.

## VM control flow and GC

If lexical scopes are GC roots, `break`, `continue`, and `return` need to unwind dead scopes/root registrations. A jump alone can keep garbage alive.

Tree interpreters likewise need exception/control-flow-safe scope cleanup (`try/finally`-style internally), otherwise return/trap can leave stale roots/scopes.

## Native GC

The collector itself can be small. Compiler cooperation is the harder part.

Every GC-bearing local and expression temporary that remains live across a potential allocation/collection point must be rooted. Return-value transfer is a common dangerous gap: do not pop a managed return value into an unrooted C/native temporary and then allow GC before the caller roots it.

A clean AOT approach is:

```text
type-check generic code abstractly
 -> monomorphize reachable concrete instantiations
 -> compute concrete GC shapes
 -> lower expressions with explicit temporaries/roots
 -> native backend
```

## C backend

Do not naively transliterate expressions to C:

- C evaluation order is not sufficiently deterministic;
- signed overflow is UB;
- signed right shift and extreme literals require care.

Lower to ordered temporaries and use defined unsigned/bit-pattern helpers where needed.

## Tooling

Compiler source offsets and LSP positions are different coordinate systems: LSP uses UTF-16 units. Terminal display columns are a third coordinate system.

Line-independent lexing makes viewport/incremental highlighting much easier; exploit it.
