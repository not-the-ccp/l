#!/usr/bin/env python3
from __future__ import annotations

"""Public SDK CLI module.

The historical implementation lives in ``_sdk_cli_impl``. Platform feature
layers are installed here before the implementation's public API is re-exported,
mirroring the existing ``core`` / ``_core_impl`` split.
"""

import _sdk_cli_impl as _impl

if _impl.IS_LINUX:
    from linux_job_host import LinuxJobHost
    from linux_signal_host import LinuxSignalHost

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
        hosts, ph, th, lh = _base_make_hosts_full(argv)
        if lh is not None:
            hosts.update(LinuxJobHost(lh).modules())
            hosts.update(LinuxSignalHost().modules())
        return hosts, ph, th, lh

    # Functions defined in _sdk_cli_impl resolve globals in that module, so
    # patch the implementation binding as well as exporting the wrapper below.
    _impl.make_hosts_full = _make_hosts_full_with_linux_extensions

# Re-export after feature installation so callers keep the historical surface.
globals().update({
    name: value
    for name, value in vars(_impl).items()
    if not name.startswith("_")
})

if __name__ == "__main__":
    raise SystemExit(_impl.main())
