#!/usr/bin/env python3
from __future__ import annotations

import fcntl
import os
import pty
import select
import signal
import struct
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LACE = ROOT / "build" / "lace"


def drain(fd: int, idle: float = 0.02, timeout: float = 3.0) -> bytes:
    out = b""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], idle)
        if not ready:
            if out:
                break
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out


def spawn(path: Path) -> tuple[int, int]:
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(str(LACE), [str(LACE), str(path)])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 60, 0, 0))
    drain(fd, timeout=2)
    return pid, fd


def edit(path: Path, keys: bytes, timeout: float = 5.0) -> None:
    pid, fd = spawn(path)
    os.write(fd, keys)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        drain(fd, idle=0.005, timeout=0.03)
        got, status = os.waitpid(pid, os.WNOHANG)
        if got == pid:
            os.close(fd)
            assert os.waitstatus_to_exitcode(status) == 0, status
            return
        time.sleep(0.005)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    os.close(fd)
    raise RuntimeError(f"Lace hung for operator input {keys!r}")


def case(root: Path, name: str, initial: bytes, keys: bytes, expected: bytes) -> None:
    path = root / name
    path.write_bytes(initial)
    edit(path, keys + b":wq\r")
    actual = path.read_bytes()
    assert actual == expected, (name, actual, expected)


def run() -> None:
    assert LACE.is_file(), "build/lace was not built"
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)

        # `cw` is the established special case: on a word it behaves like `ce`
        # and leaves the following separator. On whitespace it remains `cw`.
        case(root, "cw-word.txt", b"one two\n", b"cwX\x1b", b"X two\n")
        case(root, "cw-space.txt", b"  one two\n", b"cwX\x1b", b"Xone two\n")
        case(root, "c2w.txt", b"one two three\n", b"c2wX\x1b", b"X three\n")

        # Counts before and after an operator compose multiplicatively.
        case(root, "2dw.txt", b"one two three four\n", b"2dw", b"three four\n")
        case(root, "d2w.txt", b"one two three four\n", b"d2w", b"three four\n")
        case(
            root,
            "2d3w.txt",
            b"one two three four five six seven\n",
            b"2d3w",
            b"seven\n",
        )

        # Doubled operators use the composed count as a line count.
        case(root, "2dd.txt", b"1\n2\n3\n4\n", b"2dd", b"3\n4\n")
        case(root, "d2d.txt", b"1\n2\n3\n4\n", b"d2d", b"3\n4\n")
        case(root, "2d2d.txt", b"1\n2\n3\n4\n5\n6\n", b"2d2d", b"5\n6\n")

        # Counted yanks use the same range grammar.
        case(root, "2yyp.txt", b"1\n2\n3\n4\n", b"2yyp", b"1\n1\n2\n2\n3\n4\n")

        # Counted line changes collapse the requested lines into one insertion
        # line rather than changing only the first line.
        case(root, "2cc.txt", b"  one\n  two\nthree\n", b"2ccX\x1b", b"  X\nthree\n")

        # Count parsing saturates and motions stop when no progress is possible;
        # absurd user input must not turn into a multi-billion-iteration hang.
        huge = root / "huge-count.txt"
        huge.write_bytes(b"one two\n")
        edit(huge, b"999999999999999999999999999999999999w:q\r", timeout=2.0)
        assert huge.read_bytes() == b"one two\n"

    print("Lace operator PTY regressions PASS")


if __name__ == "__main__":
    run()
