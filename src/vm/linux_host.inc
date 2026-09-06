/* Composed Linux hosted profile.
 *
 * Keep the established descriptor/process/environment implementation intact in
 * linux_host_base.inc and layer process-state/controlling-terminal and signal
 * disposition operations on top. The generic native VM still sees one
 * linux_host_* dispatch surface.
 */

#define linux_host_id linux_base_host_id
#define linux_host_call linux_base_host_call
#define linux_host_cleanup linux_base_host_cleanup
#include "linux_host_base.inc"
#undef linux_host_id
#undef linux_host_call
#undef linux_host_cleanup

#include "linux_job_host.inc"
#include "linux_signal_host.inc"

static int linux_host_id(int id) {
    return linux_base_host_id(id) || linux_job_host_id(id) || linux_signal_host_id(id);
}

static LValue linux_host_call(LVM *vm, int id, LValue *args, int n) {
    if (linux_job_host_id(id)) return linux_job_host_call(vm, id, args, n);
    if (linux_signal_host_id(id)) return linux_signal_host_call(vm, id, args, n);
    return linux_base_host_call(vm, id, args, n);
}

static void linux_host_cleanup(LVM *vm) {
    // Job events retain pointers to base Child handles, so release events before
    // the base profile frees its opaque-handle registry.
    linux_signal_host_cleanup(vm);
    linux_job_host_cleanup(vm);
    linux_base_host_cleanup(vm);
}
