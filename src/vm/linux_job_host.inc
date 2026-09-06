/* Linux process-state and controlling-terminal hosted profile.
 *
 * Included from linux_host.inc after its opaque Child/Group/Fd definitions.
 * This models kernel state changes and terminal foreground ownership; it
 * contains no shell-job policy.
 */
#ifdef __linux__

enum {
    H_LINUX_GROUP_CURRENT = 56,
    H_LINUX_GROUP_BECOME_LEADER,
    H_LINUX_GROUP_SAME,
    H_LINUX_WAIT_CHILD,
    H_LINUX_WAIT_GROUP,
    H_LINUX_WAIT_POLL_GROUP,
    H_LINUX_WAIT_EVENT_CHILD,
    H_LINUX_WAIT_EXIT_CODE,
    H_LINUX_WAIT_TERM_SIGNAL,
    H_LINUX_WAIT_STOP_SIGNAL,
    H_LINUX_WAIT_CONTINUED,
    H_LINUX_TTY_IS_TTY,
    H_LINUX_TTY_FOREGROUND,
    H_LINUX_TTY_SET_FOREGROUND,
    H_LINUX_CHILD_SAME,
    H_LINUX_TTY_CAPTURE,
    H_LINUX_TTY_RESTORE,
    H_LINUX_LAUNCH_FOREGROUND_EXACT,
};

enum {
    LJ_EXITED = 1,
    LJ_SIGNALED,
    LJ_STOPPED,
    LJ_CONTINUED,
};

typedef struct LinuxJobEvent LinuxJobEvent;
struct LinuxJobEvent {
    LinuxOpaque *child;
    int kind;
    int code;
    LinuxJobEvent *next;
};

typedef struct LinuxTtyMode LinuxTtyMode;
struct LinuxTtyMode {
    struct termios attrs;
    LinuxTtyMode *next;
};

static LinuxJobEvent *g_linux_job_events = NULL;
static LinuxTtyMode *g_linux_tty_modes = NULL;

static LinuxJobEvent *linux_job_event_new(LinuxOpaque *child, int kind, int code) {
    LinuxJobEvent *event = calloc(1, sizeof(*event));
    if (!event) die("out of memory");
    event->child = child;
    event->kind = kind;
    event->code = code;
    event->next = g_linux_job_events;
    g_linux_job_events = event;
    return event;
}

static LinuxJobEvent *linux_job_event_as(LValue value) {
    if (value.tag != V_OPAQUE || !value.as.ptr)
        die("expected linux.process.wait.Event");
    for (LinuxJobEvent *event = g_linux_job_events; event; event = event->next)
        if ((void *)event == value.as.ptr) return event;
    die("invalid linux.process.wait.Event");
    return NULL;
}

static LinuxTtyMode *linux_tty_mode_new(const struct termios *attrs) {
    LinuxTtyMode *mode = calloc(1, sizeof(*mode));
    if (!mode) die("out of memory");
    mode->attrs = *attrs;
    mode->next = g_linux_tty_modes;
    g_linux_tty_modes = mode;
    return mode;
}

static LinuxTtyMode *linux_tty_mode_as(LValue value) {
    if (value.tag != V_OPAQUE || !value.as.ptr)
        die("expected linux.tty.Mode");
    for (LinuxTtyMode *mode = g_linux_tty_modes; mode; mode = mode->next)
        if ((void *)mode == value.as.ptr) return mode;
    die("invalid linux.tty.Mode");
    return NULL;
}

static LinuxOpaque *linux_job_find_child(pid_t pid) {
    for (LinuxOpaque *o = g_linux_opaques; o; o = o->next)
        if (o->kind == LX_CHILD && o->u.child.pid == pid) return o;
    die("wait returned an untracked child");
    return NULL;
}

static LValue linux_job_from_siginfo(LVM *vm, const siginfo_t *info) {
    LinuxOpaque *child = linux_job_find_child((pid_t)info->si_pid);
    int kind;
    int code = info->si_status;
    if (info->si_code == CLD_EXITED) {
        kind = LJ_EXITED;
    } else if (info->si_code == CLD_KILLED || info->si_code == CLD_DUMPED) {
        kind = LJ_SIGNALED;
    } else if (info->si_code == CLD_STOPPED) {
        kind = LJ_STOPPED;
    } else if (info->si_code == CLD_CONTINUED) {
        kind = LJ_CONTINUED;
        code = 0;
    } else {
        die("unsupported child state from waitid");
    }

    if (kind == LJ_EXITED || kind == LJ_SIGNALED) {
        child->u.child.waited = 1;
        if (child->u.child.pidfd >= 0) {
            close(child->u.child.pidfd);
            child->u.child.pidfd = -1;
        }
    }
    return v_opaque(linux_job_event_new(child, kind, code));
}

static LValue linux_job_waitid(LVM *vm, idtype_t type, id_t id, int nonblocking) {
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    int options = WEXITED | WSTOPPED | WCONTINUED;
    if (nonblocking) options |= WNOHANG;
    int rc;
    do {
        rc = waitid(type, id, &info, options);
    } while (rc < 0 && errno == EINTR);
    if (rc < 0) die("linux.process.wait failed: %s", strerror(errno));
    if (nonblocking && info.si_pid == 0) return v_none();
    if (info.si_pid == 0) die("blocking wait returned no event");
    return linux_job_from_siginfo(vm, &info);
}

static LValue linux_job_optional_event(LVM *vm, LValue value) {
    if (value.tag == V_NONE) return value;
    return linux_some(vm, value);
}

static LValue linux_job_host_call(LVM *vm, int id, LValue *args, int n) {
    switch (id) {
    case H_LINUX_GROUP_CURRENT: {
        if (n != 0) die("linux.process.group.current arity");
        LinuxOpaque *group = linux_new(vm, LX_GROUP);
        group->u.group.pgid = getpgrp();
        return v_opaque(group);
    }
    case H_LINUX_GROUP_BECOME_LEADER: {
        if (n != 0) die("linux.process.group.become_leader arity");
        errno = 0;
        return linux_errno_optional(vm, setpgid(0, 0));
    }
    case H_LINUX_GROUP_SAME: {
        if (n != 2) die("linux.process.group.same arity");
        LinuxOpaque *a = linux_as(args[0], LX_GROUP, "linux.process.Group");
        LinuxOpaque *b = linux_as(args[1], LX_GROUP, "linux.process.Group");
        return v_bool(a->u.group.pgid == b->u.group.pgid);
    }
    case H_LINUX_CHILD_SAME: {
        if (n != 2) die("linux.process.child.same arity");
        LinuxOpaque *a = linux_as(args[0], LX_CHILD, "linux.process.Child");
        LinuxOpaque *b = linux_as(args[1], LX_CHILD, "linux.process.Child");
        return v_bool(a == b);
    }
    case H_LINUX_WAIT_CHILD: {
        if (n != 1) die("linux.process.wait.child arity");
        LinuxOpaque *child = linux_as(args[0], LX_CHILD, "linux.process.Child");
        if (child->u.child.waited) die("linux.process.Child was already reaped");
        if (child->u.child.pidfd >= 0)
            return linux_job_waitid(vm, (idtype_t)P_PIDFD, (id_t)child->u.child.pidfd, 0);
        return linux_job_waitid(vm, P_PID, (id_t)child->u.child.pid, 0);
    }
    case H_LINUX_WAIT_GROUP:
    case H_LINUX_WAIT_POLL_GROUP: {
        if (n != 1) die("linux.process.wait group arity");
        LinuxOpaque *group = linux_as(args[0], LX_GROUP, "linux.process.Group");
        LValue value = linux_job_waitid(vm, P_PGID, (id_t)group->u.group.pgid,
                                        id == H_LINUX_WAIT_POLL_GROUP);
        if (id == H_LINUX_WAIT_POLL_GROUP) return linux_job_optional_event(vm, value);
        return value;
    }
    case H_LINUX_WAIT_EVENT_CHILD: {
        if (n != 1) die("linux.process.wait.event_child arity");
        return v_opaque(linux_job_event_as(args[0])->child);
    }
    case H_LINUX_WAIT_EXIT_CODE:
    case H_LINUX_WAIT_TERM_SIGNAL:
    case H_LINUX_WAIT_STOP_SIGNAL: {
        if (n != 1) die("linux.process.wait event accessor arity");
        LinuxJobEvent *event = linux_job_event_as(args[0]);
        int wanted = id == H_LINUX_WAIT_EXIT_CODE ? LJ_EXITED
            : id == H_LINUX_WAIT_TERM_SIGNAL ? LJ_SIGNALED : LJ_STOPPED;
        if (event->kind != wanted) return v_none();
        return linux_some(vm, v_int((uint64_t)(int64_t)event->code));
    }
    case H_LINUX_WAIT_CONTINUED: {
        if (n != 1) die("linux.process.wait.continued arity");
        return v_bool(linux_job_event_as(args[0])->kind == LJ_CONTINUED);
    }
    case H_LINUX_TTY_IS_TTY: {
        if (n != 1) die("linux.tty.is_tty arity");
        LinuxOpaque *fd = linux_fd_open_handle(args[0]);
        return v_bool(isatty(fd->u.fd.fd));
    }
    case H_LINUX_TTY_FOREGROUND: {
        if (n != 1) die("linux.tty.foreground arity");
        LinuxOpaque *fd = linux_fd_open_handle(args[0]);
        pid_t pgid = tcgetpgrp(fd->u.fd.fd);
        if (pgid < 0) return v_none();
        LinuxOpaque *group = linux_new(vm, LX_GROUP);
        group->u.group.pgid = pgid;
        return linux_some(vm, v_opaque(group));
    }
    case H_LINUX_TTY_SET_FOREGROUND: {
        if (n != 2) die("linux.tty.set_foreground arity");
        LinuxOpaque *fd = linux_fd_open_handle(args[0]);
        LinuxOpaque *group = linux_as(args[1], LX_GROUP, "linux.process.Group");
        return linux_errno_optional(vm,
            linux_tcsetpgrp_no_sigttou(fd->u.fd.fd, group->u.group.pgid));
    }
    case H_LINUX_LAUNCH_FOREGROUND_EXACT: {
        if (n != 7) die("linux.process.launch.foreground_exact arity");
        LinuxOpaque *terminal = linux_fd_open_handle(args[6]);
        return linux_spawn_exact_impl(vm, args, 6, terminal->u.fd.fd);
    }
    case H_LINUX_TTY_CAPTURE: {
        if (n != 1) die("linux.tty.capture arity");
        LinuxOpaque *fd = linux_fd_open_handle(args[0]);
        struct termios attrs;
        if (tcgetattr(fd->u.fd.fd, &attrs) < 0) return v_none();
        return linux_some(vm, v_opaque(linux_tty_mode_new(&attrs)));
    }
    case H_LINUX_TTY_RESTORE: {
        if (n != 2) die("linux.tty.restore arity");
        LinuxOpaque *fd = linux_fd_open_handle(args[0]);
        LinuxTtyMode *mode = linux_tty_mode_as(args[1]);
        errno = 0;
        return linux_errno_optional(vm, tcsetattr(fd->u.fd.fd, TCSADRAIN, &mode->attrs));
    }
    }
    die("unknown Linux job-control host function %d", id);
    return v_unit();
}

static int linux_job_host_id(int id) {
    return id >= H_LINUX_GROUP_CURRENT && id <= H_LINUX_LAUNCH_FOREGROUND_EXACT;
}

static void linux_job_host_cleanup(LVM *vm) {
    (void)vm;
    while (g_linux_job_events) {
        LinuxJobEvent *next = g_linux_job_events->next;
        free(g_linux_job_events);
        g_linux_job_events = next;
    }
    while (g_linux_tty_modes) {
        LinuxTtyMode *next = g_linux_tty_modes->next;
        free(g_linux_tty_modes);
        g_linux_tty_modes = next;
    }
}

#else

static int linux_job_host_id(int id) { (void)id; return 0; }
static LValue linux_job_host_call(LVM *vm, int id, LValue *args, int n) {
    (void)vm; (void)id; (void)args; (void)n;
    die("Linux job-control host profile is unavailable on this platform");
    return v_unit();
}
static void linux_job_host_cleanup(LVM *vm) { (void)vm; }

#endif
