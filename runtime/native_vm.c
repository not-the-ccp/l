#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include "native_vm.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <locale.h>
#include <wchar.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* Generated-program ABI. Keep this intentionally boring. */
typedef struct LObj LObj;
typedef struct LValue LValue;
typedef struct LPlace { LObj *owner; LValue *cell; } LPlace;

enum {
    V_UNIT, V_NONE, V_BOOL, V_INT, V_FLOAT,
    V_OBJ, V_FUNC, V_HOSTFN, V_OPAQUE, V_PLACE,
};

struct LValue {
    int tag;
    union {
        uint64_t u;
        double f;
        LObj *obj;
        int id;
        void *ptr;
        LPlace place;
    } as;
};

enum { O_ARRAY, O_REF, O_STRUCT, O_ENUM, O_SOME };
typedef struct { int field; LValue value; } LField;

struct LObj {
    int kind;
    unsigned mark;
    LObj *next;
    union {
        struct { size_t len, cap; LValue *items; } array;
        struct { LValue value; } ref;
        struct { int name; size_t n; LField *fields; } st;
        struct { int name, variant; size_t n; LValue *items; } en;
        struct { LValue value; } some;
    } u;
};

typedef struct { size_t len; const unsigned char *data; } LBlob;
typedef struct { int kind, a, b, n; const int *subs; uint64_t imm; } LPattern;
typedef struct { int op, a, b, c; uint64_t u; double f; const void *ptr; } LIns;
typedef struct {
    int name;
    int param_count;
    const int *param_slots;
    int slot_count;
    int ins_count;
    const LIns *code;
} LFunc;

struct LProgram {
    int function_count;
    const LFunc *functions;
    int entry_function;
    int string_count;
    const char *const *strings;
    int pattern_count;
    const LPattern *patterns;
};

/* opcodes */
enum {
    OP_PUSH_UNIT, OP_PUSH_NONE, OP_PUSH_BOOL, OP_PUSH_INT, OP_PUSH_FLOAT,
    OP_MAKE_BYTES, OP_MAKE_SOME, OP_MAKE_ARRAY, OP_MAKE_REPEAT,
    OP_DECL, OP_LOAD, OP_LOCAL_PLACE, OP_FIELD_PLACE, OP_VALUE_FIELD_PLACE,
    OP_INDEX_PLACE, OP_DEREF_PLACE, OP_LOAD_PLACE, OP_STORE_PLACE,
    OP_DUP, OP_POP, OP_SCOPE_ENTER, OP_SCOPE_ENTER_BINDINGS, OP_SCOPE_EXIT,
    OP_UNWIND, OP_NO_BINDINGS, OP_DROP_BINDINGS,
    OP_JUMP, OP_JUMP_IF_FALSE, OP_JUMP_IF_FALSE_KEEP, OP_JUMP_IF_TRUE_KEEP,
    OP_LEN, OP_LOCAL_INC_U64, OP_INDEX, OP_GET_FIELD, OP_DEREF,
    OP_UNARY, OP_BIN, OP_CAST, OP_NEW,
    OP_MAKE_STRUCT, OP_MAKE_ENUM_ZERO, OP_MAKE_ENUM, OP_PUSH_FUNC,
    OP_CALL_NAMED, OP_CALL_VALUE, OP_HOST_MEMBER,
    OP_ARRAY_PUSH, OP_ARRAY_POP, OP_ARRAY_SPLICE,
    OP_SAVE_MATCH_VALUE, OP_LOAD_MATCH_VALUE, OP_CLEAR_MATCH_VALUE,
    OP_TRY_PATTERN, OP_PATTERN_TO_BOOL, OP_JUMP_IF_NO_MATCH,
    OP_TRAP_MATCH, OP_TRAP, OP_RET,
};

enum {
    TY_UNIT, TY_BOOL, TY_I8, TY_I16, TY_I32, TY_I64,
    TY_U8, TY_U16, TY_U32, TY_U64, TY_F32, TY_F64, TY_REF, TY_ENUM,
};

enum {
    B_EQ, B_NE, B_LT, B_LE, B_GT, B_GE, B_AND, B_OR,
    B_SHL, B_SHR, B_BAND, B_BOR, B_BXOR,
    B_ADD, B_SUB, B_MUL, B_DIV, B_MOD,
};

enum { U_NOT, U_BNOT, U_NEG };
enum { P_WILD, P_BIND, P_UNIT, P_NONE, P_SOME, P_BOOL, P_INT, P_BYTE, P_ENUM };

enum {
    H_STDIO_READ, H_STDIO_WRITE,
    H_FS_READ, H_FS_WRITE,
    H_SYS_ARGS, H_SYS_EXE_PATH, H_SYS_GETENV,
    H_PROC_SPAWN, H_PROC_WRITE, H_PROC_READ, H_PROC_READ_TIMEOUT,
    H_PROC_CLOSE, H_PROC_SHELL,
    H_TERM_ENTER_RAW, H_TERM_LEAVE_RAW, H_TERM_ENTER_UI, H_TERM_LEAVE_UI,
    H_TERM_READ_KEY, H_TERM_READ_KEY_TIMEOUT, H_TERM_WRITE,
    H_TERM_ROWS, H_TERM_COLS,
    H_PROC_WRITE_TRY, H_PROC_ALIVE, H_TERM_TEXT_WIDTH,
};

/* VM state */
typedef struct { int slot; LValue value; } LBinding;
typedef struct { size_t boundary; } LScope;

typedef struct LFrame {
    const LFunc *fn;
    int ip;
    LValue *locals;
    unsigned char *active;
    int *declared;
    size_t decl_len, decl_cap;
    LScope *scopes;
    size_t scope_len, scope_cap;
    struct LFrame *prev;
} LFrame;

typedef struct Proc {
    pid_t pid;
    int in_fd, out_fd;
    int closed;
    struct Proc *next;
} Proc;

typedef struct {
    const LProgram *p;
    LValue *stack;
    size_t sp, stack_cap;
    LFrame *frame;
    LObj *objects;
    size_t object_count;
    size_t gc_threshold;
    LBinding *pending;
    size_t pending_len, pending_cap;
    LValue match_value;
    int has_match;
    int argc;
    char **argv;
    struct termios saved_term;
    int term_raw;
    int term_screen;
    unsigned char key_pushback[16];
    size_t key_pushback_len;
    Proc *procs;
    int trapped;
} LVM;

static LVM *g_vm = NULL;
static int g_cleanup_registered = 0;

static void emergency_term_restore(void) {
    if (!g_vm) return;
    if (g_vm->term_screen) {
        static const char seq[] = "\x1b[0m\x1b[?25h\x1b[?1049l";
        (void)write(1, seq, sizeof(seq) - 1);
        g_vm->term_screen = 0;
    }
    if (g_vm->term_raw) {
        (void)tcsetattr(0, TCSANOW, &g_vm->saved_term);
        g_vm->term_raw = 0;
    }
}

static void runtime_atexit(void) { emergency_term_restore(); }

static void runtime_signal(int sig) {
    emergency_term_restore();
    _exit(128 + sig);
}

static void install_runtime_cleanup(void) {
    if (g_cleanup_registered) return;
    g_cleanup_registered = 1;
    atexit(runtime_atexit);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = runtime_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
}

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "L runtime error: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(70);
}

static LValue v_unit(void) {
    LValue v = {.tag = V_UNIT};
    return v;
}

static LValue v_none(void) {
    LValue v = {.tag = V_NONE};
    return v;
}

static LValue v_bool(int b) {
    LValue v = {.tag = V_BOOL};
    v.as.u = !!b;
    return v;
}

static LValue v_int(uint64_t x) {
    LValue v = {.tag = V_INT};
    v.as.u = x;
    return v;
}

static LValue v_float(double x) {
    LValue v = {.tag = V_FLOAT};
    v.as.f = x;
    return v;
}

static LValue v_obj(LObj *o) {
    LValue v = {.tag = V_OBJ};
    v.as.obj = o;
    return v;
}

static LValue v_func(int x) {
    LValue v = {.tag = V_FUNC};
    v.as.id = x;
    return v;
}

static LValue v_host(int x) {
    LValue v = {.tag = V_HOSTFN};
    v.as.id = x;
    return v;
}

static LValue v_opaque(void *x) {
    LValue v = {.tag = V_OPAQUE};
    v.as.ptr = x;
    return v;
}

static LValue v_place(LObj *owner, LValue *cell) {
    LValue v = {.tag = V_PLACE};
    v.as.place.owner = owner;
    v.as.place.cell = cell;
    return v;
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die("out of memory");
    return p;
}

static void *xrealloc(void *p, size_t n) {
    p = realloc(p, n ? n : 1);
    if (!p) die("out of memory");
    return p;
}

static LObj *obj_new(LVM *vm, int kind) {
    LObj *o = calloc(1, sizeof(*o));
    if (!o) die("out of memory");
    o->kind = kind;
    o->next = vm->objects;
    vm->objects = o;
    vm->object_count++;
    return o;
}

static int ty_width(int t) {
    switch (t) {
        case TY_I8: case TY_U8: return 8;
        case TY_I16: case TY_U16: return 16;
        case TY_I32: case TY_U32: return 32;
        case TY_I64: case TY_U64: return 64;
        default: return 0;
    }
}

static int ty_signed(int t) {
    return t == TY_I8 || t == TY_I16 || t == TY_I32 || t == TY_I64;
}

static int ty_int(int t) { return ty_width(t) != 0; }

static uint64_t mask_width(uint64_t x, int w) {
    return w == 64 ? x : (x & ((UINT64_C(1) << w) - 1));
}

static int64_t signed_value(uint64_t x, int w) {
    x = mask_width(x, w);
    if (w == 64) return (int64_t)x;
    uint64_t sign = UINT64_C(1) << (w - 1);
    return (int64_t)((x ^ sign) - sign);
}

static double round_float(double x, int t) {
    if (t == TY_F32) {
        float f = (float)x;
        return (double)f;
    }
    return x;
}

static int truth(LValue v) {
    if (v.tag != V_BOOL) die("condition is not bool");
    return (int)v.as.u;
}

static void mark_value(LValue v);

static void mark_obj(LObj *o) {
    if (!o || o->mark) return;
    o->mark = 1;
    switch (o->kind) {
        case O_ARRAY:
            for (size_t i = 0; i < o->u.array.len; i++)
                mark_value(o->u.array.items[i]);
            break;
        case O_REF:
            mark_value(o->u.ref.value);
            break;
        case O_STRUCT:
            for (size_t i = 0; i < o->u.st.n; i++)
                mark_value(o->u.st.fields[i].value);
            break;
        case O_ENUM:
            for (size_t i = 0; i < o->u.en.n; i++)
                mark_value(o->u.en.items[i]);
            break;
        case O_SOME:
            mark_value(o->u.some.value);
            break;
    }
}

static void mark_value(LValue v) {
    if (v.tag == V_OBJ) mark_obj(v.as.obj);
    else if (v.tag == V_PLACE) mark_obj(v.as.place.owner);
}

static void gc_collect(LVM *vm) {
    for (size_t i = 0; i < vm->sp; i++) mark_value(vm->stack[i]);
    for (LFrame *f = vm->frame; f; f = f->prev)
        for (int i = 0; i < f->fn->slot_count; i++)
            if (f->active[i]) mark_value(f->locals[i]);
    for (size_t i = 0; i < vm->pending_len; i++)
        mark_value(vm->pending[i].value);
    if (vm->has_match) mark_value(vm->match_value);

    LObj **pp = &vm->objects;
    size_t live = 0;
    while (*pp) {
        LObj *o = *pp;
        if (!o->mark) {
            *pp = o->next;
            if (o->kind == O_ARRAY) free(o->u.array.items);
            else if (o->kind == O_STRUCT) free(o->u.st.fields);
            else if (o->kind == O_ENUM) free(o->u.en.items);
            free(o);
            vm->object_count--;
        } else {
            o->mark = 0;
            live++;
            pp = &o->next;
        }
    }
    vm->gc_threshold = live * 2 + 4096;
}

static void gc_maybe(LVM *vm) {
    if (vm->object_count > vm->gc_threshold) gc_collect(vm);
}

static LValue value_copy(LVM *vm, LValue v) {
    if (v.tag != V_OBJ) return v;
    LObj *o = v.as.obj;
    if (o->kind == O_ARRAY || o->kind == O_REF) return v;
    if (o->kind == O_SOME) {
        LObj *n = obj_new(vm, O_SOME);
        n->u.some.value = value_copy(vm, o->u.some.value);
        return v_obj(n);
    }
    if (o->kind == O_STRUCT) {
        LObj *n = obj_new(vm, O_STRUCT);
        n->u.st.name = o->u.st.name;
        n->u.st.n = o->u.st.n;
        n->u.st.fields = xmalloc(sizeof(LField) * n->u.st.n);
        for (size_t i = 0; i < n->u.st.n; i++) {
            n->u.st.fields[i].field = o->u.st.fields[i].field;
            n->u.st.fields[i].value = value_copy(vm, o->u.st.fields[i].value);
        }
        return v_obj(n);
    }
    if (o->kind == O_ENUM) {
        LObj *n = obj_new(vm, O_ENUM);
        n->u.en.name = o->u.en.name;
        n->u.en.variant = o->u.en.variant;
        n->u.en.n = o->u.en.n;
        n->u.en.items = xmalloc(sizeof(LValue) * n->u.en.n);
        for (size_t i = 0; i < n->u.en.n; i++)
            n->u.en.items[i] = value_copy(vm, o->u.en.items[i]);
        return v_obj(n);
    }
    return v;
}

static LObj *new_array(LVM *vm, size_t n) {
    LObj *o = obj_new(vm, O_ARRAY);
    o->u.array.len = n;
    o->u.array.cap = n;
    o->u.array.items = n ? xmalloc(sizeof(LValue) * n) : NULL;
    return o;
}

static void array_reserve(LObj *a, size_t n) {
    if (a->kind != O_ARRAY) die("not an array");
    if (n <= a->u.array.cap) return;
    size_t c = a->u.array.cap ? a->u.array.cap : 8;
    while (c < n) c = c < 1048576 ? c * 2 : c + c / 2;
    a->u.array.items = xrealloc(a->u.array.items, c * sizeof(LValue));
    a->u.array.cap = c;
}

static LObj *bytes_array(LVM *vm, const unsigned char *p, size_t n) {
    LObj *a = new_array(vm, n);
    for (size_t i = 0; i < n; i++) a->u.array.items[i] = v_int(p[i]);
    return a;
}

static char *array_cstr(LValue v) {
    if (v.tag != V_OBJ || v.as.obj->kind != O_ARRAY) die("expected []u8");
    LObj *a = v.as.obj;
    char *s = xmalloc(a->u.array.len + 1);
    for (size_t i = 0; i < a->u.array.len; i++)
        s[i] = (char)(a->u.array.items[i].as.u & 255);
    s[a->u.array.len] = 0;
    return s;
}

static void stack_reserve(LVM *vm, size_t n) {
    if (n <= vm->stack_cap) return;
    size_t c = vm->stack_cap ? vm->stack_cap : 256;
    while (c < n) c *= 2;
    vm->stack = xrealloc(vm->stack, c * sizeof(LValue));
    vm->stack_cap = c;
}

static void pushv(LVM *vm, LValue v) {
    stack_reserve(vm, vm->sp + 1);
    vm->stack[vm->sp++] = v;
}

static LValue popv(LVM *vm) {
    if (!vm->sp) die("operand stack underflow");
    return vm->stack[--vm->sp];
}

static LValue *field_cell(LValue base, int field, LObj **owner) {
    if (base.tag != V_OBJ) die("field on non-object");
    LObj *o = base.as.obj;
    if (o->kind == O_REF) {
        o = o->u.ref.value.as.obj;
        if (!o) die("bad ref");
    }
    if (o->kind != O_STRUCT) die("field on non-struct");
    for (size_t i = 0; i < o->u.st.n; i++) {
        if (o->u.st.fields[i].field == field) {
            if (owner) *owner = o;
            return &o->u.st.fields[i].value;
        }
    }
    die("unknown struct field");
    return NULL;
}

static void frame_scope_enter(LFrame *f) {
    if (f->scope_len == f->scope_cap) {
        f->scope_cap = f->scope_cap ? f->scope_cap * 2 : 8;
        f->scopes = xrealloc(f->scopes, f->scope_cap * sizeof(LScope));
    }
    f->scopes[f->scope_len++] = (LScope){f->decl_len};
}

static void frame_decl(LFrame *f, int slot, LValue v) {
    if (slot < 0 || slot >= f->fn->slot_count) die("bad local slot");
    f->locals[slot] = v;
    f->active[slot] = 1;
    if (f->decl_len == f->decl_cap) {
        f->decl_cap = f->decl_cap ? f->decl_cap * 2 : 16;
        f->declared = xrealloc(f->declared, f->decl_cap * sizeof(int));
    }
    f->declared[f->decl_len++] = slot;
}

static void frame_scope_exit(LFrame *f) {
    if (!f->scope_len) die("scope underflow");
    size_t b = f->scopes[--f->scope_len].boundary;
    while (f->decl_len > b) {
        int s = f->declared[--f->decl_len];
        f->active[s] = 0;
        f->locals[s] = v_unit();
    }
}

static void frame_unwind(LFrame *f, int n) {
    while (n-- > 0) frame_scope_exit(f);
}static LValue scalar_bin(LVM *vm, int op, LValue a, LValue b, int t) {
    (void)vm;
    if (op == B_AND || op == B_OR)
        return v_bool(op == B_AND ? (truth(a) && truth(b))
                                  : (truth(a) || truth(b)));
    if (t == TY_BOOL) {
        if (op == B_EQ) return v_bool(a.as.u == b.as.u);
        if (op == B_NE) return v_bool(a.as.u != b.as.u);
    }
    if (t == TY_REF) {
        if (op == B_EQ) return v_bool(a.as.obj == b.as.obj);
        if (op == B_NE) return v_bool(a.as.obj != b.as.obj);
    }
    if (t == TY_ENUM) {
        if (a.tag != V_OBJ || b.tag != V_OBJ ||
            a.as.obj->kind != O_ENUM || b.as.obj->kind != O_ENUM)
            die("bad enum comparison");
        int eq = a.as.obj->u.en.name == b.as.obj->u.en.name &&
                 a.as.obj->u.en.variant == b.as.obj->u.en.variant;
        if (op == B_EQ) return v_bool(eq);
        if (op == B_NE) return v_bool(!eq);
    }
    if (t == TY_F32 || t == TY_F64) {
        double x = a.as.f, y = b.as.f;
        switch (op) {
            case B_EQ: return v_bool(x == y);
            case B_NE: return v_bool(x != y);
            case B_LT: return v_bool(x < y);
            case B_LE: return v_bool(x <= y);
            case B_GT: return v_bool(x > y);
            case B_GE: return v_bool(x >= y);
            case B_ADD: return v_float(round_float(x + y, t));
            case B_SUB: return v_float(round_float(x - y, t));
            case B_MUL: return v_float(round_float(x * y, t));
            case B_DIV:
                if (y == 0.0) {
                    if (x == 0.0) return v_float(NAN);
                    return v_float(copysign(INFINITY, x) * copysign(1.0, y));
                }
                return v_float(round_float(x / y, t));
            default: die("bad float op");
        }
    }
    if (ty_int(t)) {
        int w = ty_width(t), sg = ty_signed(t);
        uint64_t x = mask_width(a.as.u, w);
        uint64_t y = mask_width(b.as.u, w);
        int64_t sx = signed_value(x, w), sy = signed_value(y, w);
        switch (op) {
            case B_EQ: return v_bool(x == y);
            case B_NE: return v_bool(x != y);
            case B_LT: return v_bool(sg ? sx < sy : x < y);
            case B_LE: return v_bool(sg ? sx <= sy : x <= y);
            case B_GT: return v_bool(sg ? sx > sy : x > y);
            case B_GE: return v_bool(sg ? sx >= sy : x >= y);
            case B_BAND: return v_int(mask_width(x & y, w));
            case B_BOR: return v_int(mask_width(x | y, w));
            case B_BXOR: return v_int(mask_width(x ^ y, w));
            case B_ADD: return v_int(mask_width(x + y, w));
            case B_SUB: return v_int(mask_width(x - y, w));
            case B_MUL: return v_int(mask_width(x * y, w));
            case B_SHL:
                if (b.as.u >= (uint64_t)w) die("invalid shift count");
                return v_int(mask_width(x << b.as.u, w));
            case B_SHR:
                if (b.as.u >= (uint64_t)w) die("invalid shift count");
                if (sg && b.as.u && (x & (UINT64_C(1) << (w - 1)))) {
                    uint64_t z = (x >> b.as.u) |
                        ((~UINT64_C(0)) << (w - (int)b.as.u));
                    return v_int(mask_width(z, w));
                }
                return v_int(x >> b.as.u);
            case B_DIV:
                if (y == 0) die("division by zero");
                if (sg) {
                    __int128 q = (__int128)sx / (__int128)sy;
                    return v_int(mask_width((uint64_t)q, w));
                }
                return v_int(x / y);
            case B_MOD:
                if (y == 0) die("remainder by zero");
                if (sg) {
                    __int128 q = (__int128)sx / (__int128)sy;
                    __int128 r = (__int128)sx - q * (__int128)sy;
                    return v_int(mask_width((uint64_t)r, w));
                }
                return v_int(x % y);
        }
    }
    die("bad scalar op/type");
    return v_unit();
}

static LValue scalar_unary(int op, LValue v, int t) {
    if (op == U_NOT) return v_bool(!truth(v));
    if (t == TY_F32 || t == TY_F64) {
        if (op == U_NEG) return v_float(round_float(-v.as.f, t));
    }
    if (ty_int(t)) {
        int w = ty_width(t);
        if (op == U_BNOT) return v_int(mask_width(~v.as.u, w));
        if (op == U_NEG) return v_int(mask_width((uint64_t)(-v.as.u), w));
    }
    die("bad unary");
    return v_unit();
}

static LValue cast_value(LValue v, int src, int dst) {
    if (ty_int(src) && ty_int(dst))
        return v_int(mask_width(v.as.u, ty_width(dst)));
    if ((src == TY_F32 || src == TY_F64) && (dst == TY_F32 || dst == TY_F64))
        return v_float(round_float(v.as.f, dst));
    if (ty_int(src) && (dst == TY_F32 || dst == TY_F64)) {
        double x = ty_signed(src)
            ? (double)signed_value(v.as.u, ty_width(src))
            : (double)mask_width(v.as.u, ty_width(src));
        return v_float(round_float(x, dst));
    }
    if ((src == TY_F32 || src == TY_F64) && ty_int(dst)) {
        double x = trunc(v.as.f);
        if (!isfinite(x)) die("invalid float to integer cast");
        int w = ty_width(dst);
        if (ty_signed(dst)) {
            long double lo = -(ldexpl(1.0L, w - 1));
            long double hi = ldexpl(1.0L, w - 1) - 1;
            if ((long double)x < lo || (long double)x > hi)
                die("float to integer cast out of range");
            return v_int(mask_width((uint64_t)(__int128)x, w));
        }
        long double hi = w == 64 ? 18446744073709551615.0L
                                 : ldexpl(1.0L, w) - 1;
        if (x < 0 || (long double)x > hi)
            die("float to integer cast out of range");
        return v_int(mask_width((uint64_t)(unsigned __int128)x, w));
    }
    die("bad cast");
    return v_unit();
}

static void pending_clear(LVM *vm) { vm->pending_len = 0; }

static void pending_add(LVM *vm, int slot, LValue v) {
    if (vm->pending_len == vm->pending_cap) {
        vm->pending_cap = vm->pending_cap ? vm->pending_cap * 2 : 8;
        vm->pending = xrealloc(vm->pending,
                               vm->pending_cap * sizeof(LBinding));
    }
    vm->pending[vm->pending_len++] = (LBinding){slot, value_copy(vm, v)};
}

static int pattern_match(LVM *vm, int pid, LValue v) {
    const LPattern *p = &vm->p->patterns[pid];
    size_t base = vm->pending_len;
    switch (p->kind) {
        case P_WILD: return 1;
        case P_BIND: pending_add(vm, p->a, v); return 1;
        case P_UNIT: return v.tag == V_UNIT;
        case P_NONE: return v.tag == V_NONE;
        case P_BOOL: return v.tag == V_BOOL && (int)v.as.u == p->a;
        case P_INT:
        case P_BYTE:
            return v.tag == V_INT && v.as.u == (uint64_t)p->imm;
        case P_SOME:
            if (v.tag != V_OBJ || v.as.obj->kind != O_SOME) return 0;
            if (pattern_match(vm, p->a, v.as.obj->u.some.value)) return 1;
            break;
        case P_ENUM:
            if (v.tag != V_OBJ || v.as.obj->kind != O_ENUM ||
                v.as.obj->u.en.name != p->a ||
                v.as.obj->u.en.variant != p->b ||
                v.as.obj->u.en.n != (size_t)p->n)
                return 0;
            for (int i = 0; i < p->n; i++) {
                if (!pattern_match(vm, p->subs[i],
                                   v.as.obj->u.en.items[i]))
                    goto fail;
            }
            return 1;
    }
fail:
    vm->pending_len = base;
    return 0;
}

static int read_fd_timeout(int fd, unsigned char *buf, size_t n,
                           int timeout_ms) {
    struct pollfd p = {.fd = fd, .events = POLLIN};
    int r = poll(&p, 1, timeout_ms);
    if (r <= 0) return r;
    ssize_t z = read(fd, buf, n);
    return z > 0 ? (int)z : (z == 0 ? 0 : -1);
}

static LValue host_bytes(LVM *vm, const unsigned char *p, size_t n) {
    return v_obj(bytes_array(vm, p, n));
}

static Proc *as_proc(LValue v) {
    if (v.tag != V_OPAQUE) die("expected process");
    return (Proc *)v.as.ptr;
}

static void proc_close_one(Proc *p) {
    if (!p || p->closed) return;
    p->closed = 1;
    if (p->in_fd >= 0) { close(p->in_fd); p->in_fd = -1; }
    if (p->out_fd >= 0) { close(p->out_fd); p->out_fd = -1; }
    int st;
    pid_t r = waitpid(p->pid, &st, WNOHANG);
    if (r == 0) {
        kill(p->pid, SIGTERM);
        for (int i = 0; i < 20; i++) {
            r = waitpid(p->pid, &st, WNOHANG);
            if (r != 0) break;
            struct timespec ts = {0, 10000000};
            nanosleep(&ts, NULL);
        }
        if (r == 0) {
            kill(p->pid, SIGKILL);
            waitpid(p->pid, &st, 0);
        }
    }
}

#include "linux_host.inc"

static LValue host_call(LVM *vm, int id, LValue *args, int n) {
    if (linux_host_id(id)) return linux_host_call(vm, id, args, n);
    switch (id) {
    case H_STDIO_READ: {
        if (n != 1) die("stdio.read arity");
        size_t want = (size_t)args[0].as.u;
        if (want > 1048576) want = 1048576;
        unsigned char *b = xmalloc(want ? want : 1);
        ssize_t z = read(0, b, want ? want : 1);
        if (z <= 0) {
            free(b);
            return v_none();
        }
        LObj *s = obj_new(vm, O_SOME);
        s->u.some.value = host_bytes(vm, b, (size_t)z);
        free(b);
        return v_obj(s);
    }
    case H_STDIO_WRITE: {
        char *b = array_cstr(args[0]);
        size_t len = args[0].as.obj->u.array.len;
        size_t off = 0;
        while (off < len) {
            ssize_t z = write(1, b + off, len - off);
            if (z < 0) die("stdio.write");
            off += (size_t)z;
        }
        free(b);
        return v_unit();
    }
    case H_FS_READ: {
        char *path = array_cstr(args[0]);
        FILE *f = fopen(path, "rb");
        free(path);
        if (!f) return v_none();
        if (fseek(f, 0, SEEK_END)) {
            fclose(f);
            return v_none();
        }
        long z = ftell(f);
        rewind(f);
        unsigned char *b = xmalloc(z > 0 ? (size_t)z : 1);
        size_t got = fread(b, 1, z > 0 ? (size_t)z : 0, f);
        fclose(f);
        LObj *s = obj_new(vm, O_SOME);
        s->u.some.value = host_bytes(vm, b, got);
        free(b);
        return v_obj(s);
    }
    case H_FS_WRITE: {
        char *path = array_cstr(args[0]);
        LObj *a = args[1].as.obj;
        FILE *f = fopen(path, "wb");
        free(path);
        if (!f) return v_bool(0);
        unsigned char *b = xmalloc(a->u.array.len ? a->u.array.len : 1);
        for (size_t i = 0; i < a->u.array.len; i++)
            b[i] = (unsigned char)a->u.array.items[i].as.u;
        size_t w = fwrite(b, 1, a->u.array.len, f);
        int ok = (w == a->u.array.len && fclose(f) == 0);
        free(b);
        return v_bool(ok);
    }
    case H_SYS_ARGS: {
        LObj *out = new_array(vm, vm->argc > 1 ? (size_t)(vm->argc - 1) : 0);
        for (int i = 1; i < vm->argc; i++)
            out->u.array.items[i - 1] =
                host_bytes(vm, (unsigned char *)vm->argv[i],
                           strlen(vm->argv[i]));
        return v_obj(out);
    }
    case H_SYS_EXE_PATH: {
        char tmp[4096];
        ssize_t z = readlink("/proc/self/exe", tmp, sizeof(tmp));
        if (z < 0) {
            const char *s = vm->argv[0];
            return host_bytes(vm, (const unsigned char *)s, strlen(s));
        }
        return host_bytes(vm, (unsigned char *)tmp, (size_t)z);
    }
    case H_SYS_GETENV: {
        char *name = array_cstr(args[0]);
        const char *value = getenv(name);
        free(name);
        if (!value) return v_none();
        LObj *s = obj_new(vm, O_SOME);
        s->u.some.value =
            host_bytes(vm, (const unsigned char *)value, strlen(value));
        return v_obj(s);
    }
    case H_PROC_SPAWN: {
        LObj *aa = args[0].as.obj;
        if (aa->kind != O_ARRAY || aa->u.array.len == 0)
            die("proc.spawn requires argv");
        size_t ac = aa->u.array.len;
        char **av = xmalloc((ac + 1) * sizeof(char *));
        for (size_t i = 0; i < ac; i++)
            av[i] = array_cstr(aa->u.array.items[i]);
        av[ac] = NULL;
        int pin[2], pout[2];
        if (pipe(pin) || pipe(pout)) die("pipe failed");
        pid_t pid = fork();
        if (pid < 0) die("fork failed");
        if (pid == 0) {
            setpgid(0, 0);
            dup2(pin[0], 0);
            dup2(pout[1], 1);
            int dn = open("/dev/null", O_WRONLY);
            if (dn >= 0) dup2(dn, 2);
            close(pin[0]); close(pin[1]);
            close(pout[0]); close(pout[1]);
            execvp(av[0], av);
            _exit(127);
        }
        setpgid(pid, pid);
        close(pin[0]);
        close(pout[1]);
        for (size_t i = 0; i < ac; i++) free(av[i]);
        free(av);
        Proc *p = calloc(1, sizeof(*p));
        p->pid = pid;
        p->in_fd = pin[1];
        p->out_fd = pout[0];
        p->next = vm->procs;
        vm->procs = p;
        return v_opaque(p);
    }
    case H_PROC_WRITE: {
        Proc *p = as_proc(args[0]);
        LObj *a = args[1].as.obj;
        unsigned char *b = xmalloc(a->u.array.len ? a->u.array.len : 1);
        for (size_t i = 0; i < a->u.array.len; i++)
            b[i] = (unsigned char)a->u.array.items[i].as.u;
        size_t off = 0;
        while (off < a->u.array.len) {
            ssize_t z = write(p->in_fd, b + off, a->u.array.len - off);
            if (z <= 0) die("proc.write");
            off += (size_t)z;
        }
        free(b);
        return v_unit();
    }
    case H_PROC_READ:
    case H_PROC_READ_TIMEOUT: {
        Proc *p = as_proc(args[0]);
        size_t want = (size_t)args[1].as.u;
        if (want > 1048576) want = 1048576;
        unsigned char *b = xmalloc(want ? want : 1);
        int z;
        if (id == H_PROC_READ_TIMEOUT) {
            z = read_fd_timeout(p->out_fd, b, want ? want : 1,
                                 (int)args[2].as.u);
        } else {
            ssize_t q = read(p->out_fd, b, want ? want : 1);
            z = (int)q;
        }
        if (z <= 0) {
            free(b);
            return v_none();
        }
        LObj *s = obj_new(vm, O_SOME);
        s->u.some.value = host_bytes(vm, b, (size_t)z);
        free(b);
        return v_obj(s);
    }
    case H_PROC_CLOSE: {
        proc_close_one(as_proc(args[0]));
        return v_unit();
    }
    case H_PROC_SHELL: {
        char *cmd = array_cstr(args[0]);
        struct sigaction ign, oldint, oldquit;
        memset(&ign, 0, sizeof(ign));
        ign.sa_handler = SIG_IGN;
        sigemptyset(&ign.sa_mask);
        sigaction(SIGINT, &ign, &oldint);
        sigaction(SIGQUIT, &ign, &oldquit);
        pid_t pid = fork();
        int st = 127;
        if (pid == 0) {
            signal(SIGINT, SIG_DFL);
            signal(SIGQUIT, SIG_DFL);
            execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
            _exit(127);
        }
        if (pid > 0) {
            while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
            }
        }
        sigaction(SIGINT, &oldint, NULL);
        sigaction(SIGQUIT, &oldquit, NULL);
        free(cmd);
        if (pid < 0) return v_int(127);
        if (WIFEXITED(st)) return v_int((uint64_t)WEXITSTATUS(st));
        if (WIFSIGNALED(st)) return v_int((uint64_t)(128 + WTERMSIG(st)));
        return v_int(127);
    }
    case H_PROC_WRITE_TRY: {
        Proc *p = as_proc(args[0]);
        LObj *a = args[1].as.obj;
        if (p->closed || p->in_fd < 0) return v_bool(0);
        unsigned char *b = xmalloc(a->u.array.len ? a->u.array.len : 1);
        for (size_t i = 0; i < a->u.array.len; i++)
            b[i] = (unsigned char)a->u.array.items[i].as.u;
        size_t off = 0;
        int ok = 1;
        while (off < a->u.array.len) {
            ssize_t z = write(p->in_fd, b + off, a->u.array.len - off);
            if (z < 0 && errno == EINTR) continue;
            if (z <= 0) {
                ok = 0;
                break;
            }
            off += (size_t)z;
        }
        free(b);
        return v_bool(ok);
    }
    case H_PROC_ALIVE: {
        Proc *p = as_proc(args[0]);
        if (p->closed) return v_bool(0);
        int st;
        pid_t r = waitpid(p->pid, &st, WNOHANG);
        if (r == 0) return v_bool(1);
        if (r == p->pid) {
            if (p->in_fd >= 0) { close(p->in_fd); p->in_fd = -1; }
            if (p->out_fd >= 0) { close(p->out_fd); p->out_fd = -1; }
            p->closed = 1;
            return v_bool(0);
        }
        return v_bool(0);
    }
    case H_TERM_ENTER_RAW:
    case H_TERM_ENTER_UI: {
        if (!vm->term_raw && isatty(0)) {
            if (tcgetattr(0, &vm->saved_term) == 0) {
                struct termios t = vm->saved_term;
                t.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
                t.c_oflag &= ~OPOST;
                t.c_cflag |= CS8;
                t.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
                t.c_cc[VMIN] = 1;
                t.c_cc[VTIME] = 0;
                if (tcsetattr(0, TCSANOW, &t) == 0) vm->term_raw = 1;
            }
        }
        if (id == H_TERM_ENTER_UI && !vm->term_screen) {
            static const char seq[] = "\x1b[?1049h\x1b[?25h";
            (void)write(1, seq, sizeof(seq) - 1);
            vm->term_screen = 1;
        }
        return v_unit();
    }
    case H_TERM_LEAVE_RAW:
    case H_TERM_LEAVE_UI: {
        if (id == H_TERM_LEAVE_UI && vm->term_screen) {
            static const char seq[] = "\x1b[0m\x1b[?25h\x1b[?1049l";
            (void)write(1, seq, sizeof(seq) - 1);
            vm->term_screen = 0;
        }
        if (vm->term_raw) {
            tcsetattr(0, TCSANOW, &vm->saved_term);
            vm->term_raw = 0;
        }
        return v_unit();
    }
    case H_TERM_READ_KEY:
    case H_TERM_READ_KEY_TIMEOUT: {
        int timeout = id == H_TERM_READ_KEY ? -1 : (int)args[0].as.u;
        unsigned char b[16];
        size_t nread = 0;
        if (vm->key_pushback_len) {
            b[nread++] = vm->key_pushback[0];
            memmove(vm->key_pushback, vm->key_pushback + 1,
                    --vm->key_pushback_len);
        } else {
            int z = read_fd_timeout(0, b, 1, timeout);
            if (z <= 0) return v_none();
            nread = 1;
        }
        if (b[0] == 27) {
            unsigned char second = 0;
            int q = read_fd_timeout(0, &second, 1, 8);
            if (q > 0) {
                if (second == '[' || second == 'O') {
                    b[nread++] = second;
                    while (nread < sizeof(b)) {
                        unsigned char c = 0;
                        q = read_fd_timeout(0, &c, 1, 8);
                        if (q <= 0) break;
                        b[nread++] = c;
                        /* ANSI/VT CSI and SS3 final bytes are in 0x40..0x7e. */
                        if (c >= 0x40 && c <= 0x7e) break;
                    }
                } else {
                    if (vm->key_pushback_len < sizeof(vm->key_pushback))
                        vm->key_pushback[vm->key_pushback_len++] = second;
                }
            }
        } else {
            /* Return one complete UTF-8 scalar for ordinary text input. */
            int want = 1;
            unsigned char c = b[0];
            if ((c & 0xe0) == 0xc0) want = 2;
            else if ((c & 0xf0) == 0xe0) want = 3;
            else if ((c & 0xf8) == 0xf0) want = 4;
            while ((int)nread < want && nread < sizeof(b)) {
                int q = read_fd_timeout(0, b + nread, 1, 8);
                if (q <= 0) break;
                nread++;
            }
        }
        LObj *s = obj_new(vm, O_SOME);
        s->u.some.value = host_bytes(vm, b, nread);
        return v_obj(s);
    }
    case H_TERM_WRITE: {
        LObj *a = args[0].as.obj;
        unsigned char *b = xmalloc(a->u.array.len ? a->u.array.len : 1);
        for (size_t i = 0; i < a->u.array.len; i++)
            b[i] = (unsigned char)a->u.array.items[i].as.u;
        size_t off = 0;
        while (off < a->u.array.len) {
            ssize_t z = write(1, b + off, a->u.array.len - off);
            if (z <= 0) break;
            off += (size_t)z;
        }
        free(b);
        return v_unit();
    }
    case H_TERM_ROWS:
    case H_TERM_COLS: {
        struct winsize ws;
        if (ioctl(1, TIOCGWINSZ, &ws) < 0)
            return v_int(id == H_TERM_ROWS ? 24 : 80);
        return v_int(id == H_TERM_ROWS ? ws.ws_row : ws.ws_col);
    }
    case H_TERM_TEXT_WIDTH: {
        LObj *a = args[0].as.obj;
        size_t len = a->u.array.len;
        char *b = xmalloc(len + 1);
        for (size_t i = 0; i < len; i++)
            b[i] = (char)(unsigned char)a->u.array.items[i].as.u;
        b[len] = 0;
        mbstate_t st;
        memset(&st, 0, sizeof(st));
        size_t off = 0;
        uint64_t total = 0;
        int join_next = 0, regional = 0;
        while (off < len) {
            wchar_t wc = 0;
            size_t z = mbrtowc(&wc, b + off, len - off, &st);
            if (z == (size_t)-1 || z == (size_t)-2) {
                memset(&st, 0, sizeof(st));
                z = 1;
                total += 1;
                join_next = 0;
                regional = 0;
                off += z;
                continue;
            }
            if (z == 0) z = 1;
            uint32_t cp = (uint32_t)wc;
            if (cp == 0x200d) {
                join_next = 1;
                off += z;
                continue;
            }
            if ((cp >= 0xfe00 && cp <= 0xfe0f) ||
                (cp >= 0x1f3fb && cp <= 0x1f3ff)) {
                off += z;
                continue;
            }
            int w = wcwidth(wc);
            if (w == 0) {
                off += z;
                continue;
            }
            if (w < 0) w = 1;
            if (cp >= 0x1f1e6 && cp <= 0x1f1ff) {
                if (regional) {
                    regional = 0;
                    off += z;
                    continue;
                }
                total += 2;
                regional = 1;
                off += z;
                continue;
            }
            regional = 0;
            if (join_next) {
                join_next = 0;
                off += z;
                continue;
            }
            total += (uint64_t)w;
            off += z;
        }
        free(b);
        return v_int(total);
    }
    }
    die("unknown host function %d", id);
    return v_unit();
}

static int field_index(LObj *st, int field) {
    for (size_t i = 0; i < st->u.st.n; i++)
        if (st->u.st.fields[i].field == field) return (int)i;
    return -1;
}static LValue vm_call(LVM *vm, int fid, LValue *args, int argc) {
    if (fid < 0 || fid >= vm->p->function_count) die("bad function id");
    const LFunc *fn = &vm->p->functions[fid];
    if (argc != fn->param_count) die("arity mismatch");
    LFrame fr = {0};
    fr.fn = fn;
    fr.locals = calloc(fn->slot_count ? fn->slot_count : 1, sizeof(LValue));
    fr.active = calloc(fn->slot_count ? fn->slot_count : 1, 1);
    fr.prev = vm->frame;
    vm->frame = &fr;
    frame_scope_enter(&fr);
    for (int i = 0; i < argc; i++) {
        int s = fn->param_slots[i];
        fr.locals[s] = value_copy(vm, args[i]);
        fr.active[s] = 1;
    }
    size_t base_sp = vm->sp;
    LValue ret = v_unit();
    while (fr.ip < fn->ins_count) {
        const LIns *in = &fn->code[fr.ip++];
        switch (in->op) {
        case OP_PUSH_UNIT: pushv(vm, v_unit()); break;
        case OP_PUSH_NONE: pushv(vm, v_none()); break;
        case OP_PUSH_BOOL: pushv(vm, v_bool(in->a)); break;
        case OP_PUSH_INT:
            pushv(vm, v_int(mask_width(in->u, ty_width(in->a))));
            break;
        case OP_PUSH_FLOAT:
            pushv(vm, v_float(round_float(in->f, in->a)));
            break;
        case OP_MAKE_BYTES: {
            const LBlob *b = in->ptr;
            pushv(vm, v_obj(bytes_array(vm, b->data, b->len)));
            break;
        }
        case OP_MAKE_SOME: {
            LValue x = popv(vm);
            LObj *o = obj_new(vm, O_SOME);
            o->u.some.value = value_copy(vm, x);
            pushv(vm, v_obj(o));
            break;
        }
        case OP_MAKE_ARRAY: {
            int n = in->a;
            LObj *o = new_array(vm, n);
            for (int i = n - 1; i >= 0; i--)
                o->u.array.items[i] = value_copy(vm, popv(vm));
            pushv(vm, v_obj(o));
            break;
        }
        case OP_MAKE_REPEAT: {
            uint64_t n = popv(vm).as.u;
            LValue x = popv(vm);
            LObj *o = new_array(vm, (size_t)n);
            for (size_t i = 0; i < (size_t)n; i++)
                o->u.array.items[i] = value_copy(vm, x);
            pushv(vm, v_obj(o));
            break;
        }
        case OP_DECL: {
            LValue x = value_copy(vm, popv(vm));
            frame_decl(&fr, in->a, x);
            break;
        }
        case OP_LOAD:
            if (!fr.active[in->a]) die("inactive local");
            pushv(vm, value_copy(vm, fr.locals[in->a]));
            break;
        case OP_LOCAL_PLACE:
            if (!fr.active[in->a]) die("inactive local");
            pushv(vm, v_place(NULL, &fr.locals[in->a]));
            break;
        case OP_FIELD_PLACE: {
            LValue p = popv(vm);
            if (p.tag != V_PLACE) die("expected place");
            LValue b = *p.as.place.cell;
            LObj *owner = NULL;
            LValue *cell = field_cell(b, in->a, &owner);
            pushv(vm, v_place(owner, cell));
            break;
        }
        case OP_VALUE_FIELD_PLACE: {
            LValue b = popv(vm);
            LObj *owner = NULL;
            LValue *cell = field_cell(b, in->a, &owner);
            pushv(vm, v_place(owner, cell));
            break;
        }
        case OP_INDEX_PLACE: {
            LValue iv = popv(vm);
            LValue av = popv(vm);
            if (av.tag != V_OBJ || av.as.obj->kind != O_ARRAY)
                die("index place on non-array");
            size_t i = (size_t)iv.as.u;
            if (i >= av.as.obj->u.array.len) die("array index out of bounds");
            pushv(vm, v_place(av.as.obj, &av.as.obj->u.array.items[i]));
            break;
        }
        case OP_DEREF_PLACE: {
            LValue r = popv(vm);
            if (r.tag != V_OBJ || r.as.obj->kind != O_REF)
                die("deref place on non-ref");
            pushv(vm, v_place(r.as.obj, &r.as.obj->u.ref.value));
            break;
        }
        case OP_LOAD_PLACE: {
            LValue p = popv(vm);
            if (p.tag != V_PLACE) die("load place");
            pushv(vm, value_copy(vm, *p.as.place.cell));
            break;
        }
        case OP_STORE_PLACE: {
            LValue x = popv(vm);
            LValue p = popv(vm);
            if (p.tag != V_PLACE) die("store place");
            *p.as.place.cell = value_copy(vm, x);
            break;
        }
        case OP_DUP:
            if (!vm->sp) die("dup underflow");
            pushv(vm, vm->stack[vm->sp - 1]);
            break;
        case OP_POP: (void)popv(vm); break;
        case OP_SCOPE_ENTER: frame_scope_enter(&fr); break;
        case OP_SCOPE_ENTER_BINDINGS:
            frame_scope_enter(&fr);
            for (size_t i = 0; i < vm->pending_len; i++)
                frame_decl(&fr, vm->pending[i].slot,
                           value_copy(vm, vm->pending[i].value));
            pending_clear(vm);
            break;
        case OP_SCOPE_EXIT: frame_scope_exit(&fr); break;
        case OP_UNWIND: frame_unwind(&fr, in->a); break;
        case OP_NO_BINDINGS: pending_clear(vm); break;
        case OP_DROP_BINDINGS: pending_clear(vm); break;
        case OP_JUMP: fr.ip = in->a; break;
        case OP_JUMP_IF_FALSE: {
            LValue x = popv(vm);
            if (!truth(x)) fr.ip = in->a;
            break;
        }
        case OP_JUMP_IF_FALSE_KEEP:
            if (!truth(vm->stack[vm->sp - 1])) fr.ip = in->a;
            break;
        case OP_JUMP_IF_TRUE_KEEP:
            if (truth(vm->stack[vm->sp - 1])) fr.ip = in->a;
            break;
        case OP_LEN: {
            LValue a = popv(vm);
            if (a.tag != V_OBJ || a.as.obj->kind != O_ARRAY)
                die("len non-array");
            pushv(vm, v_int(a.as.obj->u.array.len));
            break;
        }
        case OP_LOCAL_INC_U64:
            if (!fr.active[in->a]) die("bad local inc");
            fr.locals[in->a].as.u++;
            break;
        case OP_INDEX: {
            LValue iv = popv(vm);
            LValue av = popv(vm);
            if (av.tag != V_OBJ || av.as.obj->kind != O_ARRAY)
                die("index non-array");
            size_t i = (size_t)iv.as.u;
            if (i >= av.as.obj->u.array.len) die("array index out of bounds");
            pushv(vm, value_copy(vm, av.as.obj->u.array.items[i]));
            break;
        }
        case OP_GET_FIELD: {
            LValue b = popv(vm);
            LObj *owner = NULL;
            LValue *cell = field_cell(b, in->a, &owner);
            pushv(vm, value_copy(vm, *cell));
            break;
        }
        case OP_DEREF: {
            LValue r = popv(vm);
            if (r.tag != V_OBJ || r.as.obj->kind != O_REF)
                die("deref non-ref");
            pushv(vm, value_copy(vm, r.as.obj->u.ref.value));
            break;
        }
        case OP_UNARY: {
            LValue x = popv(vm);
            pushv(vm, scalar_unary(in->a, x, in->b));
            break;
        }
        case OP_BIN: {
            LValue b = popv(vm);
            LValue a = popv(vm);
            pushv(vm, scalar_bin(vm, in->a, a, b, in->b));
            break;
        }
        case OP_CAST: {
            LValue x = popv(vm);
            pushv(vm, cast_value(x, in->a, in->b));
            break;
        }
        case OP_NEW: {
            LValue x = popv(vm);
            LObj *o = obj_new(vm, O_REF);
            o->u.ref.value = value_copy(vm, x);
            pushv(vm, v_obj(o));
            break;
        }
        case OP_MAKE_STRUCT: {
            const int *fields = in->ptr;
            int n = in->b;
            LObj *o = obj_new(vm, O_STRUCT);
            o->u.st.name = in->a;
            o->u.st.n = n;
            o->u.st.fields = xmalloc(sizeof(LField) * n);
            for (int i = n - 1; i >= 0; i--) {
                o->u.st.fields[i].field = fields[i];
                o->u.st.fields[i].value = value_copy(vm, popv(vm));
            }
            pushv(vm, v_obj(o));
            break;
        }
        case OP_MAKE_ENUM_ZERO: {
            LObj *o = obj_new(vm, O_ENUM);
            o->u.en.name = in->a;
            o->u.en.variant = in->b;
            pushv(vm, v_obj(o));
            break;
        }
        case OP_MAKE_ENUM: {
            int n = in->c;
            LObj *o = obj_new(vm, O_ENUM);
            o->u.en.name = in->a;
            o->u.en.variant = in->b;
            o->u.en.n = n;
            o->u.en.items = xmalloc(sizeof(LValue) * n);
            for (int i = n - 1; i >= 0; i--)
                o->u.en.items[i] = value_copy(vm, popv(vm));
            pushv(vm, v_obj(o));
            break;
        }
        case OP_PUSH_FUNC: pushv(vm, v_func(in->a)); break;
        case OP_CALL_NAMED: {
            int n = in->b;
            LValue *av = xmalloc(sizeof(LValue) * n);
            for (int i = n - 1; i >= 0; i--) av[i] = popv(vm);
            LValue r = vm_call(vm, in->a, av, n);
            free(av);
            pushv(vm, r);
            break;
        }
        case OP_CALL_VALUE: {
            int n = in->a;
            LValue *av = xmalloc(sizeof(LValue) * n);
            for (int i = n - 1; i >= 0; i--) av[i] = popv(vm);
            LValue f = popv(vm);
            LValue r;
            if (f.tag == V_FUNC) r = vm_call(vm, f.as.id, av, n);
            else if (f.tag == V_HOSTFN) r = host_call(vm, f.as.id, av, n);
            else die("not callable");
            free(av);
            pushv(vm, r);
            break;
        }
        case OP_HOST_MEMBER: pushv(vm, v_host(in->a)); break;
        case OP_ARRAY_PUSH: {
            LValue x = popv(vm);
            LValue a = popv(vm);
            if (a.tag != V_OBJ || a.as.obj->kind != O_ARRAY)
                die("push non-array");
            array_reserve(a.as.obj, a.as.obj->u.array.len + 1);
            a.as.obj->u.array.items[a.as.obj->u.array.len++] =
                value_copy(vm, x);
            pushv(vm, v_unit());
            break;
        }
        case OP_ARRAY_POP: {
            LValue a = popv(vm);
            if (a.tag != V_OBJ || a.as.obj->kind != O_ARRAY ||
                !a.as.obj->u.array.len)
                die("pop empty/non-array");
            LValue x = value_copy(
                vm, a.as.obj->u.array.items[--a.as.obj->u.array.len]);
            pushv(vm, x);
            break;
        }
        case OP_ARRAY_SPLICE: {
            LValue repl = popv(vm);
            LValue endv = popv(vm);
            LValue startv = popv(vm);
            LValue a = popv(vm);
            if (a.tag != V_OBJ || a.as.obj->kind != O_ARRAY ||
                repl.tag != V_OBJ || repl.as.obj->kind != O_ARRAY)
                die("splice non-array");
            size_t start = (size_t)startv.as.u;
            size_t end = (size_t)endv.as.u;
            if (start > end || end > a.as.obj->u.array.len)
                die("splice bounds");
            size_t rn = repl.as.obj->u.array.len;
            LValue *tmp = rn ? xmalloc(sizeof(LValue) * rn) : NULL;
            for (size_t i = 0; i < rn; i++)
                tmp[i] = value_copy(vm, repl.as.obj->u.array.items[i]);
            size_t old = a.as.obj->u.array.len;
            size_t newn = old - (end - start) + rn;
            array_reserve(a.as.obj, newn);
            memmove(a.as.obj->u.array.items + start + rn,
                    a.as.obj->u.array.items + end,
                    (old - end) * sizeof(LValue));
            for (size_t i = 0; i < rn; i++)
                a.as.obj->u.array.items[start + i] = tmp[i];
            free(tmp);
            a.as.obj->u.array.len = newn;
            pushv(vm, v_unit());
            break;
        }
        case OP_SAVE_MATCH_VALUE:
            vm->match_value = popv(vm);
            vm->has_match = 1;
            break;
        case OP_LOAD_MATCH_VALUE:
            pushv(vm, value_copy(vm, vm->match_value));
            break;
        case OP_CLEAR_MATCH_VALUE:
            vm->has_match = 0;
            vm->match_value = v_unit();
            break;
        case OP_TRY_PATTERN: {
            LValue x = popv(vm);
            pending_clear(vm);
            int ok = pattern_match(vm, in->a, x);
            pushv(vm, ok ? v_bool(1) : v_none());
            break;
        }
        case OP_PATTERN_TO_BOOL: {
            LValue x = popv(vm);
            pushv(vm, v_bool(x.tag != V_NONE));
            break;
        }
        case OP_JUMP_IF_NO_MATCH: {
            LValue x = popv(vm);
            if (x.tag == V_NONE) fr.ip = in->a;
            break;
        }
        case OP_TRAP_MATCH: die("match fell through"); break;
        case OP_TRAP: die("trap"); break;
        case OP_RET:
            ret = value_copy(vm, popv(vm));
            vm->sp = base_sp;
            goto done;
        default: die("bad opcode %d", in->op);
        }
        gc_maybe(vm);
    }
    ret = v_unit();
    vm->sp = base_sp;
done:
    vm->frame = fr.prev;
    free(fr.locals);
    free(fr.active);
    free(fr.declared);
    free(fr.scopes);
    return ret;
}

static void vm_cleanup(LVM *vm) {
    if (vm->term_screen) {
        static const char seq[] = "\x1b[0m\x1b[?25h\x1b[?1049l";
        (void)write(1, seq, sizeof(seq) - 1);
        vm->term_screen = 0;
    }
    if (vm->term_raw) {
        tcsetattr(0, TCSANOW, &vm->saved_term);
        vm->term_raw = 0;
    }
    linux_host_cleanup(vm);
    for (Proc *p = vm->procs; p;) {
        Proc *n = p->next;
        proc_close_one(p);
        free(p);
        p = n;
    }
    vm->procs = NULL;
    vm->sp = 0;
    vm->frame = NULL;
    vm->pending_len = 0;
    vm->has_match = 0;
    gc_collect(vm);
    while (vm->objects) {
        LObj *o = vm->objects;
        vm->objects = o->next;
        if (o->kind == O_ARRAY) free(o->u.array.items);
        else if (o->kind == O_STRUCT) free(o->u.st.fields);
        else if (o->kind == O_ENUM) free(o->u.en.items);
        free(o);
    }
    free(vm->stack);
    free(vm->pending);
}

int lvm_run(const LProgram *program, int argc, char **argv) {
    setlocale(LC_CTYPE, "");
    LVM vm = {0};
    g_vm = &vm;
    install_runtime_cleanup();
    vm.p = program;
    vm.argc = argc;
    vm.argv = argv;
    vm.gc_threshold = 4096;
    LValue r = vm_call(&vm, program->entry_function, NULL, 0);
    int status = 0;
    if (r.tag == V_INT) status = (int)(r.as.u & 255);
    else if (r.tag == V_BOOL) status = r.as.u ? 0 : 1;
    vm_cleanup(&vm);
    g_vm = NULL;
    return status;
}