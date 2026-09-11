#ifndef L_NATIVE_EMBED_H
#define L_NATIVE_EMBED_H

#include <stddef.h>

#include "vm.h"

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

/* Recoverable host-callback boundary (issue #20).
 *
 * A hosted application (for example Lace extensions) invokes a trusted
 * in-process L callback and must survive a faulty one. lvm_context_call_function
 * runs a zero-argument L function and reports the outcome without terminating
 * the process:
 *
 *   LVM_CALL_OK   normal return; *status holds the process-style exit code.
 *   LVM_CALL_TRAP contained trap/runtime failure; message holds the
 *                 diagnostic. The VM stays usable for later calls.
 *   LVM_CALL_USAGE invalid host use (bad context, unknown function id,
 *                  function takes arguments); nothing was invoked.
 *
 * Calling convention: only functions with zero parameters are invocable
 * through this boundary; the L return value maps to a small status integer
 * (int payload low byte, bool true/false to 0/1, anything else to 0). This
 * deliberately explicit ABI keeps the internal LValue/LObj layout out of the
 * embedding surface; richer argument passing is future work.
 *
 * Error protocol: on LVM_CALL_TRAP the message buffer (when non-NULL)
 * receives a NUL-terminated diagnostic naming the failure (for example
 * "trap", "array index out of bounds", "division by zero"). The host decides
 * whether to disable the extension, report the error, or continue.
 *
 * State guarantees: transient interpreter state (frames, operand stack,
 * pending bindings, match state), newly acquired native handles (closed but
 * valid, never dangling), and terminal/input state are restored to the entry
 * snapshot. Heap object-graph mutations are NOT rolled back: completed side
 * effects on pre-existing L state persist. Out-of-memory inside bookkeeping
 * remains process-fatal. Boundaries nest: an inner trap reports to the inner
 * caller while the outer boundary stays armed.
 *
 * lvm_context_find_function looks up a zero-argument function id by its
 * compiled name (as stored in the program string table); returns -1 when the
 * name is unknown. Name lookup needs no extra compiler metadata because the
 * generated function names already point into the string table.
 */
enum {
    LVM_CALL_OK = 0,
    LVM_CALL_TRAP = 1,
    LVM_CALL_USAGE = 2
};

int lvm_context_find_function(LVMContext *context, const char *name);
int lvm_context_call_function(LVMContext *context, int fid, int *status,
                              char *message, size_t message_size);

#endif
