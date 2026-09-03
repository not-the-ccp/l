from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{label}: expected one match, got {n}")
    p.write_text(s.replace(old, new, 1))


replace_once(
    "bootstrap/linux_host.py",
    '''        env = dict(os.environb)\n        inherited_fds = [item.fd for item in self.fds if not item.closed]\n        launch_read, launch_write = os.pipe2(os.O_CLOEXEC)\n''',
    '''        previous_foreground = None\n        if foreground_fd is not None:\n            try:\n                previous_foreground = os.tcgetpgrp(foreground_fd)\n            except OSError as exc:\n                return OpaqueVal(\n                    SPAWN_TYPE,\n                    LinuxSpawnResult(None, int(exc.errno or errno.EIO)),\n                )\n\n        env = dict(os.environb)\n        inherited_fds = [item.fd for item in self.fds if not item.closed]\n        launch_read, launch_write = os.pipe2(os.O_CLOEXEC)\n''',
    "python capture previous foreground",
)
replace_once(
    "bootstrap/linux_host.py",
    '''        try:\n            pidfd = os.pidfd_open(pid, 0)\n        except BaseException:\n            os.close(launch_read)\n            try:\n                os.kill(pid, signal.SIGKILL)\n            except ProcessLookupError:\n                pass\n            try:\n                os.waitpid(pid, 0)\n            except ChildProcessError:\n                pass\n            raise\n''',
    '''        try:\n            pidfd = os.pidfd_open(pid, 0)\n        except BaseException:\n            os.close(launch_read)\n            try:\n                os.kill(pid, signal.SIGKILL)\n            except ProcessLookupError:\n                pass\n            try:\n                os.waitpid(pid, 0)\n            except ChildProcessError:\n                pass\n            if previous_foreground is not None:\n                try:\n                    self._set_foreground_pgid(foreground_fd, previous_foreground)\n                except OSError:\n                    pass\n            raise\n''',
    "python rollback exceptional launch",
)
replace_once(
    "bootstrap/linux_host.py",
    '''        if payload:\n            number = struct.unpack("=i", payload.ljust(4, b"\\0")[:4])[0]\n            try:\n                os.waitid(os.P_PIDFD, pidfd, os.WEXITED)\n            except (ChildProcessError, OSError):\n                pass\n            os.close(pidfd)\n            return OpaqueVal(SPAWN_TYPE, LinuxSpawnResult(None, number))\n''',
    '''        if payload:\n            number = struct.unpack("=i", payload.ljust(4, b"\\0")[:4])[0]\n            try:\n                os.waitid(os.P_PIDFD, pidfd, os.WEXITED)\n            except (ChildProcessError, OSError):\n                pass\n            os.close(pidfd)\n            if previous_foreground is not None:\n                try:\n                    self._set_foreground_pgid(foreground_fd, previous_foreground)\n                except OSError:\n                    pass\n            return OpaqueVal(SPAWN_TYPE, LinuxSpawnResult(None, number))\n''',
    "python rollback failed exec",
)

replace_once(
    "runtime/linux_host_base.inc",
    '''    int launch[2];\n    if (linux_pipe_cloexec(launch) < 0) {\n''',
    '''    pid_t previous_foreground = -1;\n    if (foreground_fd >= 0) {\n        previous_foreground = tcgetpgrp(foreground_fd);\n        if (previous_foreground < 0) {\n            int e = errno ? errno : EIO;\n            free(path);\n            linux_free_argv(av, ac);\n            return linux_spawn_error_result(vm, e);\n        }\n    }\n\n    int launch[2];\n    if (linux_pipe_cloexec(launch) < 0) {\n''',
    "native capture previous foreground",
)
replace_once(
    "runtime/linux_host_base.inc",
    '''    if (got != 0) {\n        int number = EIO;\n        memcpy(&number, payload, got < sizeof(number) ? got : sizeof(number));\n        int st;\n        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}\n        return linux_spawn_error_result(vm, number);\n    }\n''',
    '''    if (got != 0) {\n        int number = EIO;\n        memcpy(&number, payload, got < sizeof(number) ? got : sizeof(number));\n        int st;\n        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}\n        if (previous_foreground >= 0)\n            (void)linux_tcsetpgrp_no_sigttou(foreground_fd, previous_foreground);\n        return linux_spawn_error_result(vm, number);\n    }\n''',
    "native rollback failed exec",
)

replace_once(
    "examples/hosted/linux_tty_job_probe.l",
    '''    var argv = ["cat"];\n    var child = child_or_trap(launch.foreground_exact(\n''',
    '''    // A failed foreground exec must be transactional with respect to tty\n    // ownership. PATH-style probing cannot leave the terminal attached to the\n    // short-lived failed child process group.\n    var missing_argv = ["definitely-missing-l-job-probe"];\n    var missing = launch.foreground_exact(\n        "/definitely/missing/l-job-probe", missing_argv, input, output, error, none, input\n    );\n    match (process.spawn_child(missing)) {\n        some(_) { trap; }\n        none {}\n    }\n    match (process.spawn_error(missing)) {\n        some(_) {}\n        none { trap; }\n    }\n    require(foreground_is(input, shell_group));\n\n    var argv = ["cat"];\n    var child = child_or_trap(launch.foreground_exact(\n''',
    "probe failed foreground launch rollback",
)
