#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
TASKS = HERE / "tasks"
LOGGER = HERE / "vim_logger.vim"


def find_task(name: str) -> tuple[Path, Path]:
    start = TASKS / f"{name}.start.l"
    expected = TASKS / f"{name}.expected.l"
    if not start.is_file() or not expected.is_file():
        choices = sorted(p.name.removesuffix(".start.l") for p in TASKS.glob("*.start.l"))
        raise SystemExit(f"unknown task {name!r}; available: {', '.join(choices)}")
    return start, expected


def main() -> int:
    ap = argparse.ArgumentParser(description="Run one Lace keymap dogfood task in Vim")
    ap.add_argument("task")
    ap.add_argument("--vim", default=os.environ.get("VIM", "vim"))
    ap.add_argument("--clean", action="store_true", help="run without user vimrc/plugins/viminfo")
    ap.add_argument("--keep", action="store_true", help="keep the working directory")
    ap.add_argument("--log", type=Path, help="telemetry output path")
    ns = ap.parse_args()

    start, expected = find_task(ns.task)
    work_root = Path(tempfile.mkdtemp(prefix=f"lace-keymap-{ns.task}-"))
    work = work_root / start.name.replace(".start.l", ".l")
    shutil.copyfile(start, work)

    log = ns.log.resolve() if ns.log else (HERE / "logs" / f"{ns.task}.jsonl").resolve()
    log.parent.mkdir(parents=True, exist_ok=True)
    if log.exists():
        log.unlink()

    env = os.environ.copy()
    env["LACE_KEYLOG"] = str(log)
    env["LACE_KEYLOG_TASK"] = ns.task
    env.setdefault("LACE_KEYLOG_REDACT", "1")

    print(f"Task: {ns.task}")
    print(f"Edit: {work}")
    print("Finish by saving and quitting Vim. The result is checked byte-for-byte.")
    print(f"Telemetry: {log}")

    command = [ns.vim]
    if ns.clean:
        command += ["-Nu", "NONE", "-i", "NONE", "--noplugin", "-n"]
    command += ["-S", str(LOGGER), str(work)]

    rc = subprocess.call(command, env=env)
    if rc != 0:
        print(f"Vim exited with status {rc}", file=sys.stderr)
        if not ns.keep:
            shutil.rmtree(work_root, ignore_errors=True)
        return rc

    actual = work.read_bytes()
    wanted = expected.read_bytes()
    ok = actual == wanted
    print("PASS" if ok else "FAIL: final file does not match expected output")
    if not ok:
        print(f"Expected: {expected}")
        print(f"Actual:   {work}")

    if ns.keep or not ok:
        print(f"Working directory kept at {work_root}")
    else:
        shutil.rmtree(work_root, ignore_errors=True)

    print(f"Analyze with: python3 {HERE / 'analyze.py'} {log}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
