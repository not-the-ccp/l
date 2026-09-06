/* Linux process signal-disposition hosted profile.
 *
 * Kept separate from process spawning/job policy so other hosted L programs can
 * deliberately choose process-global dispositions without exposing raw sigaction.
 */
#ifdef __linux__

enum {
    H_LINUX_SIGNAL_IGNORE = 74,
    H_LINUX_SIGNAL_DEFAULT,
};

static LValue linux_signal_host_call(LVM *vm, int id, LValue *args, int n) {
    if (n != 1) die("linux.process.signal disposition arity");
    int signo = (int)(int64_t)args[0].as.u;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = id == H_LINUX_SIGNAL_IGNORE ? SIG_IGN : SIG_DFL;
    if (sigemptyset(&action.sa_mask) < 0)
        return linux_errno_optional(vm, -1);
    errno = 0;
    return linux_errno_optional(vm, sigaction(signo, &action, NULL));
}

static int linux_signal_host_id(int id) {
    return id == H_LINUX_SIGNAL_IGNORE || id == H_LINUX_SIGNAL_DEFAULT;
}

static void linux_signal_host_cleanup(LVM *vm) { (void)vm; }

#else

static int linux_signal_host_id(int id) { (void)id; return 0; }
static LValue linux_signal_host_call(LVM *vm, int id, LValue *args, int n) {
    (void)vm; (void)id; (void)args; (void)n;
    die("Linux signal-disposition host profile is unavailable on this platform");
    return v_unit();
}
static void linux_signal_host_cleanup(LVM *vm) { (void)vm; }

#endif
