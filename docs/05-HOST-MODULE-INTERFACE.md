# Optional host-module interface

Host modules are how an implementation/environment exposes capabilities that are not portable language semantics.

This boundary replaces a mandatory C FFI, OS API, or baked-in standard environment.

## Semantic model

A host module has a logical module name and may expose:

- typed functions;
- typed constants;
- opaque nominal types.

L source imports it exactly like a source module:

```text
import files;
```

The resolver decides whether `files` denotes source code or a host module. Source code cannot observe the implementation distinction except through the API's behavior.

## Opaque host values

A host can expose a nominal type such as `files.File`. L can store/pass it but cannot inspect representation, perform pointer arithmetic, or reinterpret it.

The host is responsible for the lifetime/resource semantics of such values. Those semantics should be documented by the hosted profile/API rather than silently generalized into Core.

## GC interaction

If host code retains an L-managed `ref` or `[]T` beyond a call, a native embedding API must keep that value visible to the language collector (for example by registering an external root).

Opaque host values are atomic with respect to Core tracing unless an implementation explicitly defines a richer embedding mechanism.

## Reference Unix-like host profile

The included prototype currently supplies modules roughly corresponding to:

```text
stdio  byte input/output
fs     read/write whole files
sys    argv, executable path, environment lookup
proc   child processes, pipes, shell command, timed reads
term   raw/fullscreen terminal, timed input, display width
```

These names/signatures are **reference profile APIs, not Core language requirements**.

The exact current implementation lives in `bootstrap/run_lang.py` and `runtime/native_vm.c`.
