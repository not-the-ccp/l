from __future__ import annotations

from dataclasses import dataclass
import errno
import os
import signal
import struct

from core import (
    ArrayObj,
    HostModule,
    OpaqueVal,
    SomeVal,
    TrapSig,
    UNIT,
    UNITV,
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
class LinuxSpawnResult:
    child: LinuxChild | None
    error_number: int | None


@dataclass(frozen=True)
class LinuxExitStatus:
    exited: bool
    code: int


def _bytes(value: ArrayObj) -> bytes:
    if not isinstance(value, ArrayObj):
        raise TrapSig("expected byte array")
    out = bytearray()
    for item in value.items:
        if not isinstance(item, int):
            raise TrapSig("expected byte array")
        out.append(item & 0xFF)
    return bytes(out)


def _argv(value: ArrayObj) -> list[bytes]:
    if not isinstance(value, ArrayObj):
        raise TrapSig("expected argv array")
    return [_bytes(item) for item in value.items]


def _opaque(value, type_id: tuple[str, ...], what: str):
    if not isinstance(value, OpaqueVal) or value.type_id != type_id:
        raise TrapSig(f"expected {what}")
    return value.payload


class LinuxHost:
    """Reference implementation of the Linux hosted FD/process profile.

    Descriptor values own their underlying descriptor and may be aliased as L
    values. Closing one alias closes the shared handle; later operations through
    another alias trap. Child values similarly identify one tracked process.
    """

    def __init__(self):
        self.fds: list[LinuxFd] = []
        self.children: list[LinuxChild] = []

    def _own_fd(self, fd: int) -> OpaqueVal:
        os.set_inheritable(fd, False)
        owned = LinuxFd(fd)
        self.fds.append(owned)
        return OpaqueVal(FD_TYPE, owned)

    def _fd(self, value) -> LinuxFd:
        fd = _opaque(value, FD_TYPE, "linux.fd.Fd")
        if not isinstance(fd, LinuxFd) or fd.closed:
            raise TrapSig("linux.fd.Fd is closed")
        return fd

    def _child(self, value) -> LinuxChild:
        child = _opaque(value, CHILD_TYPE, "linux.process.Child")
        if not isinstance(child, LinuxChild):
            raise TrapSig("invalid linux.process.Child")
        return child

    def _group(self, value) -> LinuxGroup:
        group = _opaque(value, GROUP_TYPE, "linux.process.Group")
        if not isinstance(group, LinuxGroup):
            raise TrapSig("invalid linux.process.Group")
        return group

    def _spawn_result(self, value) -> LinuxSpawnResult:
        result = _opaque(value, SPAWN_TYPE, "linux.process.SpawnResult")
        if not isinstance(result, LinuxSpawnResult):
            raise TrapSig("invalid linux.process.SpawnResult")
        return result

    def _status(self, value) -> LinuxExitStatus:
        status = _opaque(value, STATUS_TYPE, "linux.process.ExitStatus")
        if not isinstance(status, LinuxExitStatus):
            raise TrapSig("invalid linux.process.ExitStatus")
        return status

    # linux.fd

    def _dup_std(self, fd: int):
        return self._own_fd(os.dup(fd))

    def _dup(self, value):
        return self._own_fd(os.dup(self._fd(value).fd))

    def _pipe(self):
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
        return ArrayObj([self._own_fd(read_fd), self._own_fd(write_fd)])

    def _close(self, value):
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
        fd = self._fd(value).fd
        want = int(max_bytes)
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
        fd = self._fd(value).fd
        data = _bytes(data_value)
        while True:
            try:
                return os.write(fd, data)
            except InterruptedError:
                continue
            except OSError as exc:
                raise TrapSig(f"linux.fd.write failed: {exc}") from exc

    # linux.process

    def _spawn_exact(self, path_value, argv_value, stdin_value, stdout_value,
                     stderr_value, group_value):
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

        env = dict(os.environb)
        inherited_fds = [item.fd for item in self.fds if not item.closed]
        launch_read, launch_write = os.pipe2(os.O_CLOEXEC)

        pid = os.fork()
        if pid == 0:
            try:
                os.close(launch_read)
                os.setpgid(0, 0 if requested_group is None else requested_group)
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
                number = exc.errno if isinstance(exc, OSError) and exc.errno else errno.EIO
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
            return OpaqueVal(SPAWN_TYPE, LinuxSpawnResult(None, number))

        child = LinuxChild(pid=pid, pidfd=pidfd, pgid=pgid)
        self.children.append(child)
        return OpaqueVal(SPAWN_TYPE, LinuxSpawnResult(child, None))

    def _spawn_child(self, value):
        result = self._spawn_result(value)
        if result.child is None:
            return None
        return SomeVal(OpaqueVal(CHILD_TYPE, result.child))

    def _spawn_error(self, value):
        result = self._spawn_result(value)
        if result.error_number is None:
            return None
        return SomeVal(result.error_number)

    def _child_group(self, value):
        child = self._child(value)
        return OpaqueVal(GROUP_TYPE, LinuxGroup(child.pgid))

    def _wait_exit(self, value):
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
        status = self._status(value)
        return SomeVal(status.code) if status.exited else None

    def _term_signal(self, value):
        status = self._status(value)
        return None if status.exited else SomeVal(status.code)

    def fd_module(self) -> HostModule:
        host = HostModule(("linux", "fd"))
        fd_ty = host.opaque_type("Fd")
        bytes_ro = const_arr(name_ty("u8"))

        host.function("stdin", [], fd_ty, lambda: self._dup_std(0))
        host.function("stdout", [], fd_ty, lambda: self._dup_std(1))
        host.function("stderr", [], fd_ty, lambda: self._dup_std(2))
        host.function("dup", [fd_ty], fd_ty, self._dup)
        host.function("pipe", [], arr(fd_ty), self._pipe)
        host.function("close", [fd_ty], UNIT, self._close)
        host.function("read", [fd_ty, name_ty("u64")], opt(arr(name_ty("u8"))), self._read)
        host.function("write", [fd_ty, bytes_ro], name_ty("u64"), self._write)
        return host

    def process_module(self) -> HostModule:
        host = HostModule(("linux", "process"))
        fd_ty = name_ty(("__host__", "linux", "fd", "Fd"))
        child_ty = host.opaque_type("Child")
        group_ty = host.opaque_type("Group")
        spawn_ty = host.opaque_type("SpawnResult")
        status_ty = host.opaque_type("ExitStatus")
        bytes_ro = const_arr(name_ty("u8"))
        argv_ro = const_arr(bytes_ro)

        host.function(
            "spawn_exact",
            [bytes_ro, argv_ro, fd_ty, fd_ty, fd_ty, opt(group_ty)],
            spawn_ty,
            self._spawn_exact,
        )
        host.function("spawn_child", [spawn_ty], opt(child_ty), self._spawn_child)
        host.function("spawn_error", [spawn_ty], opt(name_ty("i64")), self._spawn_error)
        host.function("group", [child_ty], group_ty, self._child_group)
        host.function("wait_exit", [child_ty], status_ty, self._wait_exit)
        host.function("exit_code", [status_ty], opt(name_ty("i64")), self._exit_code)
        host.function("term_signal", [status_ty], opt(name_ty("i64")), self._term_signal)
        return host

    def modules(self) -> dict[tuple[str, ...], HostModule]:
        return {
            ("linux", "fd"): self.fd_module(),
            ("linux", "process"): self.process_module(),
        }

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
