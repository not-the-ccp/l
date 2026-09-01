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
