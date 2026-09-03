#!/usr/bin/env python3
from __future__ import annotations

import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "examples" / "hosted" / "linux_tty_job_probe.l"
SDK = ROOT / "bootstrap" / "sdk_cli.py"


def drain(fd: int, timeout: float = 0.05) -> bytes:
    out = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.01)
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
        out.extend(chunk)
    return bytes(out)


def wait_for(fd: int, needle: bytes, transcript: bytearray, timeout: float = 4.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        transcript.extend(drain(fd, 0.08))
        if needle in transcript:
            return
        time.sleep(0.005)
    raise AssertionError((needle, bytes(transcript[-4000:])))


def wait_exit(pid: int, fd: int, transcript: bytearray, timeout: float = 4.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        transcript.extend(drain(fd, 0.05))
        got, status = os.waitpid(pid, os.WNOHANG)
        if got == pid:
            code = os.waitstatus_to_exitcode(status)
            assert code == 0, (code, bytes(transcript[-4000:]))
            return
        time.sleep(0.005)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    raise AssertionError(("probe did not exit", bytes(transcript[-4000:])))


def run_case(label: str, argv: list[str]) -> None:
    pid, fd = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        os.chdir(ROOT)
        os.execve(argv[0], argv, env)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 18, 80, 0, 0))
    transcript = bytearray()
    try:
        wait_for(fd, b"READY", transcript)

        # Send the tty's normal VSUSP character. Correct behavior requires the
        # terminal driver to target the child foreground process group; the L
        # parent is blocked in wait.group and must remain alive.
        os.write(fd, b"\x1a")
        wait_for(fd, b"STOPPED", transcript)

        # The probe has reclaimed the tty, then foregrounds + SIGCONTs cat. Once
        # CONTINUED appears, VINTR must likewise target cat rather than the L
        # parent/reference runner.
        wait_for(fd, b"CONTINUED", transcript)
        os.write(fd, b"\x03")
        wait_for(fd, b"DONE", transcript)
        wait_exit(pid, fd, transcript)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            got, _ = os.waitpid(pid, os.WNOHANG)
            if got == 0:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        except ProcessLookupError:
            pass

    print(f"linux job-control PTY {label} PASS")


def main() -> None:
    if not sys.platform.startswith("linux"):
        print("linux job-control PTY SKIP")
        return

    with tempfile.TemporaryDirectory(prefix="l-job-control-") as td:
        native = Path(td) / "probe"
        subprocess.run(
            [str(ROOT / "lc"), str(PROBE), "-o", str(native)],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        run_case("reference", [sys.executable, str(SDK), "run", str(PROBE)])
        run_case("native", [str(native)])


if __name__ == "__main__":
    main()
