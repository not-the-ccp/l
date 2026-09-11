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

The exact current implementation lives in `src/hosts/run.py` and `src/vm/vm.c`.

## Recoverable host callbacks

Hosted applications such as Lace invoke trusted in-process L extension callbacks through a recoverable boundary so a faulty extension is reported and contained instead of taking down the host process. This is an embedding facility, not a language feature: L gains no exception semantics from it, and ordinary standalone programs keep fatal-on-unhandled-error behavior.

Native boundary (`src/vm/embed.c`, `src/vm/embed.h`):

- `lvm_context_find_function` resolves a zero-argument L function id by its compiled name; no extra compiler metadata is required.
- `lvm_context_call_function` runs it and returns `LVM_CALL_OK` (normal return; status holds the process-style exit code), `LVM_CALL_TRAP` (contained trap or runtime failure; message holds the diagnostic), or `LVM_CALL_USAGE` (invalid host use; nothing was invoked).
- Only zero-parameter functions are invocable, and the L return value maps to a small status integer, keeping the internal value layout out of the embedding ABI.

Python twin (`src/hosts/host_boundary.py`): `HostBoundary.call` returns `CallOk(value)` or `CallTrap(message)` over checkpointable hosts (`src/hosts/run.py`, `src/hosts/linux_host.py`).

State guarantees (both boundaries):

- Transient interpreter state (frames, operand stack, pending bindings, match state), newly acquired native handles (closed but valid, never dangling), and terminal/input state are restored to the entry snapshot.
- Heap object-graph mutations are not rolled back: completed side effects on pre-existing L state persist.
- Out-of-memory inside bookkeeping remains process-fatal.
- Boundaries nest: an inner trap reports to the inner caller while the outer boundary stays armed.
- Runaway extension recursion is contained as a trap, not a crash.

The host owns the policy after a `TRAP` result: disable the extension, report the error, or continue. The boundary is covered by `tests/host_callback.py`.
