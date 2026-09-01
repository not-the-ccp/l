# L design notes from the Lace 0.8 usability/safety iteration

These notes separate **language conclusions** from bugs in a particular editor/runtime implementation. The goal is to keep changing L only when real programs demonstrate a language-level problem.

## What the editor bugs taught us

### Terminal ownership is a runtime/host invariant

The first Lace prototype let the kernel turn `Ctrl-C` into `SIGINT` while the terminal was in raw/full-screen mode. That could terminate an unsaved editor and strand the user's terminal in raw mode.

The corrected native terminal host:

- disables `ISIG` while the editor owns raw mode, so `Ctrl-C` is an input byte the editor can interpret;
- registers emergency cleanup for ordinary runtime failure and terminating signals;
- restores termios, cursor visibility, styles, and alternate-screen state on exit;
- temporarily gives normal terminal/signal semantics back to `:!` child commands.

This is **not** evidence for exceptions, destructors, `defer`, or RAII in L. It is evidence that a terminal host capability must have a precise ownership/cleanup contract.

### Semantic highlighting is state, not a disposable render product

Clearing all semantic tokens immediately after every edit guaranteed visible white -> colored flicker. The right model is:

1. retain the last accepted semantic-token map;
2. transform unaffected token positions through local edits;
3. tag async requests with the document revision;
4. accept a reply only when it still matches that revision;
5. replace the cache atomically.

Diagnostics are handled similarly: unaffected later diagnostics shift with edits, while diagnostics touching the changed range are hidden until republished rather than knowingly rendered at a stale location.

Again, this required no language feature. It required a correct asynchronous-state model.

### Buffer bytes, LSP coordinates, and terminal cells are different domains

An earlier editor accidentally reused UTF-16 LSP columns as terminal columns. That is incorrect for tabs, combining marks, CJK/wide characters, and emoji.

Lace now keeps:

- byte offsets for the L buffer;
- UTF-16 positions only at the LSP boundary;
- display-cell positions only at the terminal boundary.

`term.text_width([]u8) -> u64` is a host capability because terminal display width is environmental. The editor handles configured tab stops and common grapheme cases while L itself remains byte-oriented.

This strongly reinforces the decision **not** to add a core `char` or Unicode string type merely because tooling must display Unicode correctly.

### `:!` validated the host-module boundary

`:!command` required shell/process behavior, signal inheritance, terminal suspension, and inherited stdio. All of that belongs in `proc`/`term`, not in the language grammar.

The source implementation remains ordinary state-machine code:

```text
leave UI -> proc.shell(command) -> wait -> enter UI
```

No `async`, threads, exceptions, or magic editor runtime were needed.

## Source-language conclusions that continue to hold

### `splice` remains justified as a core dynamic-array primitive

The editor is the strongest argument so far. Inserting/deleting bytes through an L-level element-shifting loop made a simple VM execute hundreds of thousands of operations for normal buffer edits. A representation-independent primitive

```text
splice(array, start, end, replacement);
```

lets interpreters/VMs use efficient native movement without changing aliasing semantics or exposing capacity/pointers.

The useful primitive dynamic-array set remains small: `len`, `push`, `pop`, `splice`.

### Line-independent lexing is a real product feature

Because L has no multiline lexical constructs, the LSP can lex only the visible range for semantic tokens without reconstructing lexer state from the beginning of the document. That materially improves large-file editor behavior.

This restriction continues to earn its place.

### `[]u8` continues to survive real text-heavy workloads

Lace, JSON, JSON-RPC, LSP framing, UTF-8/UTF-16 conversion, search, terminal input, compiler-like parsing, configuration parsing, and shell command handling all remain practical using `[]u8` plus libraries.

The editor needing Unicode display correctness did **not** imply that L needs a Unicode scalar/character type.

### Managed `ref T` is still not the performance problem

Profiling repeatedly found costs in whole-document algorithms, byte movement, IPC, rendering, and name lookup—not in tracing GC itself. Native GC/rooting correctness required implementation work, but moving memory lifetime bugs into every L program would still be the worse trade.

### Small generics + noncapturing functions remain sufficient

The editor/LSP framework continues to be callback- and collection-heavy without producing a compelling need for:

- generic constraints;
- interfaces/traits;
- method dispatch;
- capturing closures.

Explicit state objects and ordinary function values remain adequate.

### Visual selection, theming, editor commands, undo, and modal composition required no new language machinery

A much more capable editor was built using the existing structs/enums/functions/arrays/refs. The usability work changed the **library/application design**, not L's type system or grammar. That is a healthy result.

## Tooling architecture lessons

### Source origin is part of semantic metadata

A presentable compiler cannot report a type error in an imported module as if it came from the entry file. The checker already tracked declaration origin for privacy; v0.8 now carries that through CLI diagnostics.

Canonical symbol identity, source module identity, source spans, and backend-mangled names should remain separate concepts.

### Lossless frontend data remains important

The formatter/highlighter experiments already showed why tokens need raw spelling as well as decoded values. The editor work reinforces the likely long-term architecture:

```text
lossless tokens/CST -> resolved semantic AST/IR
```

rather than trying to use one minimal AST for compiler, formatter, refactoring, and LSP features.

### Responsive tools need nonblocking host operations, not necessarily language async

Lace uses timed terminal/process reads and explicit state. That has remained understandable and performant. If future non-editor programs demonstrate a recurring need for structured concurrency, that should be evaluated independently rather than inferred from "editors have event loops".

## Current negative results

Even after implementing a native runtime, compiler driver, three LSPs, a JSON implementation, UTF-8 helpers, a recursive-descent L frontend, and a substantially more usable modal editor, there is still no demonstrated requirement for:

```text
classes / methods
interfaces / traits
generic constraints
capturing closures
exceptions / try propagation
raw pointers / manual free
async / await
generators / iterator protocols
reflection
macros
operator or function overloading
special string / char types
```

The bar for those features should remain high.

## Current source-language shape

The design being exercised remains roughly:

```text
()
bool
i8 i16 i32 i64
u8 u16 u32 u64
f32 f64

[]T
ref T
?T

struct
enum
unconstrained generics
function values
noncapturing anonymous functions

var
restricted scalar const

if / else
while
C-style for
array-only for-in
match
return / break / continue
trap

modules, private by default, with pub
```

Important rules still include:

- `ref T` is non-null and created through `new`;
- absence is `?T` (`none` / `some`), never null;
- no user-visible deallocation;
- flat payload patterns rather than recursive nested destructuring in v1;
- fieldless enums have tag equality; payload enums do not gain recursive equality;
- contextual numeric literals but no general implicit numeric conversion;
- assignment is a statement with single-evaluation place semantics;
- evaluation order is left-to-right;
- host modules are the environment/FFI boundary;
- logical module names do not imply filesystem paths in the language specification.
