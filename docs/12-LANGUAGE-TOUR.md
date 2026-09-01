# A tour of L

This is the user-oriented introduction to the current L language. It is intentionally less formal than the Core specification.

L is a small statically typed C-family language aimed at ordinary programs while keeping parsing, interpretation, compilation, embedding, and tooling unusually straightforward.

It is **not** a small C clone. C-like mainly means braces, infix operators, functions, and familiar imperative control flow. L deliberately avoids C declarators, nullable pointers, integer-promotion rules, undefined signed overflow, a preprocessor, and filesystem-defined modules.

## A first function

```l
fn max(a: i64, b: i64) -> i64 {
    if (a > b) {
        return a;
    }
    return b;
}
```

Braces are mandatory. Conditions are `bool`; integers are not truthy/falsy.

A function with no written return type returns unit, `()`:

```l
fn touch() {
    return;
}
```

`return;` is equivalent to returning `()`.

## Primitive types

L has fixed, portable scalar types:

```text
()
bool

i8  i16  i32  i64
u8  u16  u32  u64

f32 f64
```

There is no platform-dependent `int`, `long`, `size_t`, or `usize` in Core.

Numeric conversions are explicit:

```l
var small: u8 = 10;
var wide: u64 = small as u64;
```

Numeric literals are contextually typed where the surrounding type is clear, so `10` does not need a suffix in the first declaration.

Integer arithmetic has fixed-width, specified behavior. Ordinary arithmetic wraps at the type width; division by zero traps. See the semantics document for exact edge cases.

## Variables

Every local variable is initialized:

```l
var count: i64 = 0;
var next = count + 1;
```

The second form uses initializer-only local inference. L does not infer function parameter types, public APIs, or large webs of constraints.

There are no uninitialized locals.

## Bytes, strings, and arrays

There is no special string type. A string literal is a mutable byte array:

```l
var message: []u8 = "hello";
```

`[]T` is a mutable dynamic array object. Copying an array value copies its handle, not its elements:

```l
var a: []i64 = [1, 2, 3];
var b = a;
b[0] = 9;
// a[0] is now also 9
```

Core provides only the operations that cannot be written efficiently and portably in ordinary L:

```l
len(a)
push(a, value)
pop(a)
splice(a, start, end, replacement)
```

Higher-level operations such as copying, sorting, searching, maps, sets, queues, and spans belong in libraries.

A string is simply bytes. The language does not define Unicode characters, graphemes, case folding, normalization, or text encodings. Portable libraries may interpret a `[]u8` as UTF-8 when desired.

## Structs

Structs are nominal value types:

```l
struct Point {
    x: i64,
    y: i64,
}

var p = Point {
    x: 10,
    y: 20,
};
```

Every field must be initialized. There is no implicit zero initialization.

Struct assignment copies the struct value. If a field contains a handle such as `[]T` or `ref T`, the handle itself is copied, so the referenced object remains shared.

## Managed references

Ordinary programs need linked lists, trees, graphs, ASTs, and shared mutable identity. L provides that directly with `ref T`:

```l
struct Node {
    value: i64,
    next: ?ref Node,
}

var node: ref Node = new Node {
    value: 42,
    next: none,
};
```

A `ref T` is always non-null and points to a managed object created by `new`.

Core deliberately has no:

- address-of operator;
- raw pointer arithmetic;
- integer/pointer casts;
- manual `free`;
- destructors/finalizers;
- dangling references.

A simple implementation can use its host language's tracing GC; a native implementation can provide its own collector. Collection timing is not observable by L programs.

Fields through refs use ordinary dot syntax:

```l
node.value += 1;
```

## Optional values: no `null`

Absence is explicit in the type system:

```l
?T
```

An optional value is either `none` or `some(value)`:

```l
var head: ?ref Node = none;
head = some(new Node {
    value: 1,
    next: head,
});
```

There is no `null` and no force-unwrap operator.

Unwrap by pattern matching:

```l
while (head is some(node)) {
    // node has type ref Node here
    head = node.next;
}
```

or with `match`:

```l
match (head) {
    none {
        // empty
    }
    some(node) {
        // use node
    }
}
```

Patterns are intentionally shallow rather than growing into a general destructuring sub-language.

## Enums

Enums are tagged sums:

```l
enum Token {
    eof,
    number(i64),
    error([]u8),
}
```

Construct values directly:

```l
var t: Token = Token.number(123);
```

and inspect them with `match`:

```l
match (t) {
    Token.eof {
        return;
    }
    Token.number(value) {
        use_number(value);
    }
    Token.error(message) {
        report(message);
    }
}
```

Fieldless enums support `==` and `!=` by tag. Payload enums do not automatically get recursive structural equality.

Enums are the ordinary way to model parser tokens, AST nodes, state machines, and library-level result/error values.

## Generics

L has deliberately small unconstrained parametric generics:

```l
struct Pair[A, B] {
    first: A,
    second: B,
}

fn reverse[T](xs: []T) {
    var left: u64 = 0;
    var right = len(xs);

    while (left < right) {
        right -= 1;
        var tmp: T = xs[left];
        xs[left] = xs[right];
        xs[right] = tmp;
        left += 1;
    }
}
```

A type parameter is opaque. `T` does not implicitly support arithmetic, comparison, methods, hashing, or any other operation.

If generic code needs behavior, pass it explicitly:

```l
fn sort_by[T](xs: []T, less: fn(T, T) -> bool) {
    // algorithm uses less(a, b)
}
```

There are no traits, interfaces, type sets, generic constraints, specialization rules, or associated types.

Calls infer generic arguments by exact structural unification from ordinary arguments and, when available, the expected result type.

## Function values and anonymous functions

Top-level functions are first-class values:

```l
fn less_i64(a: i64, b: i64) -> bool {
    return a < b;
}

var cmp: fn(i64, i64) -> bool = less_i64;
```

Anonymous functions are also supported:

```l
var cmp: fn(i64, i64) -> bool = fn(a: i64, b: i64) -> bool {
    return a < b;
};
```

Anonymous functions do **not** capture runtime locals. This keeps a function value representable as an ordinary function pointer/function ID rather than a code-plus-environment closure object.

When state is required, pass it explicitly as another argument or through a `ref` context object.

## Control flow

L has intentionally ordinary imperative control flow:

```l
if (condition) {
    ...
} else {
    ...
}

while (condition) {
    ...
}

for (var i: u64 = 0; i < len(xs); i += 1) {
    ...
}

for (item in xs) {
    ...
}
```

`for (item in xs)` is array-specific sugar, not an iterator protocol.

There are also:

```text
break
continue
return
match
trap
```

`trap;` is an uncatchable execution failure. Exceptions are not part of Core.

## Assignment and evaluation order

Assignment is a statement rather than an expression:

```l
x = 3;
array[i] += 1;
node.flags ^= mask;
```

L defines evaluation order left-to-right.

Assignment places are evaluated exactly once. For example, an implementation must not evaluate the index expression twice in:

```l
a[next_index()] += value();
```

These rules avoid a class of C-style unspecified-order surprises and make interpreters, compilers, and source analysis agree on program behavior.

## Modules

Modules use logical names:

```l
import math;
import company.parser as parser;
```

The language does **not** say that `company.parser` means a particular directory or extension.

An implementation or embedding environment decides how logical names resolve. They may map to files, in-memory source, generated modules, embedded resources, native host modules, or something else.

Declarations and struct fields are private by default. `pub` makes them visible to importing modules.

Imports are qualified; wildcard imports are not part of Core.

## Core versus the environment

A freestanding Core implementation can exist without files, processes, terminals, command-line arguments, networking, or even a conventional `main` function.

Environment-specific capabilities enter through typed host modules.

The bundled command-line implementation provides enough host support to run examples and Lace, but those APIs are not requirements for another L implementation.

## What L deliberately does not have

The current Core intentionally omits many familiar features:

- raw pointers and manual memory management;
- `null`;
- methods/classes/inheritance;
- interfaces/traits/generic constraints;
- capturing closures;
- exceptions and `try` propagation syntax;
- operator/function overloading;
- macros and compile-time user code;
- reflection;
- tuples/multiple returns;
- general iterators/generators;
- async/await or a concurrency model;
- a built-in Unicode string/character abstraction;
- a standardized C ABI or filesystem package layout.

These omissions are not claims that the features are universally bad. The project requires a demonstrated recurring problem before adding a new semantic mechanism to Core.

## Try the existing examples

From the repository root:

```sh
./lc --check examples/core/linked_list.l
./lc --check examples/core/generic_queue.l

./lc analyze examples/core/linked_list.l
./lc analyze examples/core/linked_list.l --flowchart -o linked-list.mmd
```

Hosted examples can be compiled and run using the bundled command-line host profile:

```sh
./lr examples/hosted/hello.l -- hello world
```

For exact rules, continue with [`01-CORE-LANGUAGE.md`](01-CORE-LANGUAGE.md) and [`03-CORE-SEMANTICS.md`](03-CORE-SEMANTICS.md).
