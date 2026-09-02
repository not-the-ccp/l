#!/usr/bin/env python3
"""Focused conformance checks for shallow const arrays."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bootstrap"))

from bytecode import BCCompiler, BCVM
from core import LangError, Program, internal_name
from native_compile import compile_native

MODULE = ("const_arrays",)


def program(source: str) -> Program:
    return Program({MODULE: source}, host_modules={})


def expect_compile_error(name: str, source: str, contains: str | None = None) -> None:
    try:
        program(source)
    except LangError as error:
        if contains is not None and contains not in str(error):
            raise AssertionError(f"{name}: wrong error: {error}") from error
        return
    raise AssertionError(f"{name}: expected compile error")


def run_all(source: str, expected: int) -> None:
    checked = program(source)
    entry = internal_name(MODULE, "main")

    tree = checked.run(MODULE, "main")
    if tree != expected:
        raise AssertionError(f"tree: expected {expected}, got {tree}")

    bytecode = BCVM(BCCompiler(checked.checked), checked.host_modules).run(entry)
    if bytecode != expected:
        raise AssertionError(f"bytecode: expected {expected}, got {bytecode}")

    with tempfile.TemporaryDirectory(prefix="l-const-array-") as directory:
        output = Path(directory) / "program"
        compile_native(checked, entry, output, cc=os.environ.get("CC", "cc"))
        result = subprocess.run(
            [str(output)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        if result.returncode != (expected & 255):
            raise AssertionError(
                f"native: expected status {expected & 255}, got "
                f"{result.returncode}: {result.stderr.strip()}"
            )


run_all(
    r'''
struct Node {
    value: i64,
}

fn first[T](items: const []T) -> T {
    return items[0];
}

fn mutate_literal(bytes: []u8) -> u8 {
    bytes[0] = 'z';
    return bytes[0];
}

fn main() -> i64 {
    var mutable: []i64 = [1, 2, 3];
    var view: const []i64 = mutable;
    mutable[0] = 9;
    if (first(view) != 9) { return 1; }

    var nested: []i64 = [3];
    var outer: const [][]i64 = [nested];
    outer[0][0] = 4;
    if (nested[0] != 4) { return 2; }

    var node = new Node { value: 5 };
    var refs: const []ref Node = [node];
    refs[0].value = 7;
    if (node.value != 7) { return 3; }

    var bytes: []u8 = [0, 0, 0];
    splice(bytes, 0, 3, "abc");
    if (bytes[1] != 'b') { return 4; }
    if (len("abc") != 3) { return 5; }

    var rebound: const []i64 = [10];
    rebound = mutable;
    if (rebound[0] != 9) { return 6; }

    var mutable_literal: []u8 = "xy";
    mutable_literal[0] = 'q';
    if (mutable_literal[0] != 'q') { return 7; }
    if (mutate_literal("xy") != 'z') { return 8; }

    return 42;
}
''',
    42,
)

expect_compile_error(
    "inferred string literal mutation",
    r'''
fn main() {
    var text = "abc";
    text[0] = 'x';
}
''',
    "const []T",
)

expect_compile_error(
    "const-to-mutable conversion",
    r'''
fn main() {
    var text: const []u8 = "abc";
    var buffer: []u8 = text;
}
''',
    "type mismatch",
)

expect_compile_error(
    "const view cannot regain mutability",
    r'''
fn main() {
    var source: []i64 = [1];
    var view: const []i64 = source;
    var writable: []i64 = view;
}
''',
    "type mismatch",
)

expect_compile_error(
    "push through const handle",
    r'''
fn main() {
    var values: const []i64 = [1];
    push(values, 2);
}
''',
    "mutable []T",
)

expect_compile_error(
    "pop through const handle",
    r'''
fn main() {
    var values: const []i64 = [1];
    pop(values);
}
''',
    "mutable []T",
)

expect_compile_error(
    "splice const target",
    r'''
fn main() {
    var values: const []u8 = "abc";
    splice(values, 0, 1, "x");
}
''',
    "mutable []T",
)

expect_compile_error(
    "outer slot mutation",
    r'''
fn main() {
    var inner: []i64 = [1];
    var outer: const [][]i64 = [inner];
    outer[0] = inner;
}
''',
    "const []T",
)

expect_compile_error(
    "const inner array mutation",
    r'''
fn main() {
    var inner: const []i64 = [1];
    var outer: []const []i64 = [inner];
    outer[0][0] = 2;
}
''',
    "const []T",
)

expect_compile_error(
    "value element field mutation",
    r'''
struct Item {
    value: i64,
}

fn change(items: const []Item) {
    items[0].value = 2;
}

fn main() {}
''',
)

expect_compile_error(
    "const only qualifies arrays",
    r'''
fn bad(value: const i64) -> i64 {
    return value;
}

fn main() -> i64 {
    return bad(1);
}
''',
    "expected []",
)

expect_compile_error(
    "inferred const string cannot satisfy mutable generic parameter",
    r'''
fn mutate[T](items: []T, value: T) {
    items[0] = value;
}

fn main() {
    var text = "abc";
    mutate(text, 'x');
}
''',
)

print("const array conformance PASS")
