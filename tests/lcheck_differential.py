#!/usr/bin/env python3
"""Differential acceptance testing for the L-written semantic checker.

This intentionally compares language acceptance, not diagnostic wording.  The Python
bootstrap checker remains the semantic oracle until the L-written frontend reaches
full Core coverage; every case in this corpus must therefore either be accepted by
both checkers or rejected by both.
"""
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

CASES: list[tuple[str, str]] = [
    (
        "basic arithmetic",
        """
fn add(a: i64, b: i64) -> i64 { return a + b; }
fn main() -> i64 { var x: i64 = add(2, 3); return x; }
""",
    ),
    (
        "linked optional refs",
        """
struct Node { value: i64, next: ?ref Node, }
fn prepend(head: ?ref Node, value: i64) -> ref Node {
    return new Node { value: value, next: head };
}
fn sum(head: ?ref Node) -> i64 {
    var total: i64 = 0;
    var cursor: ?ref Node = head;
    while (cursor is some(node)) {
        total += node.value;
        cursor = node.next;
    }
    return total;
}
""",
    ),
    (
        "arrays and places",
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
        "function values and anonymous function",
        """
fn apply(f: fn(i64) -> i64, x: i64) -> i64 { return f(x); }
fn main() -> i64 {
    var inc: fn(i64) -> i64 = fn(x: i64) -> i64 { return x + 1; };
    return apply(inc, 4);
}
""",
    ),
    (
        "type mismatch rejected",
        """
fn main() { var x: i64 = true; }
""",
    ),
    (
        "non-place assignment rejected",
        """
struct S { x: i64, }
fn make() -> S { return S { x: 1 }; }
fn main() { make().x = 2; }
""",
    ),
    (
        "capture rejected",
        """
fn main() {
    var x: i64 = 1;
    var f: fn() -> i64 = fn() -> i64 { return x; };
}
""",
    ),
    (
        "bad return rejected",
        """
fn value() -> i64 { if (true) { return 1; } }
""",
    ),
    (
        "break outside loop rejected",
        """
fn main() { break; }
""",
    ),
]


def accepted(cmd: list[str], path: Path) -> tuple[bool, str]:
    proc = subprocess.run(
        [*cmd, str(path)],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
    )
    return proc.returncode == 0, proc.stdout


def main() -> int:
    mismatches: list[str] = []
    with tempfile.TemporaryDirectory(prefix="lcheck-diff-") as td:
        tmp = Path(td)
        for index, (name, source) in enumerate(CASES):
            path = tmp / f"case_{index}.l"
            path.write_text(source.strip() + "\n", encoding="utf-8")
            oracle_ok, oracle_out = accepted([str(ROOT / "lc"), "--check"], path)
            l_ok, l_out = accepted([str(ROOT / "lcheck")], path)
            if oracle_ok != l_ok:
                mismatches.append(
                    f"{name}: lc={'accept' if oracle_ok else 'reject'}, "
                    f"lcheck={'accept' if l_ok else 'reject'}\n"
                    f"--- lc ---\n{oracle_out}--- lcheck ---\n{l_out}"
                )
            else:
                print(f"PASS differential {name}: {'accept' if oracle_ok else 'reject'}")

    if mismatches:
        print("\n\n".join(mismatches))
        print(f"\nlcheck differential: {len(mismatches)} mismatch(es)")
        return 1
    print(f"lcheck differential: {len(CASES)} matched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
