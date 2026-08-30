# L Core language — review specification

This document describes the current **review snapshot**, extracted from the tested implementation/design work. It is intentionally compact. `03-CORE-SEMANTICS.md` contains the less obvious operational rules.

## Source and lexing

- Source is valid UTF-8.
- Language syntax and identifiers are ASCII.
- Identifier grammar: `[A-Za-z_][A-Za-z0-9_]*`.
- Whitespace is insignificant except as token separation.
- Semicolons terminate simple statements.
- `//` is the only comment form; it ends at newline.
- Strings and byte literals may not cross a source line.
- Therefore lexical state resets at every newline.
- A string literal has type `[]u8` and contains bytes. Raw non-ASCII source characters contribute their UTF-8 bytes.
- A byte literal has type `u8` and must encode exactly one byte.
- There is no language-level `char` or Unicode string type.

## Primitive value types

```text
()                    unit; exactly one value: ()
bool                  true / false

i8 i16 i32 i64        fixed-width signed integers
u8 u16 u32 u64        fixed-width unsigned integers

f32 f64               IEEE-style binary floating-point
```

There are no platform-sized integer aliases (`int`, `usize`, etc.).

## Type constructors

```text
?T                    optional T: none | some(T)
ref T                 non-null managed reference to a heap object
[]T                   non-null mutable dynamic array object
fn(A, B) -> R         function value
```

A function type whose return is omitted returns unit:

```text
fn(i64)               == fn(i64) -> ()
```

## Structs

```text
struct Point {
    x: i64,
    y: i64,
}
```

Structs are nominal value types. Assignment/passing/return copies the struct value. Fields that themselves contain handles (`ref`, `[]`) naturally copy those handles, so copying is shallow with respect to shared objects.

All fields must be supplied by a struct literal; there is no uninitialized value or implicit zero initialization.

## Enums

```text
enum Token {
    eof,
    number(i64),
    location(u64, u64),
}
```

Enums are nominal tagged sums.

A fieldless enum supports `==` and `!=` by tag. Payload enums do not receive implicit structural equality.

## Optional values

There is no `null`.

```text
var head: ?ref Node = none;
head = some(new Node { ... });
```

A `ref T` is intrinsically non-null. Optionality is always visible in the type as `?T`.

There is no force-unwrap operator in Core. Use `if`, `while`, or `match` patterns.

## Managed references

`new expression` creates a fresh managed object and returns `ref T`.

```text
var node: ref Node = new Node { value: 1, next: none };
```

Core has no address-of, pointer arithmetic, pointer/integer casts, `free`, destructors, weak references, or finalizers.

References to reachable objects never dangle. Collection timing is not observable by L code.

## Dynamic arrays

```text
var xs: []i64 = [1, 2, 3];
var empty: []u8 = [];
var repeated: []i64 = [0; 100];
```

Arrays are mutable shared objects. Copying an `[]T` copies the handle, not the elements.

Core array operations are:

```text
len(array) -> u64
push(array, value) -> ()
pop(array) -> T
splice(array, start: u64, end: u64, replacement: []T) -> ()
```

`pop` traps on an empty array. `splice` replaces the half-open range `[start,end)` and traps for an invalid range. If replacement aliases the target array, replacement values are conceptually snapshotted before mutation.

Higher operations such as copying, searching, insertion helpers, sorting, spans/views, maps, sets, queues, etc. belong in libraries.

## Generics

Functions, structs, and enums may have unconstrained type parameters:

```text
struct Pair[A, B] {
    first: A,
    second: B,
}

fn reverse[T](xs: []T) {
    ...
}
```

A type parameter is opaque. Generic code may only use operations known to work independently of the concrete type. There are no constraints, traits, interfaces, type sets, specialization rules, associated types, or user-defined operator capabilities.

If generic code needs behavior, pass an ordinary function value:

```text
fn sort_by[T](xs: []T, less: fn(T, T) -> bool) { ... }
```

Generic calls infer type arguments by exact structural unification from arguments and, where available, the expected result type. No implicit conversions participate.

Generic functions are not first-class polymorphic values. A recursive generic call must preserve its type parameters exactly; mutually recursive generic functions are rejected in the current Core design to keep native monomorphization finite and simple.

## Functions and anonymous functions

```text
fn add(a: i64, b: i64) -> i64 {
    return a + b;
}
```

Top-level functions are first-class function values.

Anonymous functions are allowed:

```text
var less: fn(i64, i64) -> bool = fn(a: i64, b: i64) -> bool {
    return a < b;
};
```

They **do not capture runtime locals**. They may use module declarations and enclosing generic type parameters. Conceptually an implementation may hoist them to hidden top-level functions.

There are no methods, closures, nested named functions, overloading, default arguments, named arguments, or variadic functions.

## Variables and constants

```text
var x: i64 = 3;
var y = some(x);       // initializer-only local inference
```

Every variable has an initializer. Local initializer inference is allowed only when the initializer has a unique type.

Module `const` declarations require an explicit scalar type and a restricted scalar constant expression. Constants are not a general compile-time execution facility.

Mutable global variables do not exist.

## Control flow

Core provides:

```text
if / else
while
for (init; condition; step)
for (name in array)
match
break
continue
return
trap
```

Conditions have type `bool`; integers are not truthy/falsy.

Braces are mandatory.

`trap;` terminates the current execution in a host-defined uncatchable manner. There are no language exceptions.

## Assignment and places

Assignment is a statement, never an expression.

```text
x = 3;
node.value += 1;
array[i] ^= mask;
```

Assignable places include locals, array elements, dereferenced refs, fields of assignable structs, and fields reached through refs.

Every subexpression used to identify an assignment place is evaluated exactly once. Compound assignment evaluates the place once, reads it, evaluates the RHS, applies the operation, and writes it back.

## Patterns

Patterns are intentionally shallow.

Examples:

```text
none
some(value)
some(_)
Token.eof
Token.number(n)
_
true
false
42
'a'
()
```

Constructor payload patterns are bindings or `_`; recursive nested destructuring such as `Result.ok(some(x))` is intentionally not part of Core.

A binding `is` pattern may be the complete condition of `if` or `while`:

```text
while (cursor is some(node)) {
    cursor = node.next;
}
```

A non-binding `is` test may be used as an ordinary boolean expression.

## Modules and visibility

```text
import foo.bar;
import foo.bar as fb;
```

Module names are logical names. Core does not specify files, paths, extensions, repositories, or package managers.

An embedding implementation receives a way to resolve a logical module name to a source module or host module.

Module declarations and struct fields are private by default. `pub` exports a declaration/field. Imports are qualified; wildcard imports and source-level re-export machinery are not part of the current Core.

Import cycles are rejected.

## Deliberately absent

Among other things, Core currently has no:

- null;
- raw pointers/manual free;
- classes/methods/inheritance;
- interfaces/traits/generic constraints;
- capturing closures;
- exceptions or result-propagation syntax;
- macros or compile-time user code;
- reflection;
- operator/function overloading;
- tuples/multiple return values;
- iterator protocol/generators;
- async/await or threads;
- special string/character type;
- standard FFI/ABI;
- filesystem assumptions.
