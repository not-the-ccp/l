#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import os
import pickle
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from core import Program, Parser, LangError, TrapSig, UnitVal, UNITV, internal_name
from bytecode import BCCompiler, BCVM
from run_lang import (
    REPO, PORTABLE_LIB, HOSTED_LIB,
    stdio_host,
    fs_host,
    sys_host,
    ProcessHost,
    TermHost,
)

IS_LINUX = sys.platform.startswith("linux")
if IS_LINUX:
    from linux_host import LinuxHost

ARTIFACT_MAGIC = "LBC1"


def stdlib_sources() -> dict[tuple[str, ...], str]:
    out: dict[tuple[str, ...], str] = {}
    for base in (PORTABLE_LIB, HOSTED_LIB):
        for p in sorted(base.glob("*.l")):
            out[(p.stem,)] = p.read_text(encoding="utf-8")
    return out


HOST_MODULES = {
    ("stdio",),
    ("fs",),
    ("sys",),
    ("proc",),
    ("term",),
}
if IS_LINUX:
    HOST_MODULES |= {
        ("linux", "fd"),
        ("linux", "process"),
    }


def module_name(root: Path, path: Path) -> tuple[str, ...]:
    rel = path.resolve().relative_to(root.resolve())
    return tuple(rel.with_suffix("").parts)


def project_sources(entry: Path, root: Path) -> tuple[dict[tuple[str, ...], str], tuple[str, ...]]:
    entry = entry.resolve()
    root = root.resolve()
    if not entry.is_file():
        raise SystemExit(f"no such source file: {entry}")
    try:
        entry.relative_to(root)
    except ValueError:
        raise SystemExit(f"entry file {entry} is outside project root {root}")

    stdlib = stdlib_sources()
    sources: dict[tuple[str, ...], str] = {}
    origins: dict[tuple[str, ...], Path | None] = {}
    visiting: set[tuple[str, ...]] = set()

    entry_mod = module_name(root, entry)

    def load(mod: tuple[str, ...], forced_path: Path | None = None):
        if mod in sources or mod in visiting or mod in HOST_MODULES:
            return
        visiting.add(mod)
        if forced_path is not None:
            path = forced_path
            text = path.read_text(encoding="utf-8")
            origin = path
        elif mod in stdlib:
            text = stdlib[mod]
            origin = None
        else:
            path = root.joinpath(*mod).with_suffix(".l")
            if not path.is_file():
                raise LangError(f"unresolved module {'.'.join(mod)} (looked for {path})")
            text = path.read_text(encoding="utf-8")
            origin = path
        sources[mod] = text
        origins[mod] = origin
        try:
            ast = Parser(text).program()
        except LangError as e:
            if origin is not None:
                e.path = origin
            raise
        for d in ast.a[0]:
            if d.kind == "import":
                q, _alias = d.a
                load(tuple(q))
        visiting.remove(mod)

    load(entry_mod, entry)
    return sources, entry_mod


def make_hosts_full(argv: list[str]):
    ph = ProcessHost()
    th = TermHost()
    hosts = {
        ("stdio",): stdio_host(),
        ("fs",): fs_host(),
        ("sys",): sys_host(argv),
        ("proc",): ph.module(),
        ("term",): th.module(),
    }
    lh = None
    if IS_LINUX:
        lh = LinuxHost()
        hosts.update(lh.modules())
    return hosts, ph, th, lh


def make_hosts(argv: list[str]):
    """Compatibility surface for tooling that only needs host type information.

    Existing callers intentionally retain the historical three-value return.
    Code that executes platform-owned Linux resources uses make_hosts_full() so
    those resources have an explicit cleanup owner.
    """
    hosts, ph, th, _lh = make_hosts_full(argv)
    return hosts, ph, th


def cleanup(ph: ProcessHost, th: TermHost, lh=None):
    try:
        th.leave()
    finally:
        try:
            ph.cleanup()
        finally:
            if lh is not None:
                lh.cleanup()


def build_program(entry: Path, root: Path, argv: list[str]):
    sources, mod = project_sources(entry, root)
    hosts, ph, th, lh = make_hosts_full(argv)
    try:
        p = Program(sources, hosts)
        if "main" not in p.tops.get(mod, {}):
            raise LangError(f"entry module {'.'.join(mod)} has no main function")
        return p, mod, hosts, ph, th, lh
    except Exception:
        cleanup(ph, th, lh)
        raise


def printable_result(v):
    if v is UNITV or isinstance(v, UnitVal):
        return "()"
    return repr(v)


def exit_status(v) -> int:
    if v is UNITV or isinstance(v, UnitVal):
        return 0
    if isinstance(v, bool):
        return 0 if v else 1
    if isinstance(v, int):
        return v & 0xFF
    return 0


def cmd_check(ns) -> int:
    entry = Path(ns.file)
    root = Path(ns.root) if ns.root else entry.resolve().parent
    p, mod, hosts, ph, th, lh = build_program(entry, root, [])
    try:
        print(f"OK: {entry} ({'.'.join(mod)})")
        return 0
    finally:
        cleanup(ph, th, lh)


def cmd_run(ns) -> int:
    entry = Path(ns.file)
    root = Path(ns.root) if ns.root else entry.resolve().parent
    p, mod, hosts, ph, th, lh = build_program(entry, root, ns.args)
    try:
        entry_name = internal_name(mod, "main")
        if ns.ast:
            result = p.interpreter().run(entry_name)
        else:
            result = BCVM(BCCompiler(p.checked), hosts).run(entry_name)
        if ns.print_result:
            print(printable_result(result))
        return exit_status(result)
    finally:
        cleanup(ph, th, lh)


def serializable_bc(p: Program) -> BCCompiler:
    bc = BCCompiler(p.checked)
    # Host modules contain Python callables. Bytecode references hosts symbolically,
    # so the artifact does not need those callables; the runner reconstructs them.
    bc.c.host_modules = {}
    bc.c.import_modules = {}
    return bc


def cmd_compile(ns) -> int:
    entry = Path(ns.file)
    root = Path(ns.root) if ns.root else entry.resolve().parent
    p, mod, hosts, ph, th, lh = build_program(entry, root, [])
    try:
        bc = serializable_bc(p)
        out = Path(ns.output) if ns.output else entry.with_suffix(".lbc")
        payload = {
            "magic": ARTIFACT_MAGIC,
            "entry": internal_name(mod, "main"),
            "entry_module": mod,
            "bytecode": bc,
        }
        out.write_bytes(pickle.dumps(payload, protocol=5))
        print(out)
        return 0
    finally:
        cleanup(ph, th, lh)


def cmd_exec(ns) -> int:
    path = Path(ns.file)
    payload = pickle.loads(path.read_bytes())
    if not isinstance(payload, dict) or payload.get("magic") != ARTIFACT_MAGIC:
        raise SystemExit("not an LBC1 bytecode artifact")
    hosts, ph, th, lh = make_hosts_full(ns.args)
    try:
        result = BCVM(payload["bytecode"], hosts).run(payload["entry"])
        if ns.print_result:
            print(printable_result(result))
        return exit_status(result)
    finally:
        cleanup(ph, th, lh)


def cmd_edit(ns) -> int:
    path = Path(ns.file)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"")
    server = ns.lsp
    if server == "auto":
        ext = path.suffix.lower()
        server = "json-lsp" if ext == ".json" else "ini-lsp" if ext in {".ini", ".cfg"} else "slang-lsp"
    elif server in {"l", "slang"}:
        server = "slang-lsp"
    elif server == "json":
        server = "json-lsp"
    elif server == "ini":
        server = "ini-lsp"
    cmd = [sys.executable, str(HERE / "run_lang.py"), "editor-vm", str(path), server]
    return subprocess.call(cmd)


def cmd_lsp(ns) -> int:
    name = {"l": "slang-lsp", "slang": "slang-lsp", "json": "json-lsp", "ini": "ini-lsp"}[ns.kind]
    os.execv(sys.executable, [sys.executable, str(HERE / "run_lang.py"), name + "-vm"])
    return 127


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="l", description="Small L language SDK")
    sub = p.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("edit", help="open the custom modal editor + LSP")
    q.add_argument("file")
    q.add_argument("--lsp", default="auto", choices=["auto", "l", "slang", "json", "ini"])
    q.set_defaults(func=cmd_edit)

    q = sub.add_parser("check", help="parse, link, and type-check an L program")
    q.add_argument("file")
    q.add_argument("--root", help="project root; defaults to the entry file's directory")
    q.set_defaults(func=cmd_check)

    q = sub.add_parser("run", help="compile in memory and run an L program")
    q.add_argument("file")
    q.add_argument("--root", help="project root; defaults to the entry file's directory")
    q.add_argument("--ast", action="store_true", help="use tree interpreter instead of bytecode VM")
    q.add_argument("--print-result", action="store_true")
    q.add_argument("args", nargs=argparse.REMAINDER, help="arguments exposed by sys.args()")
    q.set_defaults(func=cmd_run)

    q = sub.add_parser("compile", help="compile an L project to an LBC bytecode artifact")
    q.add_argument("file")
    q.add_argument("-o", "--output")
    q.add_argument("--root", help="project root; defaults to the entry file's directory")
    q.set_defaults(func=cmd_compile)

    q = sub.add_parser("exec", help="run a compiled .lbc artifact")
    q.add_argument("file")
    q.add_argument("--print-result", action="store_true")
    q.add_argument("args", nargs=argparse.REMAINDER, help="arguments exposed by sys.args()")
    q.set_defaults(func=cmd_exec)

    q = sub.add_parser("lsp", help="run one of the L-written LSP servers on stdio")
    q.add_argument("kind", choices=["l", "slang", "json", "ini"])
    q.set_defaults(func=cmd_lsp)
    return p


def main() -> int:
    ns = parser().parse_args()
    try:
        return ns.func(ns)
    except LangError as e:
        print(f"compile error: {e}", file=sys.stderr)
        return 1
    except TrapSig as e:
        print(f"trap: {e}", file=sys.stderr)
        return 134


if __name__ == "__main__":
    raise SystemExit(main())
