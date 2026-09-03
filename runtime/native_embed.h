#ifndef L_NATIVE_EMBED_H
#define L_NATIVE_EMBED_H

#include "native_vm.h"

/* Persistent native-VM context for embedding. This is intentionally separate
 * from language-level exception semantics: callers explicitly choose the
 * hosted invocation boundary. Only one context may be active in a process with
 * the current runtime implementation. argc/argv remain borrowed for the
 * context lifetime. */
typedef struct LVMContext LVMContext;

LVMContext *lvm_context_create(const LProgram *program, int argc, char **argv);

/* Invoke the program entry function in an existing context. On a normal L
 * return, writes its process-style status to exit_status and returns 1. A zero
 * return indicates invalid host use; recoverable trap reporting is added by a
 * later layer rather than pretending fatal runtime failures are recoverable. */
int lvm_context_invoke_entry(LVMContext *context, int *exit_status);

void lvm_context_destroy(LVMContext *context);

#endif
