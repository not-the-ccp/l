/* Linux-only hosted profile used by native L executables.
 *
 * Native host IDs 25..39 are reserved by bootstrap/native_compile.py. Keeping
 * their implementation here avoids teaching the portable VM representation
 * about Linux descriptor/process internals. The native runtime already permits
 * only one active LVM per process (g_vm); this profile follows the same model
 * and owns opaque handles until lvm_run teardown so copied L values cannot
 * dangle.
 */
#ifdef __linux__

#include <sys/syscall.h>
/* syscall() can be hidden by feature-test macros even though the symbol is
 * supplied by libc. Keep the declaration local to this Linux-only profile. */
extern long syscall(long number, ...);

#ifndef P_PIDFD
#define P_PIDFD 3
#endif

enum {
    H_LINUX_FD_STDIN = 25,
    H_LINUX_FD_STDOUT,
    H_LINUX_FD_STDERR,
    H_LINUX_FD_DUP,
    H_LINUX_FD_PIPE,
    H_LINUX_FD_CLOSE,
    H_LINUX_FD_READ,
    H_LINUX_FD_WRITE,
    H_LINUX_PROCESS_SPAWN_EXACT,
    H_LINUX_PROCESS_SPAWN_CHILD,
    H_LINUX_PROCESS_SPAWN_ERROR,
    H_LINUX_PROCESS_GROUP,
    H_LINUX_PROCESS_WAIT_EXIT,
    H_LINUX_PROCESS_EXIT_CODE,
    H_LINUX_PROCESS_TERM_SIGNAL,
};

enum {
    LX_FD = 1,
    LX_CHILD,
    LX_GROUP,
    LX_SPAWN_RESULT,
    LX_EXIT_STATUS,
};

typedef struct LinuxOpaque LinuxOpaque;
struct LinuxOpaque {
    int kind;
    LinuxOpaque *next;
    union {
        struct {
            int fd;
            int closed;
        } fd;
        struct {
            pid_t pid;
            int pidfd;
            pid_t pgid;
            int waited;
        } child;
        struct {
            pid_t pgid;
        } group;
        struct {
            LinuxOpaque *child;
            int has_error;
            int error_number;
        } spawn;
        struct {
            int exited;
            int code;
        } status;
    } u;
};

static LinuxOpaque *g_linux_opaques = NULL;

static LinuxOpaque *linux_new(LVM *vm, int kind) {
    (void)vm;
    LinuxOpaque *o = calloc(1, sizeof(*o));
    if (!o) die("out of memory");
    o->kind = kind;
    o->next = g_linux_opaques;
    g_linux_opaques = o;
    return o;
}

static LinuxOpaque *linux_as(LValue v, int kind, const char *what) {
    if (v.tag != V_OPAQUE || !v.as.ptr) die("expected %s", what);
    LinuxOpaque *o = (LinuxOpaque *)v.as.ptr;
    if (o->kind != kind) die("expected %s", what);
    return o;
}

static LinuxOpaque *linux_fd_open_handle(LValue v) {
    LinuxOpaque *o = linux_as(v, LX_FD, "linux.fd.Fd");
    if (o->u.fd.closed) die("linux.fd.Fd is closed");
    return o;
}

static LValue linux_some(LVM *vm, LValue value) {
    LObj *s = obj_new(vm, O_SOME);
    s->u.some.value = value_copy(vm, value);
    return v_obj(s);
}

static int linux_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static LinuxOpaque *linux_own_fd(LVM *vm, int fd) {
    if (linux_set_cloexec(fd) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        die("linux.fd: failed to set close-on-exec: %s", strerror(errno));
    }
    LinuxOpaque *o = linux_new(vm, LX_FD);
    o->u.fd.fd = fd;
    return o;
}

static int linux_pipe_cloexec(int ends[2]) {
    if (pipe(ends) < 0) return -1;
    if (linux_set_cloexec(ends[0]) < 0 || linux_set_cloexec(ends[1]) < 0) {
        int e = errno;
        close(ends[0]);
        close(ends[1]);
        errno = e;
        return -1;
    }
    return 0;
}

static int linux_bytes_has_nul(LValue v) {
    if (v.tag != V_OBJ || v.as.obj->kind != O_ARRAY) die("expected []u8");
    LObj *a = v.as.obj;
    for (size_t i = 0; i < a->u.array.len; i++)
        if ((a->u.array.items[i].as.u & 255) == 0) return 1;
    return 0;
}

static void linux_free_argv(char **av, size_t n) {
    if (!av) return;
    for (size_t i = 0; i < n; i++) free(av[i]);
    free(av);
}

static LValue linux_spawn_error_result(LVM *vm, int number) {
    LinuxOpaque *r = linux_new(vm, LX_SPAWN_RESULT);
    r->u.spawn.has_error = 1;
    r->u.spawn.error_number = number;
    return v_opaque(r);
}

static void linux_child_report_errno(int fd, int number) {
    const unsigned char *p = (const unsigned char *)&number;
    size_t off = 0;
    while (off < sizeof(number)) {
        ssize_t z = write(fd, p + off, sizeof(number) - off);
        if (z < 0 && errno == EINTR) continue;
        if (z <= 0) break;
        off += (size_t)z;
    }
}

static void linux_child_close_inherited(LVM *vm, int keep_fd) {
    (void)vm;
    for (LinuxOpaque *o = g_linux_opaques; o; o = o->next) {
        if (o->kind != LX_FD || o->u.fd.closed) continue;
        int fd = o->u.fd.fd;
        if (fd > 2 && fd != keep_fd) (void)close(fd);
    }
    for (Proc *p = g_vm ? g_vm->procs : NULL; p; p = p->next) {
        if (p->in_fd > 2 && p->in_fd != keep_fd) (void)close(p->in_fd);
        if (p->out_fd > 2 && p->out_fd != keep_fd) (void)close(p->out_fd);
    }
}

static int linux_pidfd_open(pid_t pid) {
#ifdef SYS_pidfd_open
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    (void)pid;
    errno = ENOSYS;
    return -1;
#endif
}

static void linux_pidfd_kill(int pidfd, pid_t pid) {
#ifdef SYS_pidfd_send_signal
    if (pidfd >= 0 && syscall(SYS_pidfd_send_signal, pidfd, SIGKILL, NULL, 0) == 0)
        return;
#endif
    (void)kill(pid, SIGKILL);
}

static LValue linux_host_call(LVM *vm, int id, LValue *args, int n) {
    switch (id) {
    case H_LINUX_FD_STDIN:
    case H_LINUX_FD_STDOUT:
    case H_LINUX_FD_STDERR: {
        if (n != 0) die("linux.fd standard stream arity");
        int src = id == H_LINUX_FD_STDIN ? 0 : id == H_LINUX_FD_STDOUT ? 1 : 2;
        int d = dup(src);
        if (d < 0) die("linux.fd standard stream dup failed: %s", strerror(errno));
        return v_opaque(linux_own_fd(vm, d));
    }
    case H_LINUX_FD_DUP: {
        if (n != 1) die("linux.fd.dup arity");
        LinuxOpaque *src = linux_fd_open_handle(args[0]);
        int d = dup(src->u.fd.fd);
        if (d < 0) die("linux.fd.dup failed: %s", strerror(errno));
        return v_opaque(linux_own_fd(vm, d));
    }
    case H_LINUX_FD_PIPE: {
        if (n != 0) die("linux.fd.pipe arity");
        int ends[2];
        if (linux_pipe_cloexec(ends) < 0)
            die("linux.fd.pipe failed: %s", strerror(errno));
        LObj *out = new_array(vm, 2);
        out->u.array.items[0] = v_opaque(linux_own_fd(vm, ends[0]));
        out->u.array.items[1] = v_opaque(linux_own_fd(vm, ends[1]));
        return v_obj(out);
    }
    case H_LINUX_FD_CLOSE: {
        if (n != 1) die("linux.fd.close arity");
        LinuxOpaque *fd = linux_as(args[0], LX_FD, "linux.fd.Fd");
        if (!fd->u.fd.closed) {
            if (close(fd->u.fd.fd) < 0 && errno != EBADF)
                die("linux.fd.close failed: %s", strerror(errno));
            fd->u.fd.closed = 1;
            fd->u.fd.fd = -1;
        }
        return v_unit();
    }
    case H_LINUX_FD_READ: {
        if (n != 2) die("linux.fd.read arity");
        LinuxOpaque *fd = linux_fd_open_handle(args[0]);
        uint64_t requested = args[1].as.u;
        if (requested > (uint64_t)SIZE_MAX) die("linux.fd.read size is too large");
        size_t want = (size_t)requested;
        if (want == 0) return linux_some(vm, host_bytes(vm, NULL, 0));
        unsigned char *buf = xmalloc(want);
        ssize_t z;
        do {
            z = read(fd->u.fd.fd, buf, want);
        } while (z < 0 && errno == EINTR);
        if (z < 0) {
            int e = errno;
            free(buf);
            die("linux.fd.read failed: %s", strerror(e));
        }
        if (z == 0) {
            free(buf);
            return v_none();
        }
        LValue out = linux_some(vm, host_bytes(vm, buf, (size_t)z));
        free(buf);
        return out;
    }
    case H_LINUX_FD_WRITE: {
        if (n != 2) die("linux.fd.write arity");
        LinuxOpaque *fd = linux_fd_open_handle(args[0]);
        if (args[1].tag != V_OBJ || args[1].as.obj->kind != O_ARRAY)
            die("linux.fd.write expected []u8");
        LObj *a = args[1].as.obj;
        if (a->u.array.len == 0) return v_int(0);
        unsigned char *buf = xmalloc(a->u.array.len);
        for (size_t i = 0; i < a->u.array.len; i++)
            buf[i] = (unsigned char)(a->u.array.items[i].as.u & 255);
        ssize_t z;
        do {
            z = write(fd->u.fd.fd, buf, a->u.array.len);
        } while (z < 0 && errno == EINTR);
        if (z < 0) {
            int e = errno;
            free(buf);
            die("linux.fd.write failed: %s", strerror(e));
        }
        free(buf);
        return v_int((uint64_t)z);
    }
    case H_LINUX_PROCESS_SPAWN_EXACT: {
        if (n != 6) die("linux.process.spawn_exact arity");
        if (args[0].tag != V_OBJ || args[0].as.obj->kind != O_ARRAY ||
            args[0].as.obj->u.array.len == 0 || linux_bytes_has_nul(args[0]))
            die("linux.process.spawn_exact requires a nonempty NUL-free path");
        if (args[1].tag != V_OBJ || args[1].as.obj->kind != O_ARRAY ||
            args[1].as.obj->u.array.len == 0)
            die("linux.process.spawn_exact requires a nonempty argv");

        char *path = array_cstr(args[0]);
        LObj *aa = args[1].as.obj;
        size_t ac = aa->u.array.len;
        char **av = xmalloc((ac + 1) * sizeof(char *));
        for (size_t i = 0; i < ac; i++) {
            if (linux_bytes_has_nul(aa->u.array.items[i])) {
                free(path);
                linux_free_argv(av, i);
                die("linux.process.spawn_exact argv contains NUL");
            }
            av[i] = array_cstr(aa->u.array.items[i]);
        }
        av[ac] = NULL;

        int in_fd = linux_fd_open_handle(args[2])->u.fd.fd;
        int out_fd = linux_fd_open_handle(args[3])->u.fd.fd;
        int err_fd = linux_fd_open_handle(args[4])->u.fd.fd;
        int has_group = 0;
        pid_t requested_group = 0;
        if (args[5].tag == V_OBJ && args[5].as.obj->kind == O_SOME) {
            LValue gv = args[5].as.obj->u.some.value;
            LinuxOpaque *g = linux_as(gv, LX_GROUP, "linux.process.Group");
            has_group = 1;
            requested_group = g->u.group.pgid;
        } else if (args[5].tag != V_NONE) {
            free(path);
            linux_free_argv(av, ac);
            die("invalid optional linux.process.Group");
        }

        int launch[2];
        if (linux_pipe_cloexec(launch) < 0) {
            int e = errno;
            free(path);
            linux_free_argv(av, ac);
            die("linux.process.spawn_exact launch pipe failed: %s", strerror(e));
        }

        pid_t pid = fork();
        if (pid < 0) {
            int e = errno;
            close(launch[0]);
            close(launch[1]);
            free(path);
            linux_free_argv(av, ac);
            return linux_spawn_error_result(vm, e);
        }
        if (pid == 0) {
            close(launch[0]);
            if (setpgid(0, has_group ? requested_group : 0) < 0) {
                linux_child_report_errno(launch[1], errno);
                _exit(127);
            }
            if (dup2(in_fd, 0) < 0 || dup2(out_fd, 1) < 0 || dup2(err_fd, 2) < 0) {
                linux_child_report_errno(launch[1], errno);
                _exit(127);
            }
            linux_child_close_inherited(vm, launch[1]);
            signal(SIGINT, SIG_DFL);
            signal(SIGQUIT, SIG_DFL);
            signal(SIGTSTP, SIG_DFL);
            signal(SIGTTIN, SIG_DFL);
            signal(SIGTTOU, SIG_DFL);
            signal(SIGPIPE, SIG_DFL);
            extern char **environ;
            execve(path, av, environ);
            linux_child_report_errno(launch[1], errno ? errno : EIO);
            _exit(127);
        }

        close(launch[1]);
        pid_t pgid = has_group ? requested_group : pid;
        if (setpgid(pid, pgid) < 0 && errno != EACCES && errno != ESRCH) {
            /* The child is authoritative and reports setup failure through the
             * launch pipe. Parent-side setpgid is only the usual race closer. */
        }

        unsigned char payload[sizeof(int)] = {0};
        size_t got = 0;
        while (got < sizeof(payload)) {
            ssize_t z = read(launch[0], payload + got, sizeof(payload) - got);
            if (z < 0 && errno == EINTR) continue;
            if (z <= 0) break;
            got += (size_t)z;
        }
        close(launch[0]);
        free(path);
        linux_free_argv(av, ac);

        if (got != 0) {
            int number = EIO;
            memcpy(&number, payload, got < sizeof(number) ? got : sizeof(number));
            int st;
            while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
            return linux_spawn_error_result(vm, number);
        }

        LinuxOpaque *child = linux_new(vm, LX_CHILD);
        child->u.child.pid = pid;
        child->u.child.pgid = pgid;
        child->u.child.pidfd = linux_pidfd_open(pid);
        if (child->u.child.pidfd < 0 && errno != ENOSYS && errno != EINVAL) {
            /* pidfd is an implementation aid, not part of the L contract. */
            child->u.child.pidfd = -1;
        }
        LinuxOpaque *result = linux_new(vm, LX_SPAWN_RESULT);
        result->u.spawn.child = child;
        return v_opaque(result);
    }
    case H_LINUX_PROCESS_SPAWN_CHILD: {
        if (n != 1) die("linux.process.spawn_child arity");
        LinuxOpaque *r = linux_as(args[0], LX_SPAWN_RESULT, "linux.process.SpawnResult");
        if (!r->u.spawn.child) return v_none();
        return linux_some(vm, v_opaque(r->u.spawn.child));
    }
    case H_LINUX_PROCESS_SPAWN_ERROR: {
        if (n != 1) die("linux.process.spawn_error arity");
        LinuxOpaque *r = linux_as(args[0], LX_SPAWN_RESULT, "linux.process.SpawnResult");
        if (!r->u.spawn.has_error) return v_none();
        return linux_some(vm, v_int((uint64_t)(int64_t)r->u.spawn.error_number));
    }
    case H_LINUX_PROCESS_GROUP: {
        if (n != 1) die("linux.process.group arity");
        LinuxOpaque *child = linux_as(args[0], LX_CHILD, "linux.process.Child");
        LinuxOpaque *group = linux_new(vm, LX_GROUP);
        group->u.group.pgid = child->u.child.pgid;
        return v_opaque(group);
    }
    case H_LINUX_PROCESS_WAIT_EXIT: {
        if (n != 1) die("linux.process.wait_exit arity");
        LinuxOpaque *child = linux_as(args[0], LX_CHILD, "linux.process.Child");
        if (child->u.child.waited) die("linux.process.Child was already waited");

        LinuxOpaque *status = linux_new(vm, LX_EXIT_STATUS);
        if (child->u.child.pidfd >= 0) {
            siginfo_t info;
            memset(&info, 0, sizeof(info));
            int rc;
            do {
                rc = waitid((idtype_t)P_PIDFD, (id_t)child->u.child.pidfd, &info, WEXITED);
            } while (rc < 0 && errno == EINTR);
            if (rc < 0) die("linux.process.wait_exit failed: %s", strerror(errno));
            if (info.si_code == CLD_EXITED) {
                status->u.status.exited = 1;
                status->u.status.code = info.si_status;
            } else if (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED) {
                status->u.status.code = info.si_status;
            } else {
                die("linux.process.wait_exit received a nonterminal state");
            }
            close(child->u.child.pidfd);
            child->u.child.pidfd = -1;
        } else {
            int st;
            pid_t r;
            do {
                r = waitpid(child->u.child.pid, &st, 0);
            } while (r < 0 && errno == EINTR);
            if (r < 0) die("linux.process.wait_exit failed: %s", strerror(errno));
            if (WIFEXITED(st)) {
                status->u.status.exited = 1;
                status->u.status.code = WEXITSTATUS(st);
            } else if (WIFSIGNALED(st)) {
                status->u.status.code = WTERMSIG(st);
            } else {
                die("linux.process.wait_exit received a nonterminal state");
            }
        }
        child->u.child.waited = 1;
        return v_opaque(status);
    }
    case H_LINUX_PROCESS_EXIT_CODE:
    case H_LINUX_PROCESS_TERM_SIGNAL: {
        if (n != 1) die("linux.process status accessor arity");
        LinuxOpaque *status = linux_as(args[0], LX_EXIT_STATUS, "linux.process.ExitStatus");
        int want_exit = id == H_LINUX_PROCESS_EXIT_CODE;
        if (status->u.status.exited != want_exit) return v_none();
        return linux_some(vm, v_int((uint64_t)(int64_t)status->u.status.code));
    }
    }
    die("unknown Linux host function %d", id);
    return v_unit();
}

static void linux_host_cleanup(LVM *vm) {
    (void)vm;
    for (LinuxOpaque *o = g_linux_opaques; o; o = o->next) {
        if (o->kind == LX_FD && !o->u.fd.closed) {
            (void)close(o->u.fd.fd);
            o->u.fd.closed = 1;
            o->u.fd.fd = -1;
        } else if (o->kind == LX_CHILD && !o->u.child.waited) {
            linux_pidfd_kill(o->u.child.pidfd, o->u.child.pid);
            if (o->u.child.pidfd >= 0) {
                siginfo_t info;
                while (waitid((idtype_t)P_PIDFD, (id_t)o->u.child.pidfd, &info, WEXITED) < 0 && errno == EINTR) {}
                close(o->u.child.pidfd);
                o->u.child.pidfd = -1;
            } else {
                int st;
                while (waitpid(o->u.child.pid, &st, 0) < 0 && errno == EINTR) {}
            }
            o->u.child.waited = 1;
        }
    }
    while (g_linux_opaques) {
        LinuxOpaque *next = g_linux_opaques->next;
        free(g_linux_opaques);
        g_linux_opaques = next;
    }
}

#else

/* Keep native_vm.c's dispatch hook linkable on non-Linux builds. */
static int linux_host_id(int id) { (void)id; return 0; }
static LValue linux_host_call(LVM *vm, int id, LValue *args, int n) {
    (void)vm; (void)id; (void)args; (void)n;
    die("Linux host profile is unavailable on this platform");
    return v_unit();
}
static void linux_host_cleanup(LVM *vm) { (void)vm; }

#endif

#ifdef __linux__
static int linux_host_id(int id) {
    return id >= H_LINUX_FD_STDIN && id <= H_LINUX_PROCESS_TERM_SIGNAL;
}
#endif
