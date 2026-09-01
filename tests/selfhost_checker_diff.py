#!/usr/bin/env python3
"""Differential acceptance tests for the L-written semantic frontend.

This intentionally covers only the semantic subset `slang_check` currently
claims. Expanding this corpus is part of growing lcheck toward full Core
conformance; unsupported features must not be silently treated as equivalent.
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
        "ref field place",
        "struct Box { value: i64, } fn main() -> i64 { var b = new Box { value: 1 }; b.value += 2; return b.value; }",
    ),
    (
        "ordinary function value",
        "fn add(a: i64, b: i64) -> i64 { return a + b; } fn main() -> i64 { var f: fn(i64, i64) -> i64 = add; return f(2, 3); }",
    ),
    ("type mismatch", "fn main() -> i64 { var x: bool = 1; return 0; }"),
    ("assign constant", "const X: i64 = 1; fn main() -> i64 { X = 2; return 0; }"),
    ("unknown value", "fn main() -> i64 { return missing; }"),
    ("unknown field", "struct S { x: i64, } fn main() -> i64 { var s = new S { x: 1 }; return s.y; }"),
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
