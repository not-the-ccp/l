"""Recoverable host-callback boundary for in-process L extensions.

Python-level twin of the native boundary in ``src/vm/embed.c`` (issue #20).
A hosted application invokes a trusted in-process L callback through
:py:class:`HostBoundary`; a trapping callback reports a structured failure
back to the host instead of propagating, and the interpreter stays usable
for the next call.

Boundaries nest: an inner failure rolls back only resources acquired inside
the inner call while the outer boundary stays armed. Heap object-graph
mutations are not rolled back; completed side effects on pre-existing L
state persist by design, matching the native boundary.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from lang import LangError, TrapSig


@dataclass(frozen=True)
class CallOk:
    """Normal callback return carrying the L return value."""

    value: Any


@dataclass(frozen=True)
class CallTrap:
    """Contained callback failure carrying the host-facing diagnostic."""

    message: str


def _trap_message(exc: BaseException) -> str:
    """Trap message (host_boundary helper for recoverable callbacks)."""
    if isinstance(exc, RecursionError):
        return "call depth exceeded"
    return str(exc) or type(exc).__name__


class HostBoundary:
    """Owns recoverable callback invocations over checkpointable hosts."""

    def __init__(self, proc_host=None, term_host=None, linux_host=None):
        """Init (HostBoundary helper for recoverable callbacks)."""
        self.proc_host = proc_host
        self.term_host = term_host
        self.linux_host = linux_host

    def _snapshot(self):
        """Snapshot (HostBoundary helper for recoverable callbacks)."""
        proc = self.proc_host.checkpoint() if self.proc_host else None
        term = self.term_host.checkpoint() if self.term_host else None
        linux = self.linux_host.checkpoint() if self.linux_host else None
        return (proc, term, linux)

    def _rollback(self, snapshot):
        """Rollback (HostBoundary helper for recoverable callbacks)."""
        proc, term, linux = snapshot
        if self.linux_host is not None and linux is not None:
            self.linux_host.rollback(linux)
        if self.term_host is not None and term is not None:
            self.term_host.rollback(term)
        if self.proc_host is not None and proc is not None:
            self.proc_host.rollback(proc)

    def call(self, fn: Callable[[], Any], stacks=()) -> CallOk | CallTrap:
        """Call (HostBoundary helper for recoverable callbacks)."""
        snapshot = self._snapshot()
        depths = [len(stack) for stack in stacks]
        try:
            return CallOk(fn())
        except (TrapSig, LangError, RecursionError) as exc:
            self._rollback(snapshot)
            for stack, depth in zip(stacks, depths):
                del stack[depth:]
            return CallTrap(_trap_message(exc))
