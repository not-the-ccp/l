#!/usr/bin/env python3
"""Broad, disposable differential probe for the L-written checker.

This is intentionally not a conformance test yet. It generates small programs
covering semantic cross-products and reports every accept/reject disagreement
between the Python oracle and native L-written lcheck.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bootstrap"))
from core import LangError, Program

LCHECK = ROOT / "build" / "lcheck"

CASES: list[tuple[str, str]] = []

def case(name: str, source: str) -> None:
    CASES.append((name, source.strip() + "\n"))

# Contextual literals and fixed-width types.
for ty, good, bad in [
    ("u8", "255", "256"), ("i8", "127", "128"),
    ("u16", "65535", "65536"), ("i16", "32767", "32768"),
    ("u32", "4294967295", "4294967296"),
]:
    case(f"{ty} literal in range", f"fn main() {{ var x: {ty} = {good}; }}")
    case(f"{ty} literal out of range", f"fn main() {{ var x: {ty} = {bad}; }}")
case("negative i8 min", "fn main() { var x: i8 = -128; }")
case("negative i8 below min", "fn main() { var x: i8 = -129; }")
case("contextual arithmetic", "fn main() { var x: i16 = 1 + 2 * 3; }")
case("mixed runtime numeric types", "fn f(a: i32, b: i64) -> i64 { return a + b; }")
case("comparison result context", "fn f(x: u64) -> bool { return x >= 3; }")
case("logical operands bool", "fn f(a: bool, b: bool) -> bool { return a && b; }")
case("logical non-bool", "fn f(a: i64, b: i64) -> bool { return a && b; }")
case("shift count u64", "fn f(x: i32, n: u64) -> i32 { return x << n; }")
case("shift count wrong runtime type", "fn f(x: i32, n: i32) -> i32 { return x << n; }")

# Cast type legality.
case("integer cast", "fn f(x: i64) -> u8 { return x as u8; }")
case("integer float cast", "fn f(x: i64) -> f64 { return x as f64; }")
case("float integer cast", "fn f(x: f64) -> i32 { return x as i32; }")
case("bool numeric cast rejected", "fn f(x: bool) -> i64 { return x as i64; }")
case("array cast rejected", "fn f(x: []u8) -> i64 { return x as i64; }")

# Arrays, aliases and places.
case("empty array expected", "fn main() { var xs: []i64 = []; }")
case("empty array ambiguous", "fn main() { var xs = []; }")
case("heterogeneous array", "fn main() { var xs = [1, true]; }")
case("array element place", "fn main() { var xs: []i64 = [1]; xs[0] += 2; }")
case("temporary array indexing place", "fn make() -> []i64 { return [1]; } fn main() { make()[0] = 2; }")
case("repeat count u64", "fn main() { var xs: []i64 = [1; 3]; }")
case("repeat count wrong type", "fn f(n: i64) { var xs: []i64 = [1; n]; }")

# Struct construction and field semantics.
case("struct exact fields", "struct S { a: i64, b: bool, } fn main() { var s = S { a: 1, b: true }; }")
case("struct missing field", "struct S { a: i64, b: bool, } fn main() { var s = S { a: 1 }; }")
case("struct extra field", "struct S { a: i64, } fn main() { var s = S { a: 1, b: 2 }; }")
case("struct wrong field type", "struct S { a: i64, } fn main() { var s = S { a: true }; }")
case("nested value place", "struct I { x: i64, } struct O { inner: I, } fn main() { var o = O { inner: I { x: 1 } }; o.inner.x = 3; }")
case("temporary struct field nonplace", "struct S { x: i64, } fn make() -> S { return S { x: 1 }; } fn main() { make().x = 2; }")

# Optionals and refs.
case("optional explicit some", "fn main() { var x: ?i64 = some(1); }")
case("optional implicit wrap rejected", "fn main() { var x: ?i64 = 1; }")
case("none expected optional", "fn main() { var x: ?i64 = none; }")
case("none ambiguous", "fn main() { var x = none; }")
case("ref allocation", "struct S { x: i64, } fn main() { var s: ref S = new S { x: 1 }; }")
case("new expected mismatch", "struct S { x: i64, } fn main() { var s: ref S = new 1; }")
case("deref ref", "struct S { x: i64, } fn f(s: ref S) -> S { return *s; }")
case("deref nonref", "fn f(x: i64) -> i64 { return *x; }")

# Functions and control flow.
case("call exact arity", "fn f(x: i64) -> i64 { return x; } fn main() -> i64 { return f(1); }")
case("call too many args", "fn f(x: i64) -> i64 { return x; } fn main() -> i64 { return f(1, 2); }")
case("call wrong arg type", "fn f(x: i64) -> i64 { return x; } fn main() -> i64 { return f(true); }")
case("if requires bool", "fn main() { if (1) { return; } }")
case("while requires bool", "fn main() { while (1) { break; } }")
case("for-in array", "fn f(xs: []i64) -> i64 { var s: i64 = 0; for (x in xs) { s += x; } return s; }")
case("for-in nonarray", "fn f(x: i64) { for (y in x) { } }")
case("continue outside loop", "fn main() { continue; }")
case("call expression statement", "fn f() {} fn main() { f(); }")
case("noncall expression statement", "fn main() { 1 + 2; }")

# Patterns and coverage (the stacked branch includes exhaustiveness checking).
case("bool exhaustive", "fn f(x: bool) -> i64 { match (x) { true { return 1; } false { return 0; } } }")
case("bool missing arm", "fn f(x: bool) -> i64 { match (x) { true { return 1; } } }")
case("optional exhaustive", "fn f(x: ?i64) -> i64 { match (x) { none { return 0; } some(v) { return v; } } }")
case("optional missing arm", "fn f(x: ?i64) -> i64 { match (x) { none { return 0; } } }")
case("integer wildcard", "fn f(x: i64) -> i64 { match (x) { 0 { return 0; } _ { return 1; } } }")
case("integer no wildcard", "fn f(x: i64) -> i64 { match (x) { 0 { return 0; } 1 { return 1; } } }")
case("duplicate bool arm", "fn f(x: bool) -> i64 { match (x) { true { return 1; } true { return 2; } false { return 0; } } }")

# Generic inference and abstract checking.
case("generic identity", "fn id[T](x: T) -> T { return x; } fn main() -> i64 { return id(1); }")
case("generic expected result", "fn empty[T]() -> []T { return []; } fn main() { var xs: []u8 = empty(); }")
case("generic conflict", "fn f[T](a: T, b: T) -> T { return a; } fn main() { var x = f(1, true); }")
case("generic unconstrained", "fn empty[T]() -> []T { return []; } fn main() { empty(); }")
case("generic abstract invalid op", "fn add[T](a: T, b: T) -> T { return a + b; }")
case("generic direct changing recursion", "fn bad[T](x: T) { bad([x]); } fn main() { bad(1); }")
case("generic direct same recursion", "fn ok[T](x: T, n: i64) { if (n > 0) { ok(x, n - 1); } } fn main() { ok(1, 3); }")


def python_accepts(source: str) -> bool:
    try:
        Program({("probe",): source}, host_modules={})
        return True
    except LangError:
        return False


def lcheck_accepts(source: str) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory(prefix="lcheck-matrix-") as td:
        p = Path(td) / "case.l"
        p.write_text(source, encoding="utf-8")
        proc = subprocess.run([str(LCHECK), str(p)], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, timeout=20)
        return proc.returncode == 0, proc.stdout


def main() -> int:
    mismatches = []
    for name, source in CASES:
        oracle = python_accepts(source)
        actual, output = lcheck_accepts(source)
        if oracle != actual:
            mismatches.append((name, oracle, actual, output.strip(), source))
            print(f"MISMATCH {name}: python={oracle} lcheck={actual}")
        else:
            print(f"PASS {name}: {'accept' if actual else 'reject'}")
    print(f"\nprobe: {len(CASES)} cases, {len(mismatches)} mismatch(es)")
    for name, oracle, actual, output, source in mismatches:
        print(f"\n=== {name} ===\npython={oracle} lcheck={actual}\n{source}")
        if output:
            print(f"lcheck output:\n{output}")
    # Deliberately fail when mismatches exist so the workflow highlights them.
    return 1 if mismatches else 0

if __name__ == '__main__':
    raise SystemExit(main())
