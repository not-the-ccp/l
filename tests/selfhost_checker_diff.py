#!/usr/bin/env python3
"""Differential acceptance tests for the L-written semantic frontend.

This compares language acceptance, not diagnostic spelling.  The Python bootstrap
checker remains the semantic oracle until the L-written frontend reaches full Core
coverage.  Every case in this corpus must therefore be accepted by both checkers or
rejected by both; adding a new checker feature should add representative cases here.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bootstrap"))

from core import LangError, Program

LCHECK = ROOT / "build" / "lcheck"

CASES = [
    ("unit", "fn main() { return; }"),
    ("numeric locals", "fn main() -> i64 { var x: i64 = 2; x += 3; return x * 4; }"),
    (
        "linked list",
        """
struct Node { value: i64, next: ?ref Node, }
fn prepend(head: ?ref Node, value: i64) -> ?ref Node {
    return some(new Node { value: value, next: head });
}
fn sum(head: ?ref Node) -> i64 {
    var total: i64 = 0;
    var cursor = head;
    while (cursor is some(node)) {
        total += node.value;
        cursor = node.next;
    }
    return total;
}
""",
    ),
    (
        "array indexing",
        "fn main() -> i64 { var xs: []i64 = [1, 2, 3]; xs[1] = 7; return xs[1]; }",
    ),
    (
        "mutable array to const view",
        "fn main() -> i64 { var xs: []i64 = [1, 2]; var view: const []i64 = xs; return view[0]; }",
    ),
    (
        "const array to mutable rejected",
        "fn main() -> i64 { var view: const []i64 = [1, 2]; var xs: []i64 = view; return xs[0]; }",
    ),
    (
        "const array index write rejected",
        "fn main() -> i64 { var view: const []i64 = [1, 2]; view[0] = 3; return 0; }",
    ),
    (
        "const array read and iteration",
        "fn sum(xs: const []i64) -> i64 { var out: i64 = 0; for (x in xs) { out += x; } return out; } fn main() -> i64 { var xs: []i64 = [1, 2]; return sum(xs); }",
    ),
    (
        "const push rejected",
        "fn main() { var xs: const []i64 = [1]; push(xs, 2); }",
    ),
    (
        "const pop rejected",
        "fn main() -> i64 { var xs: const []i64 = [1]; return pop(xs); }",
    ),
    (
        "const splice target rejected",
        "fn main() { var xs: const []i64 = [1]; splice(xs, 0, 1, [2]); }",
    ),
    (
        "const splice replacement accepted",
        "fn main() -> i64 { var dst: []u8 = []; var src = \"abc\"; splice(dst, 0, 0, src); return len(dst) as i64; }",
    ),
    (
        "inferred string is const",
        "fn main() { var text = \"x\"; text[0] = 'y'; }",
    ),
    (
        "contextual mutable string",
        "fn main() -> i64 { var text: []u8 = \"x\"; text[0] = 'y'; return text[0] as i64; }",
    ),
    (
        "generic const parameter accepts mutable",
        "fn first[T](xs: const []T) -> T { return xs[0]; } fn main() -> i64 { var xs: []i64 = [7]; return first(xs); }",
    ),
    (
        "generic const parameter accepts string",
        "fn first[T](xs: const []T) -> T { return xs[0]; } fn main() -> i64 { return first(\"x\") as i64; }",
    ),
    (
        "generic mutable parameter rejects inferred string",
        "fn first_mut[T](xs: []T) -> T { return xs[0]; } fn main() -> i64 { return first_mut(\"x\") as i64; }",
    ),
    (
        "mutable generic result to const context",
        "fn one[T](x: T) -> []T { return [x]; } fn main() -> i64 { var xs: const []i64 = one(4); return xs[0]; }",
    ),
    (
        "const generic result to mutable context rejected",
        "fn readonly[T](xs: const []T) -> const []T { return xs; } fn main() -> i64 { var xs: []i64 = readonly([4]); return xs[0]; }",
    ),
    (
        "shallow const outer conversion",
        "fn main() -> i64 { var inner: []i64 = [1]; var nested: [][]i64 = [inner]; var view: const [][]i64 = nested; view[0][0] = 2; return inner[0]; }",
    ),
    (
        "nested qualifier does not lift",
        "fn main() -> i64 { var nested: [][]i64 = [[1]]; var view: const []const []i64 = nested; return view[0][0]; }",
    ),
    (
        "const ref slots still permit referent mutation",
        "struct Box { value: i64, } fn main() -> i64 { var items: []ref Box = [new Box { value: 1 }]; var view: const []ref Box = items; view[0].value = 3; return view[0].value; }",
    ),
    (
        "nested array struct place",
        """
struct Pair { left: i64, right: i64, }
fn main() -> i64 {
    var xs: []Pair = [Pair { left: 1, right: 2 }, Pair { left: 3, right: 4 }];
    xs[1].left += 10;
    push(xs, Pair { left: 5, right: 6 });
    return xs[1].left + pop(xs).right;
}
""",
    ),
    (
        "ref field place",
        "struct Box { value: i64, } fn main() -> i64 { var b = new Box { value: 1 }; b.value += 2; return b.value; }",
    ),
    (
        "enum payload match",
        """
enum Result { ok(i64), err(u8), }
fn get(x: Result) -> i64 {
    match (x) {
        Result.ok(value) { return value; }
        Result.err(_) { return -1; }
    }
}
""",
    ),
    (
        "ordinary function value",
        "fn add(a: i64, b: i64) -> i64 { return a + b; } fn main() -> i64 { var f: fn(i64, i64) -> i64 = add; return f(2, 3); }",
    ),
    (
        "noncapturing anonymous function",
        """
fn apply(f: fn(i64) -> i64, x: i64) -> i64 { return f(x); }
fn main() -> i64 {
    var inc: fn(i64) -> i64 = fn(x: i64) -> i64 { return x + 1; };
    return apply(inc, 4);
}
""",
    ),
    ("type mismatch", "fn main() -> i64 { var x: bool = 1; return 0; }"),
    ("assign constant", "const X: i64 = 1; fn main() -> i64 { X = 2; return 0; }"),
    ("unknown value", "fn main() -> i64 { return missing; }"),
    ("unknown field", "struct S { x: i64, } fn main() -> i64 { var s = new S { x: 1 }; return s.y; }"),
    (
        "temporary field is not a place",
        "struct S { x: i64, } fn make() -> S { return S { x: 1 }; } fn main() { make().x = 2; }",
    ),
    ("bad expression statement", "fn main() -> i64 { 1; return 0; }"),
    ("break outside loop", "fn main() -> i64 { break; return 0; }"),
    ("missing return", "fn main() -> i64 { var x: i64 = 1; }"),
    ("call arity", "fn f(x: i64) -> i64 { return x; } fn main() -> i64 { return f(); }"),
    ("anonymous capture", "fn main() -> i64 { var x: i64 = 1; var f: fn() -> i64 = fn() -> i64 { return x; }; return 0; }"),
    (
        "generic identity inference",
        "fn identity[T](x: T) -> T { return x; } fn main() -> i64 { return identity(7); }",
    ),
    (
        "generic expected-result inference",
        "fn empty[T]() -> []T { return []; } fn main() { var xs: []i64 = empty(); }",
    ),
    (
        "generic struct inference",
        "struct Box[T] { value: T, } fn main() -> i64 { var b: Box[i64] = Box { value: 4 }; return b.value; }",
    ),
    (
        "generic enum inference and pattern",
        "enum Maybe[T] { just(T), nothing, } fn get(x: Maybe[i64]) -> i64 { match (x) { Maybe.just(v) { return v; } Maybe.nothing { return 0; } } } fn main() -> i64 { var x: Maybe[i64] = Maybe.just(9); return get(x); }",
    ),
    (
        "generic queue core example",
        """
struct Queue[T] { items: []T, head: u64, }
fn queue_new[T]() -> ref Queue[T] { return new Queue { items: [], head: 0 }; }
fn queue_push[T](q: ref Queue[T], value: T) { push(q.items, value); }
fn queue_pop[T](q: ref Queue[T]) -> ?T {
    if (q.head >= len(q.items)) { return none; }
    var value: T = q.items[q.head];
    q.head += 1;
    return some(value);
}
fn main() -> i64 {
    var q: ref Queue[i64] = queue_new();
    queue_push(q, 5);
    match (queue_pop(q)) { some(v) { return v; } none { return 0; } }
}
""",
    ),
    (
        "generic function is not first class",
        "fn identity[T](x: T) -> T { return x; } fn main() { var f = identity; }",
    ),
    (
        "conflicting generic inference rejected",
        "fn choose[T](a: T, b: T) -> T { return a; } fn main() { var x = choose(1, true); }",
    ),
    (
        "unconstrained generic inference rejected",
        "fn empty[T]() -> []T { return []; } fn main() { empty(); }",
    ),
    (
        "type-changing generic recursion rejected",
        "fn bad[T](x: T) { bad([x]); } fn main() { bad(1); }",
    ),
    (
        "exhaustive bool match",
        "fn f(x: bool) -> i64 { match (x) { true { return 1; } false { return 0; } } }",
    ),
    (
        "non-exhaustive bool match",
        "fn f(x: bool) -> i64 { match (x) { true { return 1; } } }",
    ),
    (
        "non-exhaustive optional match",
        "fn f(x: ?i64) -> i64 { match (x) { some(v) { return v; } } }",
    ),
    (
        "non-exhaustive enum match",
        "enum Color { red, green, blue, } fn f(x: Color) -> i64 { match (x) { red { return 1; } green { return 2; } } }",
    ),
    (
        "integer match requires catchall",
        "fn f(x: i64) -> i64 { match (x) { 0 { return 0; } 1 { return 1; } } }",
    ),
    (
        "integer binding catchall",
        "fn f(x: i64) -> i64 { match (x) { 0 { return 0; } other { return other; } } }",
    ),
    (
        "duplicate bool arm",
        "fn f(x: bool) -> i64 { match (x) { true { return 1; } true { return 2; } false { return 0; } } }",
    ),
    (
        "unit match exhaustive",
        "fn f(x: ()) -> i64 { match (x) { () { return 1; } } }",
    ),
    ("u8 literal max", "fn main() { var x: u8 = 255; }"),
    ("u8 literal overflow", "fn main() { var x: u8 = 256; }"),
    ("i8 literal max", "fn main() { var x: i8 = 127; }"),
    ("i8 positive overflow", "fn main() { var x: i8 = 128; }"),
    ("i8 signed minimum", "fn main() { var x: i8 = -128; }"),
    ("i8 negative overflow", "fn main() { var x: i8 = -129; }"),
    ("u16 literal overflow", "fn main() { var x: u16 = 65536; }"),
    ("i16 literal overflow", "fn main() { var x: i16 = 32768; }"),
    ("u32 literal overflow", "fn main() { var x: u32 = 4294967296; }"),
    ("i64 literal max", "fn main() { var x = 9223372036854775807; }"),
    ("default i64 overflow", "fn main() { var x = 9223372036854775808; }"),
    ("i64 signed minimum", "fn main() { var x: i64 = -9223372036854775808; }"),
    ("u64 literal max", "fn main() { var x: u64 = 18446744073709551615; }"),
    ("u64 literal overflow", "fn main() { var x: u64 = 18446744073709551616; }"),
    ("hex contextual literal", "fn main() { var x: u8 = 0xff; }"),
    ("hex contextual overflow", "fn main() { var x: u8 = 0x100; }"),
    ("binary contextual literal", "fn main() { var x: i8 = 0b0111_1111; }"),
    ("binary contextual overflow", "fn main() { var x: i8 = 0b1000_0000; }"),
    ("decimal underscore literal", "fn main() { var x: u16 = 65_535; }"),
    ("unsigned unary minus remains valid", "fn main() { var x: u8 = -1; }"),
]


def python_accepts(source: str) -> bool:
    try:
        Program({("test",): source}, host_modules={})
        return True
    except LangError:
        return False


def lcheck_accepts(source: str) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory(prefix="lcheck-diff-") as td:
        path = Path(td) / "case.l"
        path.write_text(source, encoding="utf-8")
        proc = subprocess.run(
            [str(LCHECK), str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
        return proc.returncode == 0, proc.stdout


def main() -> int:
    if not LCHECK.is_file():
        print(f"missing {LCHECK}; build tools first", file=sys.stderr)
        return 2

    failed = 0
    for name, source in CASES:
        expected = python_accepts(source)
        actual, output = lcheck_accepts(source)
        if actual != expected:
            failed += 1
            print(f"FAIL {name}: Python oracle={expected}, lcheck={actual}")
            if output.strip():
                print(output.rstrip())
        else:
            print(f"PASS {name}: {'accept' if actual else 'reject'}")

    if failed:
        print(f"self-hosted checker differential: {failed} disagreement(s)")
        return 1
    print(f"self-hosted checker differential: {len(CASES)} agreements")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
