/* Feature macros must precede every system header in this translation
 * unit (including via embed.h); otherwise glibc locks _GNU_SOURCE off
 * before vm.c is reached. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#define _GNU_SOURCE
#include "embed.h"

#include <string.h>

/* Keep the standalone VM implementation authoritative for now. Including it in
 * this translation unit lets the embedding layer reuse the exact same VM state,
 * GC, host modules and cleanup paths without exposing those internals as ABI. */
#include "vm.c"

struct LVMContext {
    LVM vm;
};

static int embed_status(LValue value) {
    if (value.tag == V_INT) return (int)(value.as.u & 255);
    if (value.tag == V_BOOL) return value.as.u ? 0 : 1;
    return 0;
}

LVMContext *lvm_context_create(const LProgram *program, int argc, char **argv) {
    if (!program || g_vm) return NULL;

    LVMContext *context = calloc(1, sizeof(*context));
    if (!context) return NULL;

    setlocale(LC_CTYPE, "");
    context->vm.p = program;
    context->vm.argc = argc;
    context->vm.argv = argv;
    context->vm.gc_threshold = 4096;
    vm_stack_note(&context->vm);

    g_vm = &context->vm;
    install_runtime_cleanup();
    return context;
}

int lvm_context_invoke_entry(LVMContext *context, int *exit_status) {
    if (!context || !exit_status || g_vm != &context->vm) return 0;

    LVM *vm = &context->vm;
    if (vm->frame || vm->sp || vm->pending_len || vm->has_match) return 0;
    vm_stack_note(vm);

    LValue result = vm_call(vm, vm->p->entry_function, NULL, 0);

    /* A normal top-level return must leave no transient interpreter state. Keep
     * this boundary strict so future trap recovery has an explicit clean state
     * to restore to rather than inheriting accidental pending bindings/matches. */
    if (vm->frame || vm->sp) die("embedded invocation leaked frame/stack state");
    pending_clear(vm);
    vm->has_match = 0;
    vm->match_value = v_unit();

    *exit_status = embed_status(result);
    return 1;
}

int lvm_context_find_function(LVMContext *context, const char *name) {
    if (!context || !name || g_vm != &context->vm) return -1;
    const LProgram *p = context->vm.p;
    for (int i = 0; i < p->function_count; i++) {
        int id = p->functions[i].name;
        if (id >= 0 && id < p->string_count && p->strings[id] &&
            strcmp(p->strings[id], name) == 0)
            return i;
    }
    return -1;
}

int lvm_context_call_function(LVMContext *context, int fid, int *status,
                              char *message, size_t message_size) {
    if (!context || !status || g_vm != &context->vm) return LVM_CALL_USAGE;
    LVM *vm = &context->vm;
    if (fid < 0 || fid >= vm->p->function_count) return LVM_CALL_USAGE;
    if (vm->p->functions[fid].param_count != 0) return LVM_CALL_USAGE;
    vm_stack_note(vm);

    /* Snapshot every recoverable dimension at entry. Nested boundaries link
     * through prev; an inner trap reports to the inner caller while the
     * outer snapshot stays armed underneath. */
    LRecovery boundary;
    memset(&boundary, 0, sizeof(boundary));
    boundary.prev = vm->recovery;
    boundary.frame_boundary = vm->frame;
    boundary.sp = vm->sp;
    boundary.pending_len = vm->pending_len;
    boundary.match_value = vm->match_value;
    boundary.has_match = vm->has_match;
    boundary.saved_term = vm->saved_term;
    boundary.term_raw = vm->term_raw;
    boundary.term_screen = vm->term_screen;
    memcpy(boundary.key_pushback, vm->key_pushback,
           sizeof(boundary.key_pushback));
    boundary.key_pushback_len = vm->key_pushback_len;
    boundary.proc_checkpoint = vm->procs;
    boundary.opaque_checkpoint = linux_host_checkpoint_opaque();
    boundary.job_event_checkpoint = linux_host_checkpoint_events();
    boundary.tty_mode_checkpoint = linux_host_checkpoint_modes();
    boundary.cleanup_checkpoint = vm->cleanups;
    boundary.depth_checkpoint = vm->depth;
    vm->recovery = &boundary;

    if (setjmp(boundary.env) == 0) {
        LValue result = vm_call(vm, fid, NULL, 0);
        vm->recovery = boundary.prev;
        /* A normal callback return must leave no transient interpreter
         * state behind, mirroring the entry boundary above. */
        if (vm->frame != boundary.frame_boundary || vm->sp != boundary.sp) {
            pending_clear(vm);
            vm->has_match = 0;
            vm->match_value = v_unit();
            return LVM_CALL_USAGE;
        }
        vm->pending_len = boundary.pending_len;
        vm->has_match = boundary.has_match;
        vm->match_value = boundary.match_value;
        gc_collect(vm);
        *status = embed_status(result);
        return LVM_CALL_OK;
    }

    /* Contained trap: die() already restored frames, stack top, bindings,
     * match state, native handles, and terminal state. Reclaim unreachable
     * heap garbage from the failed call, then hand control back to the
     * host with the diagnostic. The VM stays usable. */
    vm->recovery = boundary.prev;
    pending_clear(vm);
    vm->has_match = 0;
    vm->match_value = v_unit();
    gc_collect(vm);
    if (message && message_size) snprintf(message, message_size, "%s",
                                          boundary.msg);
    return LVM_CALL_TRAP;
}

void lvm_context_destroy(LVMContext *context) {
    if (!context) return;
    if (g_vm != &context->vm) return;

    vm_cleanup(&context->vm);
    g_vm = NULL;
    free(context);
}
