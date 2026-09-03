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


def wait_exit(pid: int, fd: int, timeout: float = 5.0) -> bytes:
    transcript = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        transcript += drain(fd, idle=0.005, timeout=0.03)
        got, status = os.waitpid(pid, os.WNOHANG)
        if got == pid:
            assert os.waitstatus_to_exitcode(status) == 0, status
            transcript += drain(fd, idle=0.005, timeout=0.05)
            return transcript
        time.sleep(0.005)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    raise RuntimeError("rewritten Lace failed to quit")


def spawn(path: Path) -> tuple[int, int, bytes]:
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(str(LACE), [str(LACE), str(path)])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 90, 0, 0))
    return pid, fd, drain(fd, timeout=3)


def edit(path: Path, keys: bytes) -> bytes:
    pid, fd, transcript = spawn(path)
    os.write(fd, keys)
    transcript += wait_exit(pid, fd)
    os.close(fd)
    return transcript


def run() -> None:
    assert LACE.is_file(), "build/lace was not built"
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        path = root / "bytes.bin"
        path.write_bytes(b"alpha\n")

        pid, fd, transcript = spawn(path)
        assert b"\x1b[?1049h" in transcript
        os.write(fd, b"A!\x16xFF\x1b:wq\r")
        transcript += wait_exit(pid, fd)
        os.close(fd)
        assert b"\x1b[?1049l" in transcript
        assert path.read_bytes() == b"alpha!\xff\n", path.read_bytes()

        pid, fd, transcript = spawn(path)
        assert b"<FF>" in transcript, transcript[-1000:]
        os.write(fd, b"$hx:wq\r")
        transcript += wait_exit(pid, fd)
        os.close(fd)
        assert path.read_bytes() == b"alpha!\n", path.read_bytes()

        unicode_path = root / "unicode.txt"
        unicode_path.write_bytes(b"x\n")
        edit(unicode_path, "A λ€\x1b:wq\r".encode("utf-8").replace(b"\\x1b", b"\x1b").replace(b"\\r", b"\r"))
        assert unicode_path.read_bytes() == "x λ€\n".encode("utf-8")

        arrow = root / "arrow.txt"
        arrow.write_bytes(b"ab\n")
        edit(arrow, b"A\x1b[DX\x1b:wq\r")
        assert arrow.read_bytes() == b"aXb\n", arrow.read_bytes()

        changed = root / "change-line.txt"
        changed.write_bytes(b"    alpha\nbeta\n")
        edit(changed, b"ccgamma\x1b:wq\r")
        assert changed.read_bytes() == b"    gamma\nbeta\n", changed.read_bytes()

        put = root / "linewise-put.txt"
        put.write_bytes(b"one\ntwo")
        edit(put, b"yyGp:wq\r")
        assert put.read_bytes() == b"one\ntwo\none\n", put.read_bytes()

        hostile = root / "hostile.bin"
        hostile.write_bytes(b"A\x1b[2JB\n")
        pid, fd, transcript = spawn(hostile)
        assert b"^[" in transcript
        assert b"\x1b[2J" not in transcript
        os.write(fd, b":q\r")
        transcript += wait_exit(pid, fd)
        os.close(fd)
        assert hostile.read_bytes() == b"A\x1b[2JB\n"

        created = root / "new-file.txt"
        edit(created, b"ihello\x1b:wq\r")
        assert created.read_bytes() == b"hello"

    print("default Lace native PTY dogfood PASS")


if __name__ == "__main__":
    run()
