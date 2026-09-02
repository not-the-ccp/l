from __future__ import annotations

from dataclasses import dataclass
import errno
import os
import signal
from typing import Iterable

from core import (
    ArrayObj,
    HostModule,
    OpaqueVal,
    SomeVal,
    TrapSig,
    UNIT,
    UNITV,
    arr,
    name_ty,
    opt,
)


FD_TYPE = ("linux", "proc", "Fd")
CHILD_TYPE = ("linux", "proc", "Child")
GROUP_TYPE = ("linux", "proc", "Group")
STATUS_TYPE = ("linux", "proc", "TerminalStatus")


@dataclass
class LinuxFd:
    fd: int
    closed: bool = False


@dataclass
class LinuxChild:
    pid: int
    pidfd: int
    pgid: int
    waited: bool = False


@dataclass(frozen=True)
class LinuxGroup:
    pgid: int


@dataclass(frozen=True)
class LinuxTerminalStatus:
    exited: bool
    code: int


def _bytes(value: ArrayObj) -> bytes:
    return bytes(int(item) & 0xFF for item in value.items)


def _argv(value: ArrayObj) -> list[bytes]:
    return [_bytes(item) for item in value.items]


def _opaque(value, type_id: tuple[str, ...]):
    if not isinstance(value, OpaqueVal) or value.type_id != type_id:
        raise TrapSig("wrong linux.proc opaque value")
    return value.payload


def _fd(value) -> LinuxFd:
    fd = _opaque(value, FD_TYPE)
    if not isinstance(fd, LinuxFd) or fd.closed:
        raise TrapSig("linux.proc Fd is closed")
    return fd


def _child(value) -> LinuxChild:
    child = _opaque(value, CHILD_TYPE)
    if not isinstance(child, LinuxChild):
        raise TrapSig("invalid linux.proc Child")
    return child


def _group(value) -> LinuxGroup:
    group = _opaque(value, GROUP_TYPE)
    if not isinstance(group, LinuxGroup):
        raise TrapSig("invalid linux.proc Group")
    return group


def _status(value) -> LinuxTerminalStatus:
    status = _opaque(value, STATUS_TYPE)
    if not isinstance(status, LinuxTerminalStatus):
        raise TrapSig("invalid linux.proc TerminalStatus")
    return status


class LinuxProcessHost:
    """Linux-only process/FD experiment for the L shell.

    This API intentionally exposes exact-path execution and explicit descriptor
    wiring. It does not invoke a shell and does not perform PATH lookup.
    """

    def __init__(self):
        self.fds: list[LinuxFd] = []
        self.children: list[LinuxChild] = []

    def _own_fd(self, fd: int) -> OpaqueVal:
        os.set_inheritable(fd, False)
        owned = LinuxFd(fd)
        self.fds.append(owned)
        return OpaqueVal(FD_TYPE, owned)

    def _dup_std(self, fd: int) -> OpaqueVal:
        return self._own_fd(os.dup(fd))

    def _pipe(self) -> ArrayObj:
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
        return ArrayObj([self._own_fd(read_fd), self._own_fd(write_fd)])

    def _close(self, value) -> object:
        fd = _opaque(value, FD_TYPE)
        if not isinstance(fd, LinuxFd):
            raise TrapSig("invalid linux.proc Fd")
        if not fd.closed:
            try:
                os.close(fd.fd)
            except OSError as exc:
                if exc.errno != errno.EBADF:
                    raise
            fd.closed = True
        return UNITV

    def _spawn(self, path_value, argv_value, stdin_value, stdout_value,
               stderr_value, group_value):
        path = _bytes(path_value)
        argv = _argv(argv_value)
        if not path or b"\0" in path:
            raise TrapSig("linux.proc.spawn requires a nonempty NUL-free path")
        if not argv:
            raise TrapSig("linux.proc.spawn requires a nonempty argv")
        if any(b"\0" in arg for arg in argv):
            raise TrapSig("linux.proc.spawn argv contains NUL")

        in_fd = _fd(stdin_value).fd
        out_fd = _fd(stdout_value).fd
        err_fd = _fd(stderr_value).fd
        requested_group = None
        if isinstance(group_value, SomeVal):
            requested_group = _group(group_value.value).pgid
        elif group_value is not None:
            raise TrapSig("invalid optional process group")

        # Prepare everything that allocates Python objects before fork. The
        # reference host is single-threaded, but keeping the post-fork window
        # syscall-shaped also keeps it close to the native implementation.
        env = dict(os.environb)
        inherited_fds = [item.fd for item in self.fds if not item.closed]

        pid = os.fork()
        if pid == 0:
            try:
                pgid = 0 if requested_group is None else requested_group
                os.setpgid(0, pgid)

                os.dup2(in_fd, 0, inheritable=True)
                os.dup2(out_fd, 1, inheritable=True)
                os.dup2(err_fd, 2, inheritable=True)

                for fd in inherited_fds:
                    if fd > 2:
                        try:
                            os.close(fd)
                        except OSError:
                            pass

                for sig in (
                    signal.SIGINT,
                    signal.SIGQUIT,
                    signal.SIGTSTP,
                    signal.SIGTTIN,
                    signal.SIGTTOU,
                    signal.SIGPIPE,
                ):
                    signal.signal(sig, signal.SIG_DFL)

                os.execve(path, argv, env)
            except BaseException as exc:
                code = 127
                if isinstance(exc, OSError) and exc.errno not in (errno.ENOENT, errno.ENOTDIR):
                    code = 126
                os._exit(code)

        pgid = pid if requested_group is None else requested_group
        try:
            os.setpgid(pid, pgid)
        except (ProcessLookupError, PermissionError):
            # The child also performs setpgid before exec. EACCES/ESRCH here
            # therefore means the child won the race or has already exited.
            pass

        try:
            pidfd = os.pidfd_open(pid, 0)
        except BaseException:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            raise

        child = LinuxChild(pid=pid, pidfd=pidfd, pgid=pgid)
        self.children.append(child)
        return OpaqueVal(CHILD_TYPE, child)

    def _child_group(self, value):
        child = _child(value)
        return OpaqueVal(GROUP_TYPE, LinuxGroup(child.pgid))

    def _wait_terminal(self, value):
        child = _child(value)
        if child.waited:
            raise TrapSig("linux.proc child was already waited")

        while True:
            try:
                info = os.waitid(os.P_PIDFD, child.pidfd, os.WEXITED)
                break
            except InterruptedError:
                continue

        child.waited = True
        try:
            os.close(child.pidfd)
        except OSError:
            pass
        child.pidfd = -1

        if info.si_code == os.CLD_EXITED:
            status = LinuxTerminalStatus(True, int(info.si_status))
        elif info.si_code in (os.CLD_KILLED, os.CLD_DUMPED):
            status = LinuxTerminalStatus(False, int(info.si_status))
        else:
            raise TrapSig("linux.proc.wait_terminal received a nonterminal child state")
        return OpaqueVal(STATUS_TYPE, status)

    def _exit_code(self, value):
        status = _status(value)
        if not status.exited:
            return None
        return SomeVal(status.code)

    def _term_signal(self, value):
        status = _status(value)
        if status.exited:
            return None
        return SomeVal(status.code)

    def module(self) -> HostModule:
        host = HostModule(("linux", "proc"))
        fd_ty = host.opaque_type("Fd")
        child_ty = host.opaque_type("Child")
        group_ty = host.opaque_type("Group")
        status_ty = host.opaque_type("TerminalStatus")
        bytes_ty = arr(name_ty("u8"))

        host.function("stdin", [], fd_ty, lambda: self._dup_std(0))
        host.function("stdout", [], fd_ty, lambda: self._dup_std(1))
        host.function("stderr", [], fd_ty, lambda: self._dup_std(2))
        host.function("pipe", [], arr(fd_ty), self._pipe)
        host.function("close", [fd_ty], UNIT, self._close)
        host.function(
            "spawn",
            [bytes_ty, arr(bytes_ty), fd_ty, fd_ty, fd_ty, opt(group_ty)],
            child_ty,
            self._spawn,
        )
        host.function("group", [child_ty], group_ty, self._child_group)
        host.function("wait_terminal", [child_ty], status_ty, self._wait_terminal)
        host.function("exit_code", [status_ty], opt(name_ty("i64")), self._exit_code)
        host.function("term_signal", [status_ty], opt(name_ty("i64")), self._term_signal)
        return host

    def cleanup(self):
        for fd in self.fds:
            if not fd.closed:
                try:
                    os.close(fd.fd)
                except OSError:
                    pass
                fd.closed = True

        for child in self.children:
            if child.waited:
                continue
            if child.pidfd >= 0:
                try:
                    signal.pidfd_send_signal(child.pidfd, signal.SIGKILL)
                except (AttributeError, ProcessLookupError, OSError):
                    try:
                        os.kill(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                try:
                    os.waitid(os.P_PIDFD, child.pidfd, os.WEXITED)
                except (ChildProcessError, OSError):
                    pass
                try:
                    os.close(child.pidfd)
                except OSError:
                    pass
            child.pidfd = -1
            child.waited = True
