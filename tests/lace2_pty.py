#!/usr/bin/env python3
from __future__ import annotations

import fcntl
import os
import pty
import re
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


def spawn(path: Path, rows: int = 24, cols: int = 90) -> tuple[int, int, bytes]:
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(str(LACE), [str(LACE), str(path)])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    return pid, fd, drain(fd, timeout=3)


def edit(path: Path, keys: bytes) -> bytes:
    pid, fd, transcript = spawn(path)
    os.write(fd, keys)
    transcript += wait_exit(pid, fd)
    os.close(fd)
    return transcript


def last_cursor(transcript: bytes) -> tuple[int, int]:
    matches = re.findall(rb"\x1b\[(\d+);(\d+)H", transcript)
    assert matches, transcript[-1000:]
    row, col = matches[-1]
    return int(row), int(col)


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
        os.write(fd, b"$x:wq\r")
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

        # Command-mode cursor positions are characters, not invisible line
        # terminator insertion boundaries. The first development release let
        # both `l` and `$` walk one cell past the final character.
        edges = root / "cursor-edges.txt"
        edges.write_bytes(b"abc\nxy\n")
        pid, fd, transcript = spawn(edges, rows=10, cols=40)
        os.write(fd, b"lll")
        moved = drain(fd, timeout=.4)
        assert last_cursor(moved) == (1, 9), moved[-1500:]
        os.write(fd, b"j")
        moved = drain(fd, timeout=.4)
        assert last_cursor(moved) == (2, 8), moved[-1500:]
        # A final terminating newline must not create a third phantom line.
        os.write(fd, b"j")
        moved = drain(fd, timeout=.4)
        assert last_cursor(moved) == (2, 8), moved[-1500:]
        os.write(fd, b":q\r")
        transcript += wait_exit(pid, fd)
        os.close(fd)

        # `$` addresses the final visible atom, so destructive commands work
        # there rather than silently operating on the newline separator.
        dollar_delete = root / "dollar-delete.txt"
        dollar_delete.write_bytes(b"abc\n")
        edit(dollar_delete, b"$x:wq\r")
        assert dollar_delete.read_bytes() == b"ab\n", dollar_delete.read_bytes()

        # Characterwise visual `$` ends on the final character, not the line
        # separator. Deleting the selection therefore preserves the newline.
        visual_dollar = root / "visual-dollar.txt"
        visual_dollar.write_bytes(b"abcd\n")
        edit(visual_dollar, b"v$d:wq\r")
        assert visual_dollar.read_bytes() == b"\n", visual_dollar.read_bytes()

        # Redo must restore the Normal-mode cursor snapshot after Escape, not
        # the one-past-EOL insertion boundary that existed before Escape.
        redo_cursor = root / "redo-cursor.txt"
        redo_cursor.write_bytes(b"abc\n")
        pid, fd, transcript = spawn(redo_cursor, rows=10, cols=40)
        os.write(fd, b"A!\x1bu\x12")
        redrawn = drain(fd, timeout=.6)
        assert last_cursor(redrawn) == (1, 10), redrawn[-1500:]
        os.write(fd, b":q!\r")
        transcript += wait_exit(pid, fd)
        os.close(fd)

        # `G` is Lace's document-end motion. A terminating newline must not
        # make it target the non-character EOF insertion boundary.
        document_end = root / "document-end.txt"
        document_end.write_bytes(b"one\ntwo\n")
        edit(document_end, b"Gx:wq\r")
        assert document_end.read_bytes() == b"one\ntw\n", document_end.read_bytes()

        last_line_delete = root / "last-line-delete.txt"
        last_line_delete.write_bytes(b"one\ntwo\n")
        edit(last_line_delete, b"Gdd:wq\r")
        assert last_line_delete.read_bytes() == b"one\n", last_line_delete.read_bytes()

        # Status and message rows are single terminal rows. Long paths/help
        # strings must be clipped instead of wrapping back into the buffer.
        long_name = root / ("very-long-lace-path-" + "x" * 40 + ".txt")
        long_name.write_bytes(b"x\n")
        pid, fd, transcript = spawn(long_name, rows=8, cols=18)
        assert os.fsencode(str(long_name)) not in transcript, transcript[-2000:]
        os.write(fd, b":help\r")
        help_frame = drain(fd, timeout=.5)
        full_help = b"i/a/o edit \xc2\xb7 hjkl/arrows/wbe move \xc2\xb7 d/y/c ops \xc2\xb7 v/V select \xc2\xb7 / search \xc2\xb7 :w :q \xc2\xb7 ^VxFF raw byte"
        assert full_help not in help_frame, help_frame[-2000:]
        os.write(fd, b":q\r")
        transcript += wait_exit(pid, fd)
        os.close(fd)

    print("default Lace native PTY dogfood PASS")


if __name__ == "__main__":
    run()
