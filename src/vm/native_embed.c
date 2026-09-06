#include "native_embed.h"

/* Keep the standalone VM implementation authoritative for now. Including it in
 * this translation unit lets the embedding layer reuse the exact same VM state,
 * GC, host modules and cleanup paths without exposing those internals as ABI. */
#include "native_vm.c"

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

    g_vm = &context->vm;
    install_runtime_cleanup();
    return context;
}

int lvm_context_invoke_entry(LVMContext *context, int *exit_status) {
    if (!context || !exit_status || g_vm != &context->vm) return 0;

    LVM *vm = &context->vm;
    if (vm->frame || vm->sp || vm->pending_len || vm->has_match) return 0;

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

void lvm_context_destroy(LVMContext *context) {
    if (!context) return;
    if (g_vm != &context->vm) return;

    vm_cleanup(&context->vm);
    g_vm = NULL;
    free(context);
}
