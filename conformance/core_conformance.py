#!/usr/bin/env python3
"""Core-only conformance seed for the bundled reference implementation.

Deliberately provides no portable library modules and no host modules.
"""
from __future__ import annotations
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bootstrap"))

from bytecode import BCCompiler, BCVM
from core import Program, LangError, TrapSig, UNITV, UnitVal, internal_name
from native_compile import compile_native

PASS = 0
FAIL = 0


def value_matches(got, expected):
    if isinstance(expected, str) and expected == "unit":
        return got is UNITV or isinstance(got, UnitVal)
    return got == expected


def native_status(expected):
    if isinstance(expected, str) and expected == "unit":
        return 0
    if isinstance(expected, bool):
        return 0 if expected else 1
    if isinstance(expected, int):
        return expected & 255
    raise AssertionError(f"native conformance cannot observe {expected!r} through process status")


def run_backend(p: Program, module, fn: str, backend: str):
    entry = internal_name(tuple(module), fn)
    if backend == "tree":
        return p.run(module, fn)
    if backend == "bytecode":
        return BCVM(BCCompiler(p.checked), p.host_modules).run(entry)
    raise AssertionError(f"unknown in-process backend {backend}")


def run_native(p: Program, module, fn: str):
    entry = internal_name(tuple(module), fn)
    with tempfile.TemporaryDirectory(prefix="l-conformance-") as td:
        out = Path(td) / "program"
        compile_native(p, entry, out, cc=os.environ.get("CC", "cc"))
        proc = subprocess.run([str(out)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        return proc.returncode, proc.stderr


def ok(name, src, expected):
    global PASS, FAIL
    try:
        module = ("test",)
        p = Program({module: src}, host_modules={})
        for backend in ("tree", "bytecode"):
            got = run_backend(p, module, "main", backend)
            if not value_matches(got, expected):
                raise AssertionError(f"{backend}: expected {expected!r}, got {got!r}")
        status, stderr = run_native(p, module, "main")
        want = native_status(expected)
        if status != want:
            raise AssertionError(f"native: expected status {want}, got {status}: {stderr.strip()}")
        print(f"PASS {name}")
        PASS += 1
    except Exception as e:
        print(f"FAIL {name}: {e}")
        FAIL += 1


def compile_error(name, src, contains=None):
    global PASS, FAIL
    try:
        Program({("test",): src}, host_modules={})
        raise AssertionError("expected compile error")
    except LangError as e:
        if contains and contains not in str(e):
            print(f"FAIL {name}: wrong error: {e}")
            FAIL += 1
        else:
            print(f"PASS {name}")
            PASS += 1
    except Exception as e:
        print(f"FAIL {name}: wrong exception {type(e).__name__}: {e}")
        FAIL += 1


def trap(name, src):
    global PASS, FAIL
    try:
        module = ("test",)
        p = Program({module: src}, host_modules={})
        for backend in ("tree", "bytecode"):
            try:
                run_backend(p, module, "main", backend)
                raise AssertionError(f"{backend}: expected trap")
            except TrapSig:
                pass
        status, stderr = run_native(p, module, "main")
        if status != 70:
            raise AssertionError(f"native: expected runtime-error status 70, got {status}: {stderr.strip()}")
        print(f"PASS {name}")
        PASS += 1
    except Exception as e:
        print(f"FAIL {name}: wrong exception {type(e).__name__}: {e}")
        FAIL += 1


def module_case(name, sources, module, fn, expected, should_error=False):
    global PASS, FAIL
    try:
        p = Program(sources, host_modules={})
        if should_error:
            raise AssertionError("expected module/link error")
        for backend in ("tree", "bytecode"):
            got = run_backend(p, module, fn, backend)
            if not value_matches(got, expected):
                raise AssertionError(f"{backend}: expected {expected!r}, got {got!r}")
        status, stderr = run_native(p, module, fn)
        want = native_status(expected)
        if status != want:
            raise AssertionError(f"native: expected status {want}, got {status}: {stderr.strip()}")
        print(f"PASS {name}")
        PASS += 1
    except LangError as e:
        if should_error:
            print(f"PASS {name}")
            PASS += 1
        else:
            print(f"FAIL {name}: {e}")
            FAIL += 1
    except Exception as e:
        print(f"FAIL {name}: {e}")
        FAIL += 1


ok("unit", "fn main() { return; }", "unit")
ok("integer wrap", "fn main() -> i8 { var x: i8 = 127; x += 1; return x; }", -128)
ok("signed min division wraps", "fn main() -> i8 { var x: i8 = -128; return x / -1; }", -128)
ok("signed arithmetic right shift", r'''
fn main() -> bool {
    var a: i8 = -2;
    var b: i16 = -32768;
    var c: i32 = -2147483648;
    var d: i64 = -9223372036854775808;
    return (a >> 1) == -1 && (b >> 8) == -128 && (c >> 31) == -1 && (d >> 63) == -1;
}
''', True)
ok("left-to-right evaluation", r'''
struct Box { value: i64, }
fn bump(b: ref Box, result: i64) -> i64 { b.value += 1; return result + b.value * 100; }
fn main() -> i64 {
    var b = new Box { value: 0 };
    var x = bump(b, 1) + bump(b, 2);
    return x;
}
''', 303)

ok("optional non-null refs and linked list", r'''
struct Node { value: i64, next: ?ref Node, }
fn prepend(head: ?ref Node, value: i64) -> ?ref Node {
    return some(new Node { value: value, next: head });
}
fn main() -> i64 {
    var head: ?ref Node = none;
    head = prepend(head, 3);
    head = prepend(head, 2);
    head = prepend(head, 1);
    var sum: i64 = 0;
    var cur = head;
    while (cur is some(node)) {
        sum += node.value;
        cur = node.next;
    }
    return sum;
}
''', 6)

ok("cyclic refs are expressible", r'''
struct Node { value: i64, next: ?ref Node, }
fn main() -> i64 {
    var n = new Node { value: 9, next: none };
    n.next = some(n);
    if (n.next is some(m)) { return m.value; }
    return 0;
}
''', 9)

ok("array aliasing", r'''
fn main() -> i64 {
    var a: []i64 = [1,2,3];
    var b = a;
    b[0] = 7;
    push(b, 4);
    return a[0] * 10 + len(a) as i64;
}
''', 74)

ok("array splice", r'''
fn main() -> i64 {
    var a: []i64 = [1,2,3,4];
    var r: []i64 = [8,9];
    splice(a, 1, 3, r);
    return a[0]*1000 + a[1]*100 + a[2]*10 + a[3];
}
''', 1894)

ok("struct copy shallow handles", r'''
struct S { x: i64, a: []i64, }
fn main() -> i64 {
    var s = S { x: 1, a: [4] };
    var t = s;
    t.x = 8;
    t.a[0] = 9;
    return s.x * 100 + s.a[0] * 10 + t.x;
}
''', 198)

ok("nested value place mutation", r'''
struct Inner { x: i64, }
struct Outer { inner: Inner, }
fn main() -> i64 {
    var xs: []Outer = [Outer { inner: Inner { x: 1 } }];
    xs[0].inner.x += 6;
    return xs[0].inner.x;
}
''', 7)

ok("fieldless enum equality", r'''
enum Kind { a, b, }
fn main() -> bool { return Kind.a != Kind.b && Kind.a == Kind.a; }
''', True)

ok("payload enum and match", r'''
enum E { empty, value(i64), pair(i64,i64), }
fn main() -> i64 {
    var e: E = E.pair(2, 5);
    match (e) {
        E.empty { return 0; }
        E.value(v) { return v; }
        E.pair(a,b) { return a * 10 + b; }
    }
}
''', 25)

ok("generic reverse", r'''
fn reverse[T](a: []T) {
    var i: u64 = 0;
    var j = len(a);
    while (i < j) {
        j -= 1;
        var t: T = a[i];
        a[i] = a[j];
        a[j] = t;
        i += 1;
    }
}
fn main() -> i64 { var a: []i64 = [1,2,3]; reverse(a); return a[0]*100+a[1]*10+a[2]; }
''', 321)

ok("generic result inferred from expected type", r'''
struct Box[T] { value: T, }
fn make[T](x: T) -> ref Box[T] { return new Box { value: x }; }
fn main() -> i64 { var b: ref Box[i64] = make(42); return b.value; }
''', 42)

ok("function value", r'''
fn twice(x: i64) -> i64 { return x * 2; }
fn apply(f: fn(i64) -> i64, x: i64) -> i64 { return f(x); }
fn main() -> i64 { return apply(twice, 6); }
''', 12)

ok("noncapturing anonymous function", r'''
fn apply(f: fn(i64) -> i64, x: i64) -> i64 { return f(x); }
fn main() -> i64 {
    var f: fn(i64) -> i64 = fn(x: i64) -> i64 { return x + 3; };
    return apply(f, 4);
}
''', 7)

ok("for in array", r'''
fn main() -> i64 { var a: []i64 = [1,2,3,4]; var s: i64 = 0; for (x in a) { s += x; } return s; }
''', 10)

ok("C-style for continue", r'''
fn main() -> i64 {
    var s: i64 = 0;
    for (var i: i64 = 0; i < 5; i += 1) {
        if (i == 2) { continue; }
        s += i;
    }
    return s;
}
''', 8)

ok("repeat evaluates element once conceptually", r'''
struct B { x: i64, }
fn main() -> i64 {
    var r = new B { x: 1 };
    var a: []ref B = [r; 3];
    a[0].x = 9;
    return a[2].x;
}
''', 9)

ok("nested loop break does not escape outer infinite loop", r'''
fn forever() -> i64 {
    while (true) {
        while (true) { break; }
    }
}
fn main() -> i64 { return 0; }
''', 0)

trap("bounds trap", "fn main() -> i64 { var a: []i64 = [1]; return a[1]; }")
trap("empty pop trap", "fn main() -> i64 { var a: []i64 = []; return pop(a); }")
trap("divide zero trap", "fn main() -> i64 { var z: i64 = 0; return 1 / z; }")
trap("bad shift trap", "fn main() -> u8 { var x: u8 = 1; var n: u64 = 8; return x << n; }")

compile_error("no null token", "fn main() { var x = null; }", "unknown")
compile_error("no implicit optional wrapping", r'''
struct N { x: i64, }
fn main() { var n = new N { x: 1 }; var o: ?ref N = n; }
''')
compile_error("direct recursive value layout rejected", "struct N { next: N, } fn main() {}", "recursive")
compile_error("optional does not break layout recursion", "struct N { next: ?N, } fn main() {}", "recursive")
compile_error("generic wrapper does not hide value recursion", r'''
struct Box[T] { value: T, }
struct N { next: Box[N], }
fn main() {}
''', "recursive")
compile_error("generic enum wrapper does not hide value recursion", r'''
enum Box[T] { value(T), }
struct N { next: Box[N], }
fn main() {}
''', "recursive")
compile_error("type-changing generic value recursion rejected", r'''
struct Grow[T] { next: Grow[[]T], }
fn main() {}
''', "recursive")
ok("generic ref indirection breaks value recursion", r'''
struct Box[T] { value: T, }
struct N { next: Box[ref N], }
fn main() -> i64 { return 0; }
''', 0)
compile_error("capturing anonymous function rejected", r'''
fn main() { var x: i64 = 3; var f: fn(i64)->i64 = fn(y:i64)->i64 { return x+y; }; }
''', "unknown")
compile_error("anonymous function cannot break enclosing loop", r'''
fn main() {
    while (true) {
        var f: fn() = fn() { break; };
        break;
    }
}
''', "break outside loop")
compile_error("anonymous function cannot continue enclosing loop", r'''
fn main() {
    while (true) {
        var f: fn() = fn() { continue; };
        break;
    }
}
''', "continue outside loop")
compile_error("expression statements restricted to calls", "fn main() { 1 + 2; }", "call")
compile_error("comparison chains rejected", "fn main() -> bool { return 1 < 2 < 3; }")
compile_error("shadowing rejected", "fn f() {} fn main() { var f: i64 = 1; }")
compile_error("type-changing generic recursion rejected", r'''
fn bad[T](x: T) { var a: []T = [x]; bad(a); }
fn main() { bad(1); }
''')

module_case("logical module + pub", {
    ("lib",): "pub fn value() -> i64 { return 11; }",
    ("app",): "import lib; fn main() -> i64 { return lib.value(); }",
}, ("app",), "main", 11)

module_case("private declaration rejected", {
    ("lib",): "fn hidden() -> i64 { return 3; }",
    ("app",): "import lib; fn main() -> i64 { return lib.hidden(); }",
}, ("app",), "main", None, should_error=True)

module_case("import cycle rejected", {
    ("a",): "import b; pub fn fa() {}",
    ("b",): "import a; pub fn fb() {}",
}, ("a",), "fa", None, should_error=True)

print(f"\nCore-only conformance seed: {PASS} passed, {FAIL} failed")
raise SystemExit(1 if FAIL else 0)
