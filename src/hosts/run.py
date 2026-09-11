#!/usr/bin/env python3
"""Direct host runner: execute L programs and LSP servers without the SDK wrapper.

Builds host sets over stdio, filesystem, processes, and terminals, then
runs checked programs through the tree interpreter or the bytecode VM.
Also hosts the editor-VM and language-server entry points.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import termios
import tty
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lang.bytecode import BCVM, BCCompiler
from lang import *
from lang.term_keys import KeyReader

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CORE_LIB = REPO / "lib" / "core"
SLANG_LIB = REPO / "lib" / "slang"
HOST_LIB = REPO / "lib" / "host"
TOOLS = REPO / "tools"
COMMON = {
    ("arrays",): CORE_LIB / "arrays.l",
    ("bytes",): CORE_LIB / "bytes.l",
    ("strconv",): CORE_LIB / "strconv.l",
    ("utf8",): CORE_LIB / "utf8.l",
    ("json",): CORE_LIB / "json.l",
    ("lsp",): CORE_LIB / "lsp.l",
    ("slang_syntax",): SLANG_LIB / "syntax.l",
    ("slang_decls",): SLANG_LIB / "decls.l",
    ("slang_types",): SLANG_LIB / "types.l",
    ("slang_check",): SLANG_LIB / "check.l",
    ("slang_names",): SLANG_LIB / "names.l",
    ("slang_index",): SLANG_LIB / "index.l",
    ("slang_project",): SLANG_LIB / "project.l",
    ("server",): TOOLS / "lsp/server.l",
    ("slang",): TOOLS / "lsp/slang.l",
    ("json_server_impl",): TOOLS / "lsp/json_server_impl.l",
    ("ini_server_impl",): TOOLS / "lsp/ini_server_impl.l",
}
SERVER_FILES = {
    "slang-lsp": TOOLS / "lsp/slang_server.l",
    "json-lsp": TOOLS / "lsp/json_server.l",
    "ini-lsp": TOOLS / "lsp/ini_server.l",
}


def array_bytes(data: bytes):
    """Wrap Python bytes as an L byte array."""
    return ArrayObj(data)


def to_bytes(v):
    """Unwrap an L byte array to Python bytes."""
    return bytes(v.items)


def array_strings(xs):
    """Wrap a string list as an L string array."""
    return ArrayObj(
        [array_bytes(os.fsencode(x) if isinstance(x, str) else x) for x in xs]
    )


def stdio_host():
    """Build the stdio host module over OS descriptors 0 and 1."""
    h = HostModule(("stdio",))

    def rd(n):
        """Rd (stdio_host helper for the L direct host runner)."""
        b = os.read(0, max(1, min(int(n), 1 << 20)))
        return None if not b else SomeVal(array_bytes(b))

    def wr(a):
        """Wr (stdio_host helper for the L direct host runner)."""
        data = to_bytes(a)
        off = 0
        while off < len(data):
            off += os.write(1, data[off:])
        return UNITV

    h.function("read", [name_ty("u64")], opt(arr(name_ty("u8"))), rd)
    h.function("write", [const_arr(name_ty("u8"))], UNIT, wr)
    return h


class ProcessHost:
    """Owned child-process host backing the proc module."""
    def __init__(self):
        """Init (ProcessHost helper for the L direct host runner)."""
        self.ps = []

    def module(self):
        """Module (ProcessHost helper for the L direct host runner)."""
        h = HostModule(("proc",))
        pt = h.opaque_type("Process")

        def spawn(argv):
            """Spawn (module helper for the L direct host runner)."""
            args = [os.fsdecode(bytes(x.items)) for x in argv.items]
            if not args:
                raise TrapSig("proc.spawn requires nonempty argv")
            p = subprocess.Popen(
                args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
                start_new_session=True,
            )
            self.ps.append(p)
            return OpaqueVal(("proc", "Process"), p)

        def write(pv, data):
            """Write (module helper for the L direct host runner)."""
            p = pv.payload
            b = to_bytes(data)
            if p.stdin is None:
                raise TrapSig("process stdin closed")
            p.stdin.write(b)
            p.stdin.flush()
            return UNITV

        def read(pv, n):
            """Read (module helper for the L direct host runner)."""
            p = pv.payload
            if p.stdout is None:
                return None
            b = os.read(p.stdout.fileno(), max(1, min(int(n), 1 << 20)))
            return None if not b else SomeVal(array_bytes(b))

        def close(pv):
            """Close (module helper for the L direct host runner)."""
            self.close_one(pv.payload)
            return UNITV

        h.function("spawn", [arr(arr(name_ty("u8")))], pt, spawn)
        h.function("write", [pt, const_arr(name_ty("u8"))], UNIT, write)
        h.function("read", [pt, name_ty("u64")], opt(arr(name_ty("u8"))), read)

        def read_timeout(pv, n, ms):
            """Read timeout (module helper for the L direct host runner)."""
            import select

            p = pv.payload
            if p.stdout is None:
                return None
            r, _, _ = select.select([p.stdout], [], [], max(0, int(ms)) / 1000.0)
            if not r:
                return None
            b = os.read(p.stdout.fileno(), max(1, min(int(n), 1 << 20)))
            return None if not b else SomeVal(array_bytes(b))

        h.function(
            "read_timeout",
            [pt, name_ty("u64"), name_ty("u64")],
            opt(arr(name_ty("u8"))),
            read_timeout,
        )

        def shell(command):
            """Shell (module helper for the L direct host runner)."""
            cmd = os.fsdecode(to_bytes(command))
            return int(subprocess.call(cmd, shell=True, executable="/bin/sh"))

        h.function("close", [pt], UNIT, close)
        h.function("shell", [const_arr(name_ty("u8"))], name_ty("i64"), shell)

        def write_try(pv, data):
            """Write try (module helper for the L direct host runner)."""
            p = pv.payload
            b = to_bytes(data)
            if p.stdin is None:
                return False
            try:
                p.stdin.write(b)
                p.stdin.flush()
                return True
            except (BrokenPipeError, OSError):
                return False

        h.function(
            "write_try", [pt, const_arr(name_ty("u8"))], name_ty("bool"), write_try
        )
        h.function("alive", [pt], name_ty("bool"), lambda pv: pv.payload.poll() is None)
        return h

    def close_one(self, p):
        """Close one (ProcessHost helper for the L direct host runner)."""
        if p.poll() is not None:
            return
        try:
            if p.stdin:
                p.stdin.close()
            p.wait(timeout=2)
        except Exception:
            try:
                p.terminate()
                p.wait(timeout=1)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass

    def cleanup(self):
        """Cleanup (ProcessHost helper for the L direct host runner)."""
        for p in self.ps:
            self.close_one(p)


class TermHost:
    """Terminal host backing raw mode, key reads, and screen control."""
    def __init__(self):
        """Init (TermHost helper for the L direct host runner)."""
        self.saved = None
        self.keys = KeyReader(0)

    def module(self):
        """Module (TermHost helper for the L direct host runner)."""
        h = HostModule(("term",))
        h.function("enter_raw", [], UNIT, self.enter)
        h.function("leave_raw", [], UNIT, self.leave)
        h.function("enter_ui", [], UNIT, self.enter_ui)
        h.function("leave_ui", [], UNIT, self.leave_ui)
        h.function("read_key", [], opt(arr(name_ty("u8"))), self.read_key)
        h.function(
            "read_key_timeout",
            [name_ty("u64")],
            opt(arr(name_ty("u8"))),
            self.read_key_timeout,
        )
        h.function("write", [const_arr(name_ty("u8"))], UNIT, self.write)
        h.function(
            "rows", [], name_ty("u64"), lambda: shutil.get_terminal_size((80, 24)).lines
        )
        h.function(
            "cols",
            [],
            name_ty("u64"),
            lambda: shutil.get_terminal_size((80, 24)).columns,
        )

        def text_width(value):
            """Text width (module helper for the L direct host runner)."""
            import unicodedata

            text = to_bytes(value).decode("utf-8", "replace")
            total = 0
            i = 0
            join = False
            regional = False
            while i < len(text):
                cp = ord(text[i])
                ch = text[i]
                i += 1
                if cp == 0x200D:
                    join = True
                    continue
                if (
                    unicodedata.combining(ch)
                    or 0xFE00 <= cp <= 0xFE0F
                    or 0x1F3FB <= cp <= 0x1F3FF
                ):
                    continue
                if 0x1F1E6 <= cp <= 0x1F1FF:
                    if regional:
                        regional = False
                        continue
                    total += 2
                    regional = True
                    continue
                regional = False
                w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
                if join:
                    join = False
                    continue
                total += w
            return total

        h.function("text_width", [const_arr(name_ty("u8"))], name_ty("u64"), text_width)
        return h

    def enter(self):
        """Enter (TermHost helper for the L direct host runner)."""
        if os.isatty(0) and self.saved is None:
            self.saved = termios.tcgetattr(0)
            tty.setraw(0)
        return UNITV

    def leave(self):
        """Leave (TermHost helper for the L direct host runner)."""
        if self.saved is not None:
            termios.tcsetattr(0, termios.TCSADRAIN, self.saved)
            self.saved = None
        return UNITV

    def enter_ui(self):
        """Enter ui (TermHost helper for the L direct host runner)."""
        self.enter()
        self.write(array_bytes(b"\x1b[?1049h\x1b[?25h"))
        return UNITV

    def leave_ui(self):
        """Leave ui (TermHost helper for the L direct host runner)."""
        self.write(array_bytes(b"\x1b[0m\x1b[?25h\x1b[?1049l"))
        self.leave()
        return UNITV

    def read_key(self):
        """Read key (TermHost helper for the L direct host runner)."""
        b = self.keys.read()
        return None if b is None else SomeVal(array_bytes(b))

    def read_key_timeout(self, ms):
        """Read key timeout (TermHost helper for the L direct host runner)."""
        b = self.keys.read(int(ms))
        return None if b is None else SomeVal(array_bytes(b))

    def write(self, a):
        """Write (TermHost helper for the L direct host runner)."""
        b = to_bytes(a)
        off = 0
        while off < len(b):
            off += os.write(1, b[off:])
        return UNITV


def fs_host():
    """Build the filesystem host module."""
    h = HostModule(("fs",))

    def rd(path):
        """Rd (fs_host helper for the L direct host runner)."""
        try:
            return SomeVal(array_bytes(Path(os.fsdecode(to_bytes(path))).read_bytes()))
        except FileNotFoundError:
            return None

    def wr(path, data):
        """Wr (fs_host helper for the L direct host runner)."""
        try:
            Path(os.fsdecode(to_bytes(path))).write_bytes(to_bytes(data))
            return True
        except OSError:
            return False

    h.function("read", [const_arr(name_ty("u8"))], opt(arr(name_ty("u8"))), rd)
    h.function(
        "write",
        [const_arr(name_ty("u8")), const_arr(name_ty("u8"))],
        name_ty("bool"),
        wr,
    )
    return h


def sys_host(args):
    """Build the sys host module exposing argv, exe path, and environment."""
    h = HostModule(("sys",))
    h.function("args", [], arr(arr(name_ty("u8"))), lambda: array_strings(args))
    h.function(
        "exe_path",
        [],
        arr(name_ty("u8")),
        lambda: array_bytes(os.fsencode(sys.executable)),
    )

    def getenv(name):
        """Getenv (sys_host helper for the L direct host runner)."""
        value = os.environ.get(os.fsdecode(to_bytes(name)))
        return None if value is None else SomeVal(array_bytes(os.fsencode(value)))

    h.function("getenv", [const_arr(name_ty("u8"))], opt(arr(name_ty("u8"))), getenv)
    return h


def build_sources(main_path: Path, editor=False):
    """Assemble the L source map for the main program or editor."""
    if editor:
        keep = {("arrays",), ("bytes",), ("strconv",), ("utf8",), ("json",), ("lsp",)}
        d = {k: p.read_text() for k, p in COMMON.items() if k in keep}
        d[("lsp_client",)] = (HOST_LIB / "lsp_client.l").read_text()
    else:
        d = {k: p.read_text() for k, p in COMMON.items()}
    d[("main",)] = main_path.read_text()
    return d


def execute(program, hosts, use_vm=False):
    """Execute a linked program via the tree interpreter or bytecode VM."""
    if not use_vm:
        return program.run(("main",))
    return BCVM(BCCompiler(program.checked), hosts).run(
        internal_name(("main",), "main")
    )


def run_server(name, use_vm=False):
    """Run one of the L-written language servers on stdio."""
    hosts = {("stdio",): stdio_host()}
    p = Program(build_sources(SERVER_FILES[name]), hosts)
    execute(p, hosts, use_vm)


def run_editor(path, server_kind, use_vm=False):
    """Run the Lace modal editor against a file with a language server."""
    ph = ProcessHost()
    th = TermHost()
    server_argv = [sys.executable, str(HERE / "run.py"), server_kind]
    hosts = {
        ("proc",): ph.module(),
        ("term",): th.module(),
        ("fs",): fs_host(),
        ("sys",): sys_host([path, *server_argv]),
    }
    try:
        p = Program(build_sources(TOOLS / "lace/lace.l", editor=True), hosts)
        execute(p, hosts, use_vm)
    finally:
        th.leave()
        ph.cleanup()


def main():
    """Entry point for the direct host runner."""
    if len(sys.argv) >= 2:
        cmd = sys.argv[1]
        use_vm = cmd.endswith("-vm")
        base = cmd[:-3] if use_vm else cmd
        if base in SERVER_FILES:
            run_server(base, use_vm)
            return 0
    if len(sys.argv) >= 3 and sys.argv[1] in ("editor", "editor-vm"):
        use_vm = sys.argv[1] == "editor-vm"
        kind = (
            sys.argv[3]
            if len(sys.argv) >= 4
            else (
                "json-lsp"
                if sys.argv[2].endswith(".json")
                else "ini-lsp" if sys.argv[2].endswith(".ini") else "slang-lsp"
            )
        )
        run_editor(sys.argv[2], kind, use_vm)
        return 0
    print(
        "usage: hosts/run.py {slang-lsp|json-lsp|ini-lsp} | editor FILE [SERVER]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
