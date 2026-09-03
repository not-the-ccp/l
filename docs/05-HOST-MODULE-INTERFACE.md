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

The original reference profile supplies modules roughly corresponding to:

```text
stdio  byte input/output
fs     read/write whole files
sys    argv, executable path, environment lookup
proc   convenience child processes and pipes
term   raw/fullscreen terminal, timed input, display width
```

These names/signatures are **reference profile APIs, not Core language requirements**.

## Linux low-level profile

Linux implementations may additionally expose a lower-level profile for programs that need explicit descriptor and process control. This profile is not a compatibility layer for POSIX shell behavior.

### `linux.fd`

`linux.fd.Fd` is an opaque handle that owns one Linux file descriptor. Copying an L value aliases the same handle; it does not duplicate the descriptor. `dup` creates a new independently owned descriptor. `close` is idempotent for a handle, and operations through any alias after close trap.

The initial API is:

```text
stdin() -> Fd
stdout() -> Fd
stderr() -> Fd
dup(Fd) -> Fd
pipe() -> []Fd
close(Fd)
read(Fd, u64) -> ?[]u8
write(Fd, const []u8) -> u64
```

`stdin`, `stdout`, and `stderr` return owned duplicates rather than borrowed global descriptors. `pipe()` returns exactly two entries: read end then write end.

`read` and `write` are deliberately partial operations. `read` returns `none` only for EOF; `some(bytes)` contains one successful read, which may be shorter than requested. `write` returns the number of bytes written and may be shorter than its input. Higher-level `read_all`/`write_all` behavior belongs in ordinary L libraries rather than being hidden in the host primitive.

### `linux.process`

A `Child` identifies one child process. A `Group` identifies a process group; process identity and job/group identity are separate concepts. Implementations should use pidfds for stable child identity where available rather than treating a numeric PID as the public handle.

The initial execution API takes an exact executable path and explicit standard descriptors:

```text
spawn_exact(
    path: const []u8,
    argv: const []const []u8,
    stdin: linux.fd.Fd,
    stdout: linux.fd.Fd,
    stderr: linux.fd.Fd,
    group: ?Group,
) -> SpawnResult

spawn_child(SpawnResult) -> ?Child
spawn_error(SpawnResult) -> ?i64
group(Child) -> Group
wait_exit(Child) -> ExitStatus
exit_code(ExitStatus) -> ?i64
term_signal(ExitStatus) -> ?i64
```

`spawn_exact` does no PATH search and invokes no command-language interpreter. `argv[0]` is supplied by the caller independently of the executable path.

Launch failure is distinct from process termination. If child setup or `execve` fails, `spawn_child` is `none` and `spawn_error` contains the Linux errno value. If execution succeeds, `spawn_child` contains a child and `spawn_error` is `none`. Implementations must establish that distinction synchronously across the exec boundary; callers should not need a separate `access`/`stat` precheck, which would race with execution.

`wait_exit` consumes the terminal state of a child and may be called once. `exit_code` is present only for normal exit; `term_signal` is present only for signal termination. Stopped and continued job-control events are intentionally not collapsed into this API; they require a separate event-oriented interface.

The exact current reference implementation lives in `bootstrap/run_lang.py`, `bootstrap/linux_host.py`, and `runtime/native_vm.c` as applicable to each profile.
