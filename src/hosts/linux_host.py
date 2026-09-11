"""Linux host profile: file descriptors, processes, filesystem, and environment.

Implements the linux.* host modules (fd, fs, env, process) that let
natively run L programs own real OS resources with explicit cleanup.
"""
from __future__ import annotations

import errno
import os
import signal
import struct
from dataclasses import dataclass

from lang import (
    UNIT,
    UNITV,
    ArrayObj,
    HostModule,
    OpaqueVal,
    SomeVal,
    TrapSig,
    arr,
    const_arr,
    name_ty,
    opt,
)

FD_TYPE = ("linux", "fd", "Fd")
CHILD_TYPE = ("linux", "process", "Child")
GROUP_TYPE = ("linux", "process", "Group")
SPAWN_TYPE = ("linux", "process", "SpawnResult")
STATUS_TYPE = ("linux", "process", "ExitStatus")
OPEN_TYPE = ("linux", "fd", "OpenResult")


@dataclass
class LinuxFd:
    """Owned Linux file descriptor wrapper."""
    fd: int
    closed: bool = False


@dataclass
class LinuxChild:
    """Owned Linux child-process handle wrapper."""
    pid: int
    pidfd: int
    pgid: int
    waited: bool = False


@dataclass(frozen=True)
class LinuxGroup:
    """Linux process-group identity wrapper."""
    pgid: int


@dataclass(frozen=True)
class LinuxSpawnResult:
    """Outcome of a spawn request: child handle or spawn error."""
    child: LinuxChild | None
    error_number: int | None


@dataclass(frozen=True)
class LinuxExitStatus:
    """Reaped child exit status wrapper."""
    exited: bool
    code: int


@dataclass(frozen=True)
class LinuxOpenResult:
    """Outcome of an open request: descriptor or error string."""
    fd: LinuxFd | None
    error_number: int | None


def _bytes(value: ArrayObj) -> bytes:
    """Convert an L byte array to Python bytes."""
    if not isinstance(value, ArrayObj):
        raise TrapSig("expected byte array")
    out = bytearray()
    for item in value.items:
        if not isinstance(item, int):
            raise TrapSig("expected byte array")
        out.append(item & 0xFF)
    return bytes(out)


def _argv(value: ArrayObj) -> list[bytes]:
    """Convert an L string array to an OS argument vector."""
    if not isinstance(value, ArrayObj):
        raise TrapSig("expected argv array")
    return [_bytes(item) for item in value.items]


def _opaque(value, type_id: tuple[str, ...], what: str):
    """Unwrap an opaque host value to its payload."""
    if not isinstance(value, OpaqueVal) or value.type_id != type_id:
        raise TrapSig(f"expected {what}")
    return value.payload


def _errno_result(exc: BaseException):
    """Wrap an errno outcome as an L result value."""
    if isinstance(exc, OSError):
        return SomeVal(int(exc.errno or errno.EIO))
    if isinstance(exc, MemoryError):
        return SomeVal(errno.ENOMEM)
    return SomeVal(errno.EINVAL)


class LinuxHost:
    """Reference implementation of the Linux-specific hosted profile.

    Descriptor values own their underlying descriptor and may be aliased as L
    values. Closing one alias closes the shared handle; later operations through
    another alias trap. Child values similarly identify one tracked process.
    Expected OS failures for spawn/signalling/context mutation are returned as
    errno values; contract violations remain traps.
    """

    def __init__(self):
        """Init (LinuxHost helper for the L Linux host profile)."""
        self.fds: list[LinuxFd] = []
        self.children: list[LinuxChild] = []

    def _own_fd(self, fd: int) -> OpaqueVal:
        """Own fd (LinuxHost helper for the L Linux host profile)."""
        os.set_inheritable(fd, False)
        owned = LinuxFd(fd)
        self.fds.append(owned)
        return OpaqueVal(FD_TYPE, owned)

    def _fd(self, value) -> LinuxFd:
        """Fd (LinuxHost helper for the L Linux host profile)."""
        fd = _opaque(value, FD_TYPE, "linux.fd.Fd")
        if not isinstance(fd, LinuxFd) or fd.closed:
            raise TrapSig("linux.fd.Fd is closed")
        return fd

    def _child(self, value) -> LinuxChild:
        """Child (LinuxHost helper for the L Linux host profile)."""
        child = _opaque(value, CHILD_TYPE, "linux.process.Child")
        if not isinstance(child, LinuxChild):
            raise TrapSig("invalid linux.process.Child")
        return child

    def _group(self, value) -> LinuxGroup:
        """Group (LinuxHost helper for the L Linux host profile)."""
        group = _opaque(value, GROUP_TYPE, "linux.process.Group")
        if not isinstance(group, LinuxGroup):
            raise TrapSig("invalid linux.process.Group")
        return group

    def _spawn_result(self, value) -> LinuxSpawnResult:
        """Spawn result (LinuxHost helper for the L Linux host profile)."""
        result = _opaque(value, SPAWN_TYPE, "linux.process.SpawnResult")
        if not isinstance(result, LinuxSpawnResult):
            raise TrapSig("invalid linux.process.SpawnResult")
        return result

    def _status(self, value) -> LinuxExitStatus:
        """Status (LinuxHost helper for the L Linux host profile)."""
        status = _opaque(value, STATUS_TYPE, "linux.process.ExitStatus")
        if not isinstance(status, LinuxExitStatus):
            raise TrapSig("invalid linux.process.ExitStatus")
        return status

    def _open_result(self, value) -> LinuxOpenResult:
        """Open result (LinuxHost helper for the L Linux host profile)."""
        result = _opaque(value, OPEN_TYPE, "linux.fd.OpenResult")
        if not isinstance(result, LinuxOpenResult):
            raise TrapSig("invalid linux.fd.OpenResult")
        return result

    # linux.fd

    def _dup_std(self, fd: int):
        """Dup std (LinuxHost helper for the L Linux host profile)."""
        return self._own_fd(os.dup(fd))

    def _dup(self, value):
        """Dup (LinuxHost helper for the L Linux host profile)."""
        return self._own_fd(os.dup(self._fd(value).fd))

    def _pipe(self):
        """Pipe (LinuxHost helper for the L Linux host profile)."""
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
        return ArrayObj([self._own_fd(read_fd), self._own_fd(write_fd)])

    def _open_file(self, path_value, flags: int):
        """Open file (LinuxHost helper for the L Linux host profile)."""
        path = _bytes(path_value)
        if b"\0" in path:
            return OpaqueVal(OPEN_TYPE, LinuxOpenResult(None, errno.EINVAL))
        try:
            raw = os.open(path, flags | os.O_CLOEXEC, 0o666)
            owned = self._own_fd(raw).payload
            return OpaqueVal(OPEN_TYPE, LinuxOpenResult(owned, None))
        except BaseException as exc:
            result = _errno_result(exc)
            return OpaqueVal(OPEN_TYPE, LinuxOpenResult(None, int(result.value)))

    def _open_read(self, path_value):
        """Open read (LinuxHost helper for the L Linux host profile)."""
        return self._open_file(path_value, os.O_RDONLY)

    def _create_truncate(self, path_value):
        """Create truncate (LinuxHost helper for the L Linux host profile)."""
        return self._open_file(path_value, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)

    def _create_append(self, path_value):
        """Create append (LinuxHost helper for the L Linux host profile)."""
        return self._open_file(path_value, os.O_WRONLY | os.O_CREAT | os.O_APPEND)

    def _open_fd(self, value):
        """Open fd (LinuxHost helper for the L Linux host profile)."""
        result = self._open_result(value)
        if result.fd is None:
            return None
        return SomeVal(OpaqueVal(FD_TYPE, result.fd))

    def _open_error(self, value):
        """Open error (LinuxHost helper for the L Linux host profile)."""
        result = self._open_result(value)
        if result.error_number is None:
            return None
        return SomeVal(result.error_number)

    def _close(self, value):
        """Close (LinuxHost helper for the L Linux host profile)."""
        fd = _opaque(value, FD_TYPE, "linux.fd.Fd")
        if not isinstance(fd, LinuxFd):
            raise TrapSig("invalid linux.fd.Fd")
        if not fd.closed:
            try:
                os.close(fd.fd)
            except OSError as exc:
                if exc.errno != errno.EBADF:
                    raise TrapSig(f"linux.fd.close failed: {exc}") from exc
            fd.closed = True
        return UNITV

    def _read(self, value, max_bytes):
        """Read (LinuxHost helper for the L Linux host profile)."""
        fd = self._fd(value).fd
        want = int(max_bytes)
        if want == 0:
            return SomeVal(ArrayObj([]))
        while True:
            try:
                data = os.read(fd, want)
                break
            except InterruptedError:
                continue
            except OSError as exc:
                raise TrapSig(f"linux.fd.read failed: {exc}") from exc
        if data == b"":
            return None
        return SomeVal(ArrayObj(list(data)))

    def _write(self, value, data_value):
        """Write (LinuxHost helper for the L Linux host profile)."""
        fd = self._fd(value).fd
        data = _bytes(data_value)
        while True:
            try:
                return os.write(fd, data)
            except InterruptedError:
                continue
            except OSError as exc:
                raise TrapSig(f"linux.fd.write failed: {exc}") from exc

    # linux.fs

    def _cwd(self):
        """Cwd (LinuxHost helper for the L Linux host profile)."""
        try:
            return SomeVal(ArrayObj(list(os.getcwdb())))
        except OSError:
            return None

    def _chdir(self, path_value):
        """Chdir (LinuxHost helper for the L Linux host profile)."""
        path = _bytes(path_value)
        if b"\0" in path:
            return SomeVal(errno.EINVAL)
        try:
            os.chdir(path)
            return None
        except BaseException as exc:
            return _errno_result(exc)

    # linux.env

    def _env_get(self, name_value):
        """Env get (LinuxHost helper for the L Linux host profile)."""
        name = _bytes(name_value)
        if not name or b"\0" in name or b"=" in name:
            return None
        value = os.environb.get(name)
        if value is None:
            return None
        return SomeVal(ArrayObj(list(value)))

    def _env_entries(self):
        """Env entries (LinuxHost helper for the L Linux host profile)."""
        return ArrayObj(
            [ArrayObj(list(name + b"=" + value)) for name, value in os.environb.items()]
        )

    def _env_set(self, name_value, value_value, overwrite_value):
        """Env set (LinuxHost helper for the L Linux host profile)."""
        name = _bytes(name_value)
        value = _bytes(value_value)
        if not name or b"\0" in name or b"=" in name or b"\0" in value:
            return SomeVal(errno.EINVAL)
        try:
            if not bool(overwrite_value) and name in os.environb:
                return None
            os.environb[name] = value
            return None
        except BaseException as exc:
            return _errno_result(exc)

    def _env_unset(self, name_value):
        """Env unset (LinuxHost helper for the L Linux host profile)."""
        name = _bytes(name_value)
        if not name or b"\0" in name or b"=" in name:
            return SomeVal(errno.EINVAL)
        try:
            os.environb.pop(name, None)
            return None
        except BaseException as exc:
            return _errno_result(exc)

    # linux.process

    def _set_foreground_pgid(self, descriptor: int, pgid: int) -> None:
        """Set foreground pgid (LinuxHost helper for the L Linux host profile)."""
        old_mask = None
        try:
            if hasattr(signal, "pthread_sigmask"):
                old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTTOU})
            os.tcsetpgrp(descriptor, pgid)
        finally:
            if old_mask is not None:
                signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)

    def _spawn_exact_impl(
        self,
        path_value,
        argv_value,
        stdin_value,
        stdout_value,
        stderr_value,
        group_value,
        foreground_fd: int | None,
    ):
        """Spawn exact impl (LinuxHost helper for the L Linux host profile)."""
        path = _bytes(path_value)
        argv = _argv(argv_value)
        if not path or b"\0" in path:
            raise TrapSig("linux.process.spawn_exact requires a nonempty NUL-free path")
        if not argv:
            raise TrapSig("linux.process.spawn_exact requires a nonempty argv")
        if any(b"\0" in arg for arg in argv):
            raise TrapSig("linux.process.spawn_exact argv contains NUL")

        in_fd = self._fd(stdin_value).fd
        out_fd = self._fd(stdout_value).fd
        err_fd = self._fd(stderr_value).fd
        requested_group = None
        if isinstance(group_value, SomeVal):
            requested_group = self._group(group_value.value).pgid
        elif group_value is not None:
            raise TrapSig("invalid optional linux.process.Group")

        previous_foreground = None
        if foreground_fd is not None:
            try:
                previous_foreground = os.tcgetpgrp(foreground_fd)
            except OSError as exc:
                return OpaqueVal(
                    SPAWN_TYPE,
                    LinuxSpawnResult(None, int(exc.errno or errno.EIO)),
                )

        env = dict(os.environb)
        inherited_fds = [item.fd for item in self.fds if not item.closed]
        launch_read, launch_write = os.pipe2(os.O_CLOEXEC)

        pid = os.fork()
        if pid == 0:
            try:
                os.close(launch_read)
                os.setpgid(0, 0 if requested_group is None else requested_group)
                if foreground_fd is not None:
                    self._set_foreground_pgid(foreground_fd, os.getpgrp())
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
                number = (
                    exc.errno if isinstance(exc, OSError) and exc.errno else errno.EIO
                )
                try:
                    os.write(launch_write, struct.pack("=i", int(number)))
                except BaseException:
                    pass
                os._exit(127)

        os.close(launch_write)
        pgid = pid if requested_group is None else requested_group
        try:
            os.setpgid(pid, pgid)
        except (ProcessLookupError, PermissionError):
            pass
        if foreground_fd is not None:
            try:
                self._set_foreground_pgid(foreground_fd, pgid)
            except OSError:
                # The child performs the same handoff before exec and reports
                # setup failure through the launch pipe. This parent call is
                # the race-closing half of the standard job-control pattern.
                pass

        try:
            pidfd = os.pidfd_open(pid, 0)
        except BaseException:
            os.close(launch_read)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            if previous_foreground is not None:
                try:
                    self._set_foreground_pgid(foreground_fd, previous_foreground)
                except OSError:
                    pass
            raise

        payload = b""
        while len(payload) < 4:
            try:
                part = os.read(launch_read, 4 - len(payload))
            except InterruptedError:
                continue
            if not part:
                break
            payload += part
        os.close(launch_read)

        if payload:
            number = struct.unpack("=i", payload.ljust(4, b"\0")[:4])[0]
            try:
                os.waitid(os.P_PIDFD, pidfd, os.WEXITED)
            except (ChildProcessError, OSError):
                pass
            os.close(pidfd)
            if previous_foreground is not None:
                try:
                    self._set_foreground_pgid(foreground_fd, previous_foreground)
                except OSError:
                    pass
            return OpaqueVal(SPAWN_TYPE, LinuxSpawnResult(None, number))

        child = LinuxChild(pid=pid, pidfd=pidfd, pgid=pgid)
        self.children.append(child)
        return OpaqueVal(SPAWN_TYPE, LinuxSpawnResult(child, None))

    def _spawn_exact(
        self,
        path_value,
        argv_value,
        stdin_value,
        stdout_value,
        stderr_value,
        group_value,
    ):
        """Spawn exact (LinuxHost helper for the L Linux host profile)."""
        return self._spawn_exact_impl(
            path_value,
            argv_value,
            stdin_value,
            stdout_value,
            stderr_value,
            group_value,
            None,
        )

    def _spawn_foreground_exact(
        self,
        path_value,
        argv_value,
        stdin_value,
        stdout_value,
        stderr_value,
        group_value,
        terminal_value,
    ):
        """Spawn foreground exact (LinuxHost helper for the L Linux host profile)."""
        terminal_fd = self._fd(terminal_value).fd
        return self._spawn_exact_impl(
            path_value,
            argv_value,
            stdin_value,
            stdout_value,
            stderr_value,
            group_value,
            terminal_fd,
        )

    def _spawn_child(self, value):
        """Spawn child (LinuxHost helper for the L Linux host profile)."""
        result = self._spawn_result(value)
        if result.child is None:
            return None
        return SomeVal(OpaqueVal(CHILD_TYPE, result.child))

    def _spawn_error(self, value):
        """Spawn error (LinuxHost helper for the L Linux host profile)."""
        result = self._spawn_result(value)
        if result.error_number is None:
            return None
        return SomeVal(result.error_number)

    def _child_group(self, value):
        """Child group (LinuxHost helper for the L Linux host profile)."""
        child = self._child(value)
        return OpaqueVal(GROUP_TYPE, LinuxGroup(child.pgid))

    def _send(self, value, number):
        """Send (LinuxHost helper for the L Linux host profile)."""
        child = self._child(value)
        signo = int(number)
        try:
            if child.pidfd >= 0 and hasattr(signal, "pidfd_send_signal"):
                signal.pidfd_send_signal(child.pidfd, signo)
            else:
                os.kill(child.pid, signo)
            return None
        except OSError as exc:
            return SomeVal(int(exc.errno or errno.EIO))

    def _send_group(self, value, number):
        """Send group (LinuxHost helper for the L Linux host profile)."""
        group = self._group(value)
        try:
            os.killpg(group.pgid, int(number))
            return None
        except OSError as exc:
            return SomeVal(int(exc.errno or errno.EIO))

    def _wait_exit(self, value):
        """Wait exit (LinuxHost helper for the L Linux host profile)."""
        child = self._child(value)
        if child.waited:
            raise TrapSig("linux.process.Child was already waited")

        while True:
            try:
                info = os.waitid(os.P_PIDFD, child.pidfd, os.WEXITED)
                break
            except InterruptedError:
                continue
            except OSError as exc:
                raise TrapSig(f"linux.process.wait_exit failed: {exc}") from exc

        child.waited = True
        try:
            os.close(child.pidfd)
        except OSError:
            pass
        child.pidfd = -1

        if info.si_code == os.CLD_EXITED:
            status = LinuxExitStatus(True, int(info.si_status))
        elif info.si_code in (os.CLD_KILLED, os.CLD_DUMPED):
            status = LinuxExitStatus(False, int(info.si_status))
        else:
            raise TrapSig("linux.process.wait_exit received a nonterminal state")
        return OpaqueVal(STATUS_TYPE, status)

    def _exit_code(self, value):
        """Exit code (LinuxHost helper for the L Linux host profile)."""
        status = self._status(value)
        return SomeVal(status.code) if status.exited else None

    def _term_signal(self, value):
        """Term signal (LinuxHost helper for the L Linux host profile)."""
        status = self._status(value)
        return None if status.exited else SomeVal(status.code)

    def fd_module(self) -> HostModule:
        """Fd module (LinuxHost helper for the L Linux host profile)."""
        host = HostModule(("linux", "fd"))
        fd_ty = host.opaque_type("Fd")
        bytes_ro = const_arr(name_ty("u8"))

        host.function("stdin", [], fd_ty, lambda: self._dup_std(0))
        host.function("stdout", [], fd_ty, lambda: self._dup_std(1))
        host.function("stderr", [], fd_ty, lambda: self._dup_std(2))
        host.function("dup", [fd_ty], fd_ty, self._dup)
        host.function("pipe", [], arr(fd_ty), self._pipe)
        open_ty = host.opaque_type("OpenResult")
        host.function("open_read", [bytes_ro], open_ty, self._open_read)
        host.function("create_truncate", [bytes_ro], open_ty, self._create_truncate)
        host.function("create_append", [bytes_ro], open_ty, self._create_append)
        host.function("open_fd", [open_ty], opt(fd_ty), self._open_fd)
        host.function("open_error", [open_ty], opt(name_ty("i64")), self._open_error)
        host.function("close", [fd_ty], UNIT, self._close)
        host.function(
            "read", [fd_ty, name_ty("u64")], opt(arr(name_ty("u8"))), self._read
        )
        host.function("write", [fd_ty, bytes_ro], name_ty("u64"), self._write)
        return host

    def fs_module(self) -> HostModule:
        """Fs module (LinuxHost helper for the L Linux host profile)."""
        host = HostModule(("linux", "fs"))
        bytes_ro = const_arr(name_ty("u8"))
        host.function("cwd", [], opt(arr(name_ty("u8"))), self._cwd)
        host.function("chdir", [bytes_ro], opt(name_ty("i64")), self._chdir)
        return host

    def env_module(self) -> HostModule:
        """Env module (LinuxHost helper for the L Linux host profile)."""
        host = HostModule(("linux", "env"))
        bytes_ro = const_arr(name_ty("u8"))
        i64_ty = name_ty("i64")
        host.function("get", [bytes_ro], opt(arr(name_ty("u8"))), self._env_get)
        host.function("entries", [], arr(arr(name_ty("u8"))), self._env_entries)
        host.function(
            "set", [bytes_ro, bytes_ro, name_ty("bool")], opt(i64_ty), self._env_set
        )
        host.function("unset", [bytes_ro], opt(i64_ty), self._env_unset)
        return host

    def process_module(self) -> HostModule:
        """Process module (LinuxHost helper for the L Linux host profile)."""
        host = HostModule(("linux", "process"))
        fd_ty = name_ty(("__host__", "linux", "fd", "Fd"))
        child_ty = host.opaque_type("Child")
        group_ty = host.opaque_type("Group")
        spawn_ty = host.opaque_type("SpawnResult")
        status_ty = host.opaque_type("ExitStatus")
        bytes_ro = const_arr(name_ty("u8"))
        argv_ro = const_arr(bytes_ro)
        i64_ty = name_ty("i64")
        signal_result_ty = opt(i64_ty)

        host.function(
            "spawn_exact",
            [bytes_ro, argv_ro, fd_ty, fd_ty, fd_ty, opt(group_ty)],
            spawn_ty,
            self._spawn_exact,
        )
        host.function("spawn_child", [spawn_ty], opt(child_ty), self._spawn_child)
        host.function("spawn_error", [spawn_ty], opt(i64_ty), self._spawn_error)
        host.function("group", [child_ty], group_ty, self._child_group)
        host.function("send", [child_ty, i64_ty], signal_result_ty, self._send)
        host.function(
            "send_group", [group_ty, i64_ty], signal_result_ty, self._send_group
        )
        host.function("sigint", [], i64_ty, lambda: int(signal.SIGINT))
        host.function("sigquit", [], i64_ty, lambda: int(signal.SIGQUIT))
        host.function("sigterm", [], i64_ty, lambda: int(signal.SIGTERM))
        host.function("sigkill", [], i64_ty, lambda: int(signal.SIGKILL))
        host.function("sigstop", [], i64_ty, lambda: int(signal.SIGSTOP))
        host.function("sigtstp", [], i64_ty, lambda: int(signal.SIGTSTP))
        host.function("sigcont", [], i64_ty, lambda: int(signal.SIGCONT))
        host.function("sighup", [], i64_ty, lambda: int(signal.SIGHUP))
        host.function("wait_exit", [child_ty], status_ty, self._wait_exit)
        host.function("exit_code", [status_ty], opt(i64_ty), self._exit_code)
        host.function("term_signal", [status_ty], opt(i64_ty), self._term_signal)
        return host

    def modules(self) -> dict[tuple[str, ...], HostModule]:
        """Modules (LinuxHost helper for the L Linux host profile)."""
        return {
            ("linux", "fd"): self.fd_module(),
            ("linux", "fs"): self.fs_module(),
            ("linux", "env"): self.env_module(),
            ("linux", "process"): self.process_module(),
        }

    def _contain_fd(self, fd: LinuxFd):
        """Contain fd (LinuxHost boundary helper for issue #20)."""
        if not fd.closed:
            try:
                os.close(fd.fd)
            except OSError:
                pass
            fd.closed = True

    def _contain_child(self, child: LinuxChild):
        """Contain child (LinuxHost boundary helper for issue #20)."""
        if child.waited:
            return
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
        else:
            try:
                os.kill(child.pid, signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass
            try:
                os.waitpid(child.pid, 0)
            except (ChildProcessError, OSError):
                pass
        child.pidfd = -1
        child.waited = True

    def checkpoint(self):
        """Checkpoint (LinuxHost boundary hook for issue #20)."""
        return (len(self.fds), len(self.children))

    def rollback(self, checkpoint):
        """Rollback (LinuxHost boundary hook for issue #20)."""
        nfd, nchild = (int(checkpoint[0]), int(checkpoint[1]))
        for fd in self.fds[nfd:]:
            self._contain_fd(fd)
        for child in self.children[nchild:]:
            self._contain_child(child)

    def cleanup(self):
        """Cleanup (LinuxHost helper for the L Linux host profile)."""
        for fd in self.fds:
            self._contain_fd(fd)

        for child in self.children:
            self._contain_child(child)
