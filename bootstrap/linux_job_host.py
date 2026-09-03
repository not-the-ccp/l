from __future__ import annotations

from dataclasses import dataclass
import errno
import os
import signal

from core import HostModule, OpaqueVal, SomeVal, TrapSig, arr, name_ty, opt
from linux_host import (
    CHILD_TYPE,
    FD_TYPE,
    GROUP_TYPE,
    LinuxChild,
    LinuxGroup,
    LinuxHost,
)


EVENT_TYPE = ("linux", "process", "wait", "Event")


@dataclass(frozen=True)
class LinuxProcessEvent:
    child: LinuxChild
    kind: str
    code: int


class LinuxJobHost:
    """Process-state and controlling-terminal operations layered on LinuxHost.

    This layer deliberately models kernel process groups/events rather than
    shell jobs. Terminal events reap terminal child states; stopped/continued
    events leave the child waitable for later state changes.
    """

    def __init__(self, linux: LinuxHost):
        self.linux = linux

    def _event(self, value) -> LinuxProcessEvent:
        if not isinstance(value, OpaqueVal) or value.type_id != EVENT_TYPE:
            raise TrapSig("expected linux.process.wait.Event")
        event = value.payload
        if not isinstance(event, LinuxProcessEvent):
            raise TrapSig("invalid linux.process.wait.Event")
        return event

    def _find_child(self, pid: int) -> LinuxChild:
        for child in self.linux.children:
            if child.pid == pid:
                return child
        raise TrapSig("wait returned an untracked child")

    def _finish_terminal(self, child: LinuxChild):
        child.waited = True
        if child.pidfd >= 0:
            try:
                os.close(child.pidfd)
            except OSError:
                pass
            child.pidfd = -1

    def _from_waitid(self, info) -> OpaqueVal:
        child = self._find_child(int(info.si_pid))
        if info.si_code == os.CLD_EXITED:
            kind = "exited"
            code = int(info.si_status)
            self._finish_terminal(child)
        elif info.si_code in (os.CLD_KILLED, os.CLD_DUMPED):
            kind = "signaled"
            code = int(info.si_status)
            self._finish_terminal(child)
        elif info.si_code == os.CLD_STOPPED:
            kind = "stopped"
            code = int(info.si_status)
        elif info.si_code == os.CLD_CONTINUED:
            kind = "continued"
            code = 0
        else:
            raise TrapSig("unsupported child state from waitid")
        return OpaqueVal(EVENT_TYPE, LinuxProcessEvent(child, kind, code))

    def _waitid(self, idtype: int, ident: int, nonblocking: bool):
        options = os.WEXITED | os.WSTOPPED | os.WCONTINUED
        if nonblocking:
            options |= os.WNOHANG
        while True:
            try:
                info = os.waitid(idtype, ident, options)
                break
            except InterruptedError:
                continue
            except OSError as exc:
                raise TrapSig(f"linux.process.wait failed: {exc}") from exc
        if info is None or int(getattr(info, "si_pid", 0)) == 0:
            return None
        return self._from_waitid(info)

    # linux.process.group

    def _current_group(self):
        return OpaqueVal(GROUP_TYPE, LinuxGroup(os.getpgrp()))

    def _become_group_leader(self):
        try:
            os.setpgid(0, 0)
            return None
        except OSError as exc:
            return SomeVal(int(exc.errno or errno.EIO))

    def _same_group(self, left, right):
        return self.linux._group(left).pgid == self.linux._group(right).pgid

    # linux.process.wait

    def _wait_child(self, value):
        child = self.linux._child(value)
        if child.waited:
            raise TrapSig("linux.process.Child was already reaped")
        if child.pidfd >= 0 and hasattr(os, "P_PIDFD"):
            return self._waitid(os.P_PIDFD, child.pidfd, False)
        return self._waitid(os.P_PID, child.pid, False)

    def _wait_group(self, value):
        group = self.linux._group(value)
        result = self._waitid(os.P_PGID, group.pgid, False)
        if result is None:
            raise TrapSig("blocking group wait returned no event")
        return result

    def _poll_group(self, value):
        group = self.linux._group(value)
        result = self._waitid(os.P_PGID, group.pgid, True)
        if result is None:
            return None
        return SomeVal(result)

    def _event_child(self, value):
        event = self._event(value)
        return OpaqueVal(CHILD_TYPE, event.child)

    def _event_value(self, value, kind: str):
        event = self._event(value)
        return SomeVal(event.code) if event.kind == kind else None

    def _continued(self, value):
        return self._event(value).kind == "continued"

    # linux.tty

    def _is_tty(self, value):
        return os.isatty(self.linux._fd(value).fd)

    def _foreground(self, value):
        descriptor = self.linux._fd(value).fd
        try:
            pgid = os.tcgetpgrp(descriptor)
            return SomeVal(OpaqueVal(GROUP_TYPE, LinuxGroup(int(pgid))))
        except OSError:
            return None

    def _set_foreground(self, descriptor_value, group_value):
        descriptor = self.linux._fd(descriptor_value).fd
        group = self.linux._group(group_value)
        old_mask = None
        try:
            if hasattr(signal, "pthread_sigmask"):
                old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTTOU})
            os.tcsetpgrp(descriptor, group.pgid)
            return None
        except OSError as exc:
            return SomeVal(int(exc.errno or errno.EIO))
        finally:
            if old_mask is not None:
                signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)

    def group_module(self) -> HostModule:
        host = HostModule(("linux", "process", "group"))
        group_ty = name_ty(("__host__", "linux", "process", "Group"))
        host.function("current", [], group_ty, self._current_group)
        host.function("become_leader", [], opt(name_ty("i64")), self._become_group_leader)
        host.function("same", [group_ty, group_ty], name_ty("bool"), self._same_group)
        return host

    def wait_module(self) -> HostModule:
        host = HostModule(("linux", "process", "wait"))
        child_ty = name_ty(("__host__", "linux", "process", "Child"))
        group_ty = name_ty(("__host__", "linux", "process", "Group"))
        event_ty = host.opaque_type("Event")
        i64_ty = name_ty("i64")
        host.function("child", [child_ty], event_ty, self._wait_child)
        host.function("group", [group_ty], event_ty, self._wait_group)
        host.function("poll_group", [group_ty], opt(event_ty), self._poll_group)
        host.function("event_child", [event_ty], child_ty, self._event_child)
        host.function("exit_code", [event_ty], opt(i64_ty), lambda value: self._event_value(value, "exited"))
        host.function("term_signal", [event_ty], opt(i64_ty), lambda value: self._event_value(value, "signaled"))
        host.function("stop_signal", [event_ty], opt(i64_ty), lambda value: self._event_value(value, "stopped"))
        host.function("continued", [event_ty], name_ty("bool"), self._continued)
        return host

    def tty_module(self) -> HostModule:
        host = HostModule(("linux", "tty"))
        fd_ty = name_ty(("__host__", "linux", "fd", "Fd"))
        group_ty = name_ty(("__host__", "linux", "process", "Group"))
        host.function("is_tty", [fd_ty], name_ty("bool"), self._is_tty)
        host.function("foreground", [fd_ty], opt(group_ty), self._foreground)
        host.function("set_foreground", [fd_ty, group_ty], opt(name_ty("i64")), self._set_foreground)
        return host

    def modules(self) -> dict[tuple[str, ...], HostModule]:
        return {
            ("linux", "process", "group"): self.group_module(),
            ("linux", "process", "wait"): self.wait_module(),
            ("linux", "tty"): self.tty_module(),
        }
