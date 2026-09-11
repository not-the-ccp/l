#!/usr/bin/env python3
"""Public SDK command-line interface with Linux host-profile extensions.

The command implementation lives in :mod:`tools._sdk_cli`. On Linux this
module additionally registers the Linux job-control and signal host modules
before re-exporting the implementation's public names, so managed processes
get TTY foreground and signal-dispatch behavior.
"""

from __future__ import annotations

import tools._sdk_cli as _impl

if _impl.IS_LINUX:
    from hosts.linux_job_host import LinuxJobHost
    from hosts.linux_signal_host import LinuxSignalHost

    _impl.HOST_MODULES |= {
        ("linux", "process", "launch"),
        ("linux", "process", "group"),
        ("linux", "process", "child"),
        ("linux", "process", "wait"),
        ("linux", "process", "signal"),
        ("linux", "tty"),
    }

    _base_make_hosts_full = _impl.make_hosts_full

    def _make_hosts_full_with_linux_extensions(argv: list[str]):
        """Build the full host set plus Linux job-control and signal modules."""
        hosts, ph, th, lh = _base_make_hosts_full(argv)
        if lh is not None:
            hosts.update(LinuxJobHost(lh).modules())
            hosts.update(LinuxSignalHost().modules())
        return hosts, ph, th, lh

    # Patched on the implementation module because its own functions resolve
    # the binding there; the explicit re-export below then picks it up.
    _impl.make_hosts_full = _make_hosts_full_with_linux_extensions

from tools._sdk_cli import (
    ARTIFACT_MAGIC,
    HERE,
    HOST_MODULES,
    IS_LINUX,
    SLANG_MODULE_NAMES,
    build_program,
    cleanup,
    cmd_check,
    cmd_compile,
    cmd_edit,
    cmd_exec,
    cmd_lsp,
    cmd_run,
    exit_status,
    main,
    make_hosts,
    make_hosts_full,
    module_name,
    parser,
    printable_result,
    project_sources,
    serializable_bc,
    stdlib_sources,
)

__all__ = [
    "ARTIFACT_MAGIC",
    "HERE",
    "HOST_MODULES",
    "IS_LINUX",
    "SLANG_MODULE_NAMES",
    "build_program",
    "cleanup",
    "cmd_check",
    "cmd_compile",
    "cmd_edit",
    "cmd_exec",
    "cmd_lsp",
    "cmd_run",
    "exit_status",
    "main",
    "make_hosts",
    "make_hosts_full",
    "module_name",
    "parser",
    "printable_result",
    "project_sources",
    "serializable_bc",
    "stdlib_sources",
]

if __name__ == "__main__":
    raise SystemExit(main())
