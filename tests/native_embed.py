#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
#include "native_embed.c"

static const LIns code[] = {
    {.op=OP_PUSH_INT, .a=TY_I64, .u=UINT64_C(1)},
    {.op=OP_PUSH_INT, .a=TY_I64, .u=UINT64_C(2)},
    {.op=OP_MAKE_ARRAY, .a=2},
    {.op=OP_LEN},
    {.op=OP_RET},
};

static const LFunc functions[] = {
    {0, 0, NULL, 0, 5, code},
};

static const LProgram program = {
    1, functions, 0,
    0, NULL,
    0, NULL,
};

int main(void) {
    LVMContext *context = lvm_context_create(&program, 0, NULL);
    if (!context) return 10;

    for (int i = 0; i < 10000; i++) {
        int status = -1;
        if (!lvm_context_invoke_entry(context, &status)) return 11;
        if (status != 2) return 12;
    }
    lvm_context_destroy(context);

    /* Destroying one context must make the process reusable for another. */
    context = lvm_context_create(&program, 0, NULL);
    if (!context) return 13;
    int status = -1;
    if (!lvm_context_invoke_entry(context, &status) || status != 2) return 14;
    lvm_context_destroy(context);
    return 0;
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="l-native-embed-") as td:
        root = Path(td)
        source = root / "embed_test.c"
        binary = root / "embed_test"
        source.write_text(HARNESS, encoding="utf-8")
        subprocess.run(
            [
                "cc",
                "-std=gnu11",
                "-O2",
                "-I",
                str(ROOT / "runtime"),
                str(source),
                "-lm",
                "-o",
                str(binary),
            ],
            check=True,
        )
        subprocess.run([str(binary)], check=True)
    print("persistent native embedding context PASS")


if __name__ == "__main__":
    main()
