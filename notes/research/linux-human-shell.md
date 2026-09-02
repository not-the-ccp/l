# Linux human shell experiment

This note records non-normative design hypotheses and executable experiments for a new interactive shell implemented in L. It is not a compatibility plan for POSIX shell, Bash, Zsh, Fish, or any other command language.

## Product target

The primary user is a person sitting at a Linux terminal. The language should optimize for issuing, inspecting, composing, correcting, and repeating commands. Batch scripting is secondary.

The shell may execute ordinary Linux programs, but its own command language has no compatibility obligation to existing shell languages.

The implementation should use Linux facilities directly. It must not evaluate command text by invoking `/bin/sh` or another shell.

## Design constraints

1. Command text must become an argv vector and an explicit process/FD plan before execution.
2. Substitution must not silently change argument count.
3. Substitution must not manufacture syntax or operators.
4. Ordinary punctuation inside an argument should remain ordinary data unless the complete token is an operator.
5. File descriptors and byte streams are the native interoperability boundary for external programs.
6. Structured values may be added above that boundary, but ordinary external pipelines must not require serialization through a shell-specific data format.
7. Process identity and job identity are separate concepts.
8. Interactive parsing, highlighting, completion, and execution must share the same parser.
9. Shell-specific operating-system behavior belongs in a Linux hosted module, not L Core.

## Language lab, pass 1

The first parser accepted forms such as:

```text
printf "hello world"|wc -c
build err>errors.log >output.log &
```

This made punctuation adjacent to ordinary data syntactic. It reproduced a traditional shell property without a requirement from Linux and forced otherwise harmless arguments such as `a|b` or `x>y` to be quoted.

The experiment was revised rather than preserved for familiarity.

## Language lab, pass 2

Operators are complete, unquoted, whitespace-delimited tokens:

```text
printf "hello world" | wc -c
build err> errors.log > output.log &
```

The following are ordinary arguments:

```text
a|b
x>y
foo&bar
err>file
>output
```

Quoted operator-looking text is also data:

```text
"|"
'&'
"err>"
```

Double quotes provide grouping with only `\"` and `\\` escapes in the current experiment. Single quotes are raw grouping. Quoted and unquoted segments concatenate inside one argument:

```text
pre"middle space"post
```

The parser test suite includes these cases.

### Open notation question

The pass-2 tokens `>`, `err>`, `all>`, and `&` are experimental. Familiarity is not sufficient justification for retaining them.

A later usability pass should compare at least:

```text
command > file
command err> file
command all> file
command &
```

against more explicit forms that do not rely on traditional shell notation. The comparison should include typing cost, readability in history, completion behavior, accidental syntax, and how naturally the notation extends to stdin, append, null routing, and named descriptors.

`|` has a stronger independent justification because it is a compact visual connection between two stream endpoints, but it is also provisional.

## Word semantics before substitution

The current AST stores fully materialized literal argv words because the first executable slice has no variables, globbing, or command capture.

That representation must change before adding substitution. A future word node should retain literal and substituted segments so the evaluator can enforce these properties:

- a scalar substitution contributes exactly one argument;
- a list contributes multiple arguments only through explicit spreading;
- substituted bytes never become operators;
- substituted bytes never implicitly undergo whitespace splitting;
- substituted bytes never implicitly become a pathname pattern;
- pathname expansion is represented as an explicit word operation rather than reparsing generated text.

This is more important than choosing the final sigil for variables.

## External pipeline model

External programs communicate through Linux file descriptors and byte streams. A pipeline is an execution graph, not a string to reparse.

Conceptually:

```text
rg TODO src | sort
```

becomes:

```text
job
  process 0
    argv: [rg, TODO, src]
    stdout: pipe 0 write end
  process 1
    argv: [sort]
    stdin: pipe 0 read end
```

Redirections are edges to files or inherited descriptors in the same graph.

Structured shell values can later coexist with this model through explicit producers/consumers or in-process stages. They should not redefine what an external program receives on fd 0 or emits on fd 1.

## Linux process substrate

The existing reference `proc` host module is suitable for simple child-process clients but not for an interactive shell. Its spawn operation fixes stdin/stdout to pipes and does not expose the descriptor graph needed by a shell.

The shell-specific Linux host layer should be built around:

- close-on-exec file descriptors and `pipe2`;
- an explicit descriptor mapping passed to child creation;
- `clone3(CLONE_PIDFD)` where available so child creation returns a pidfd atomically;
- pidfds as stable process handles;
- `pidfd_send_signal` for process-targeted signals;
- process groups for jobs and terminal ownership;
- parent and child `setpgid` attempts during launch to close the traditional process-group race;
- `tcgetpgrp`/`tcsetpgrp` for controlling-terminal foreground ownership;
- `signalfd` for shell-handled signals;
- `epoll` as the event-loop boundary for terminal input, pidfds, signalfd, pipes, and future watchers;
- `waitid`/child status reporting that preserves exited, signalled, stopped, and continued states.

A pidfd and a process-group ID are deliberately different values. A pidfd identifies one process without PID-reuse races. A process group identifies a job for terminal ownership and group-directed signals.

The L-facing API should expose opaque handles rather than raw integer file descriptors wherever possible. `fork()` should not be exposed to L code: child setup and exec belong in the native host implementation so the L runtime and collector never have to operate in an unsafe post-fork child.

## Runtime API experiment to build next

The next executable substrate should be capable of constructing this without another shell:

```text
printf foo | tr o a | wc -c
```

and then this under a pseudo-terminal:

```text
sleep 60
interrupt

sleep 60
stop
resume in background
bring to foreground
interrupt
```

Acceptance requires correct descriptor closure, no leaked writers keeping pipes alive, correct process-group membership, terminal transfer and restoration, and complete child reaping.

The API should be revised from those tests rather than generalized in advance.
