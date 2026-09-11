#!/usr/bin/env python3
"""Recoverable host-callback boundary tests (issue #20).

Covers the native boundary in src/vm/embed.c and the Python twin in
src/hosts/host_boundary.py: a trapping callback reports a structured
failure without aborting the host, the VM stays reusable, nested
boundaries isolate failures, deep recursion is contained, and acquired
native handles are closed (never dangling).
"""
from __future__ import annotations

import subprocess
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

HARNESS = r"""
#include "embed.c"

#include <dirent.h>

static const char *const cb_strings[] = {
    "ext_good", "ext_trap", "ext_oob", "ext_divzero",
    "ext_chain_a", "ext_chain_b", "ext_recurse", "ext_pipe_trap",
    "ext_arg",
};

enum {
    F_GOOD, F_TRAP, F_OOB, F_DIVZERO, F_CHAIN_A, F_CHAIN_B,
    F_RECURSE, F_PIPE_TRAP, F_ARG,
};

static const LIns good_code[] = {
    {.op = OP_PUSH_INT, .a = TY_I64, .u = UINT64_C(7)},
    {.op = OP_RET},
};
static const LIns trap_code[] = {
    {.op = OP_TRAP},
    {.op = OP_RET},
};
static const LIns oob_code[] = {
    {.op = OP_PUSH_INT, .a = TY_I64, .u = UINT64_C(1)},
    {.op = OP_PUSH_INT, .a = TY_I64, .u = UINT64_C(2)},
    {.op = OP_MAKE_ARRAY, .a = 2},
    {.op = OP_PUSH_INT, .a = TY_U64, .u = UINT64_C(5)},
    {.op = OP_INDEX},
    {.op = OP_RET},
};
static const LIns div_code[] = {
    {.op = OP_PUSH_INT, .a = TY_I64, .u = UINT64_C(1)},
    {.op = OP_PUSH_INT, .a = TY_I64, .u = UINT64_C(0)},
    {.op = OP_BIN, .a = B_DIV, .b = TY_I64},
    {.op = OP_RET},
};
static const LIns chain_a_code[] = {
    {.op = OP_CALL_NAMED, .a = F_CHAIN_B, .b = 0},
    {.op = OP_RET},
};
static const LIns chain_b_code[] = {
    {.op = OP_CALL_NAMED, .a = F_TRAP, .b = 0},
    {.op = OP_RET},
};
static const LIns recurse_code[] = {
    {.op = OP_CALL_NAMED, .a = F_RECURSE, .b = 0},
    {.op = OP_RET},
};
static const LIns pipe_trap_code[] = {
    {.op = OP_HOST_MEMBER, .a = 29},
    {.op = OP_CALL_VALUE, .a = 0},
    {.op = OP_POP},
    {.op = OP_TRAP},
    {.op = OP_RET},
};
static const int arg_params[] = {0};
static const LIns arg_code[] = {
    {.op = OP_PUSH_INT, .a = TY_I64, .u = UINT64_C(0)},
    {.op = OP_RET},
};

static const LFunc cb_functions[] = {
    {0, 0, NULL, 0, 2, good_code},
    {1, 0, NULL, 0, 2, trap_code},
    {2, 0, NULL, 0, 6, oob_code},
    {3, 0, NULL, 0, 4, div_code},
    {4, 0, NULL, 0, 2, chain_a_code},
    {5, 0, NULL, 0, 2, chain_b_code},
    {6, 0, NULL, 0, 2, recurse_code},
    {7, 0, NULL, 0, 5, pipe_trap_code},
    {8, 1, arg_params, 1, 2, arg_code},
};

static const LProgram cb_program = {
    9, cb_functions, F_GOOD,
    9, cb_strings,
    0, NULL,
};

static int failures = 0;

static void check(int cond, const char *what) {
    if (!cond) {
        fprintf(stderr, "callback boundary FAIL: %s\n", what);
        failures++;
    }
}

static int count_open_fds(void) {
#ifdef __linux__
    DIR *d = opendir("/proc/self/fd");
    if (!d) return -1;
    int dfd = dirfd(d);
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        if (atoi(e->d_name) == dfd) continue;
        n++;
    }
    closedir(d);
    return n;
#else
    return -1;
#endif
}

static void expect_ok(LVMContext *ctx, int fid, int want) {
    int status = -1;
    char msg[256];
    memset(msg, 0, sizeof(msg));
    int rc = lvm_context_call_function(ctx, fid, &status, msg,
                                       sizeof(msg));
    check(rc == LVM_CALL_OK, "expected OK return");
    check(status == want, "expected callback status");
}

static void expect_trap(LVMContext *ctx, int fid, const char *want) {
    int status = -1;
    char msg[256];
    memset(msg, 0, sizeof(msg));
    int rc = lvm_context_call_function(ctx, fid, &status, msg,
                                       sizeof(msg));
    check(rc == LVM_CALL_TRAP, "expected TRAP return");
    check(strstr(msg, want) != NULL, "expected trap diagnostic");
}

int main(void) {
    LVMContext *ctx = lvm_context_create(&cb_program, 0, NULL);
    if (!ctx) {
        fprintf(stderr, "callback boundary FAIL: create\n");
        return 1;
    }

    check(lvm_context_find_function(ctx, "ext_good") == F_GOOD,
          "find known function");
    check(lvm_context_find_function(ctx, "nope") == -1,
          "find unknown function");

    expect_ok(ctx, F_GOOD, 7);
    expect_trap(ctx, F_TRAP, "trap");
    expect_ok(ctx, F_GOOD, 7);
    expect_trap(ctx, F_OOB, "index");
    expect_ok(ctx, F_GOOD, 7);
    expect_trap(ctx, F_DIVZERO, "division");
    expect_ok(ctx, F_GOOD, 7);
    /* Nested L calls trap through tracked argument vectors. */
    expect_trap(ctx, F_CHAIN_A, "trap");
    expect_ok(ctx, F_GOOD, 7);
    /* Deep extension recursion is contained, not a C stack crash. */
    expect_trap(ctx, F_RECURSE, "depth");
    expect_ok(ctx, F_GOOD, 7);

    int before = count_open_fds();
    expect_trap(ctx, F_PIPE_TRAP, "trap");
    int after = count_open_fds();
    if (before >= 0 && after >= 0)
        check(before == after, "pipe fds contained after trap");
    expect_ok(ctx, F_GOOD, 7);

    /* Usage errors invoke nothing and report distinctly from traps. */
    {
        int status = -1;
        check(lvm_context_call_function(ctx, F_ARG, &status, NULL, 0) ==
              LVM_CALL_USAGE, "function with params is USAGE");
        check(lvm_context_call_function(ctx, 999, &status, NULL, 0) ==
              LVM_CALL_USAGE, "unknown fid is USAGE");
        check(lvm_context_call_function(NULL, F_GOOD, &status, NULL,
                                        0) == LVM_CALL_USAGE,
              "null context is USAGE");
    }

    /* Nested protected boundaries: an inner trap reports inward while an
     * outer boundary stays armed; a direct trap reaches the outer one. */
    {
        LVM *vm = &ctx->vm;
        LRecovery outer;
        memset(&outer, 0, sizeof(outer));
        outer.prev = vm->recovery;
        outer.frame_boundary = vm->frame;
        outer.sp = vm->sp;
        outer.pending_len = vm->pending_len;
        outer.match_value = vm->match_value;
        outer.has_match = vm->has_match;
        outer.saved_term = vm->saved_term;
        outer.term_raw = vm->term_raw;
        outer.term_screen = vm->term_screen;
        memcpy(outer.key_pushback, vm->key_pushback,
               sizeof(outer.key_pushback));
        outer.key_pushback_len = vm->key_pushback_len;
        outer.proc_checkpoint = vm->procs;
        outer.opaque_checkpoint = linux_host_checkpoint_opaque();
        outer.job_event_checkpoint = linux_host_checkpoint_events();
        outer.tty_mode_checkpoint = linux_host_checkpoint_modes();
        outer.cleanup_checkpoint = vm->cleanups;
        outer.depth_checkpoint = vm->depth;
        vm->recovery = &outer;
        if (setjmp(outer.env) == 0) {
            int status = -1;
            char msg[256];
            int rc = lvm_context_call_function(ctx, F_TRAP, &status,
                                               msg, sizeof(msg));
            check(rc == LVM_CALL_TRAP, "inner trap inside outer");
            expect_ok(ctx, F_GOOD, 7);
            LValue r = vm_call(vm, F_TRAP, NULL, 0);
            (void)r;
            check(0, "outer boundary did not catch direct trap");
            vm->recovery = outer.prev;
        } else {
            check(strstr(outer.msg, "trap") != NULL,
                  "outer caught direct trap");
            vm->recovery = outer.prev;
            pending_clear(vm);
            vm->has_match = 0;
            vm->match_value = v_unit();
            expect_ok(ctx, F_GOOD, 7);
        }
    }

    lvm_context_destroy(ctx);

    /* A context stays reusable after failures, and a fresh context works
     * after the previous one is destroyed. */
    ctx = lvm_context_create(&cb_program, 0, NULL);
    check(ctx != NULL, "recreate after destroy");
    expect_ok(ctx, F_GOOD, 7);
    lvm_context_destroy(ctx);

    if (failures) {
        fprintf(stderr, "callback boundary: %d failure(s)\n", failures);
        return 1;
    }
    printf("host callback boundary PASS\n");
    return 0;
}
"""

STANDALONE = r"""
#include "vm.c"

static const LIns code[] = {
    {.op = OP_TRAP},
    {.op = OP_RET},
};
static const LFunc functions[] = {
    {0, 0, NULL, 0, 2, code},
};
static const LProgram program = {
    1, functions, 0,
    0, NULL,
    0, NULL,
};

int main(int argc, char **argv) {
    return lvm_run(&program, argc, argv);
}
"""

CALLBACK_SOURCES = """
import proc;
fn good() -> i64 { return 7; }
fn trapper() -> i64 { trap; return 0; }
fn oob() -> i64 { var a: []i64 = [1, 2]; return a[5]; }
fn divz() -> i64 { var x: i64 = 1; var y: i64 = 0; return x / y; }
fn down(n: i64) -> i64 { if (n == 0) { return 0; } return down(n - 1); }
fn recurse() -> i64 { return down(5000); }
fn nested() -> i64 { return good() + 1; }
fn spawner() -> i64 {
  var p = proc.spawn([\"sleep\", \"60\"]);
  trap;
  return 0;
}
fn main() -> i64 { return good(); }
"""


def _compile(root: Path, name: str, source: str, extra=()):
    """Compile (host_callback helper for boundary tests)."""
    src = root / f"{name}.c"
    out = root / name
    src.write_text(source, encoding="utf-8")
    cmd = ["cc", "-std=gnu11", "-O2", "-I", str(ROOT / "src/vm"),
           str(src), "-lm", "-o", str(out), *extra]
    subprocess.run(cmd, check=True)
    return out


def run_native():
    """Run native (host_callback helper for boundary tests)."""
    with tempfile.TemporaryDirectory(prefix="l-host-callback-") as td:
        root = Path(td)
        binary = _compile(root, "callback_test", HARNESS)
        subprocess.run([str(binary)], check=True)
        proc = subprocess.run([str(binary)], capture_output=True, text=True)
        assert proc.returncode == 0, proc.stderr
        assert "host callback boundary PASS" in proc.stdout
        # Ordinary standalone programs keep fatal unhandled-trap behavior.
        standalone = _compile(root, "standalone_trap", STANDALONE)
        proc = subprocess.run([str(standalone)], capture_output=True,
                              text=True)
        assert proc.returncode == 70, (proc.returncode, proc.stderr)
        assert "trap" in proc.stderr
        # Sanitizer build must report no memory errors or leaks.
        # ASan's use-after-return fake stack aliases C stack addresses
        # held on the heap, which blinds the &probe-based stack guard;
        # disabling it keeps recursion containment exact under ASan.
        san_env = dict(os.environ)
        san_env["ASAN_OPTIONS"] = "detect_stack_use_after_return=0"
        try:
            san = _compile(root, "callback_asan", HARNESS,
                           ["-fsanitize=address,undefined",
                            "-fno-omit-frame-pointer"])
        except subprocess.CalledProcessError as exc:
            print(f"sanitizer build N/A ({exc}); plain build passed")
            return
        proc = subprocess.run([str(san)], capture_output=True, text=True,
                              env=san_env)
        assert proc.returncode == 0, proc.stderr
        assert "host callback boundary PASS" in proc.stdout
    print("native host callback boundary PASS")


def run_python():
    """Run python (host_callback helper for boundary tests)."""
    from hosts.host_boundary import CallOk, CallTrap, HostBoundary
    from hosts.run import ProcessHost, TermHost
    from lang import Program, internal_name

    ph = ProcessHost()
    th = TermHost()
    hosts = {("proc",): ph.module(), ("term",): th.module()}
    program = Program({("main",): CALLBACK_SOURCES}, hosts)
    interp = program.interpreter()
    name = lambda n: internal_name(("main",), n)  # noqa: E731
    outer = HostBoundary(ph, th)
    inner = HostBoundary(ph, th)

    got = outer.call(lambda: interp.run(name("good")))
    assert isinstance(got, CallOk) and got.value == 7, got
    for fn, word in (("trapper", "trap"), ("oob", "bounds"),
                     ("divz", "division")):
        got = outer.call(lambda fn=fn: interp.run(name(fn)))
        assert isinstance(got, CallTrap), got
        assert word in got.message, got
    got = outer.call(lambda: interp.run(name("good")))
    assert isinstance(got, CallOk) and got.value == 7, got
    got = outer.call(lambda: interp.run(name("nested")))
    assert isinstance(got, CallOk) and got.value == 8, got

    def outer_fn():
        """Outer fn (run_python helper for boundary tests)."""
        res = inner.call(lambda: interp.run(name("trapper")))
        assert isinstance(res, CallTrap), res
        return interp.run(name("good"))

    got = outer.call(outer_fn)
    assert isinstance(got, CallOk) and got.value == 7, got

    def outer_traps():
        """Outer traps (run_python helper for boundary tests)."""
        res = inner.call(lambda: interp.run(name("good")))
        assert isinstance(res, CallOk), res
        return interp.run(name("trapper"))

    got = outer.call(outer_traps)
    assert isinstance(got, CallTrap) and "trap" in got.message, got
    got = outer.call(lambda: interp.run(name("good")))
    assert isinstance(got, CallOk) and got.value == 7, got

    got = outer.call(lambda: interp.run(name("recurse")))
    assert isinstance(got, CallTrap), got
    assert "depth" in got.message, got
    got = outer.call(lambda: interp.run(name("good")))
    assert isinstance(got, CallOk) and got.value == 7, got

    before = len(ph.ps)
    got = outer.call(lambda: interp.run(name("spawner")))
    assert isinstance(got, CallTrap) and "trap" in got.message, got
    assert len(ph.ps) == before + 1
    assert ph.ps[-1].poll() is not None, "spawned child not contained"
    got = outer.call(lambda: interp.run(name("good")))
    assert isinstance(got, CallOk) and got.value == 7, got
    ph.cleanup()
    print("python host callback boundary PASS")


def main():
    """Entry point for the host callback boundary tests."""
    run_native()
    run_python()
    print("host callback PASS")


if __name__ == "__main__":
    main()
