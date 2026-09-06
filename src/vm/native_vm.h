#ifndef L_NATIVE_VM_H
#define L_NATIVE_VM_H
#include <stddef.h>
#include <stdint.h>

typedef struct LProgram LProgram;
int lvm_run(const LProgram *program, int argc, char **argv);

#endif
