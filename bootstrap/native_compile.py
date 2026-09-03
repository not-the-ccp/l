#!/usr/bin/env python3
from __future__ import annotations

"""Public native compiler entrypoint with hosted-profile extensions."""

import _native_compile_impl as _impl

_impl.HOST.update({
    (("linux", "process", "group"), "current"): 56,
    (("linux", "process", "group"), "become_leader"): 57,
    (("linux", "process", "group"), "same"): 58,
    (("linux", "process", "wait"), "child"): 59,
    (("linux", "process", "wait"), "group"): 60,
    (("linux", "process", "wait"), "poll_group"): 61,
    (("linux", "process", "wait"), "event_child"): 62,
    (("linux", "process", "wait"), "exit_code"): 63,
    (("linux", "process", "wait"), "term_signal"): 64,
    (("linux", "process", "wait"), "stop_signal"): 65,
    (("linux", "process", "wait"), "continued"): 66,
    (("linux", "tty"), "is_tty"): 67,
    (("linux", "tty"), "foreground"): 68,
    (("linux", "tty"), "set_foreground"): 69,
})

globals().update({
    name: value
    for name, value in vars(_impl).items()
    if not name.startswith("_")
})

if __name__ == "__main__":
    raise SystemExit(_impl.main())
