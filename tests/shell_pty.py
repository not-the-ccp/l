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
LSH = ROOT / "build" / "lsh"
CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")


def strip_control(data: bytes) -> bytes:
    return CSI.sub(b"", data).replace(b"\r", b"")


def drain(fd: int, idle: float = 0.02, timeout: float = 2.0) -> bytes:
    out = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
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


def wait_text(fd: int, needle: bytes, timeout: float = 3.0) -> bytes:
    out = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        out += drain(fd, idle=0.005, timeout=0.05)
        if needle in strip_control(out):
            return out
        time.sleep(0.005)
    raise AssertionError((needle, strip_control(out[-4000:])))


def wait_exit(pid: int, fd: int, expected: int = 0, timeout: float = 4.0) -> bytes:
    out = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        out += drain(fd, idle=0.005, timeout=0.03)
        got, status = os.waitpid(pid, os.WNOHANG)
        if got == pid:
            code = os.waitstatus_to_exitcode(status)
            assert code == expected, (code, expected, strip_control(out[-4000:]))
            out += drain(fd, idle=0.005, timeout=0.05)
            return out
        time.sleep(0.005)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    raise RuntimeError("lsh failed to exit")


def spawn(home: Path, rows: int = 18, cols: int = 80) -> tuple[int, int, bytes]:
    pid, fd = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env["HOME"] = str(home)
        os.chdir(home)
        os.execve(str(LSH), [str(LSH)], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    transcript = wait_text(fd, b"~ ", timeout=3)
    return pid, fd, transcript


def send(fd: int, data: bytes, settle: float = 0.20) -> bytes:
    os.write(fd, data)
    time.sleep(settle)
    return drain(fd, timeout=0.6)


def run() -> None:
    assert LSH.is_file(), "build/lsh was not built"
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        pid, fd, transcript = spawn(home)

        assert b"\x1b[?2004h" in transcript, transcript[-2000:]
        assert b"\x1b[?1049h" not in transcript, "a shell must not use the alternate screen"

        # Stateful builtin mutations persist in the shell process.
        transcript += send(fd, b"env set LSH_PTY_TEST value\r")
        chunk = send(fd, b"env get LSH_PTY_TEST\r")
        transcript += chunk
        assert b"value" in strip_control(chunk), strip_control(chunk[-3000:])

        # Up recalls the previous command, and Ctrl-C cancels the edit rather
        # than allowing the terminal driver to kill the shell in raw mode.
        chunk = send(fd, b"\x1b[A")
        transcript += chunk
        assert b"env get LSH_PTY_TEST" in strip_control(chunk), strip_control(chunk[-3000:])
        chunk = send(fd, b"\x03")
        transcript += chunk
        assert b"^C" in strip_control(chunk), strip_control(chunk[-3000:])

        # Parser-driven continuation is visible and remains editable.
        chunk = send(fd, b"env get HOME |\r")
        transcript += chunk
        assert "… ".encode() in strip_control(chunk), strip_control(chunk[-3000:])
        transcript += send(fd, b"\x03")

        # Bracketed paste is literal data. An escape sequence inside the pasted
        # value may be stored/retrieved, but must never become terminal protocol
        # when echoed as editable text or builtin output.
        hostile = b"\x1b[2J"
        before_hostile = len(transcript)
        transcript += send(fd, b"\x1b[200~env set PASTE " + hostile + b"\x1b[201~")
        transcript += send(fd, b"\r")
        chunk = send(fd, b"env get PASTE\r")
        transcript += chunk
        hostile_transcript = transcript[before_hostile:]
        assert hostile not in hostile_transcript, hostile_transcript[-4000:]
        assert b"^[[2J" in strip_control(chunk), strip_control(chunk[-3000:])

        # External foreground execution is deliberately gated until process-
        # group/tty handoff lands; the failure should be explicit, not flaky.
        chunk = send(fd, b"true\r")
        transcript += chunk
        assert b"foreground job control" in strip_control(chunk), strip_control(chunk[-3000:])

        # Resize while editing a wrapping line. Poll-driven repaint should keep
        # the shell alive and produce another frame without waiting for a key.
        transcript += send(fd, b"env set RESIZE abcdefghijklmnopqrstuvwxyz")
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 22, 0, 0))
        time.sleep(0.35)
        resized = drain(fd, timeout=0.6)
        transcript += resized
        assert resized, "resize did not trigger repaint"
        transcript += send(fd, b"\x03")

        # Return to status zero, then Ctrl-D on an empty buffer exits cleanly.
        transcript += send(fd, b"env get HOME\r")
        os.write(fd, b"\x04")
        transcript += wait_exit(pid, fd, expected=0)
        os.close(fd)

        assert b"\x1b[?2004l" in transcript, "bracketed paste was not disabled on exit"
        assert b"\x1b[?1049h" not in transcript

    print("native lsh PTY dogfood PASS")


if __name__ == "__main__":
    run()
