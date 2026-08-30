# Current implementation/tooling status

## Bootstrap/reference frontend

`bootstrap/core.py` contains the current lexer/parser/checker/tree interpreter/module linker/host-module model.

`bootstrap/bytecode.py` contains the bytecode compiler/VM.

The bootstrap compiler is Python, intentionally chosen for iteration speed and inspectability.

## Native path

The current repository toolchain compiles checked L bytecode into a generated C translation unit containing a native VM/runtime, then invokes `cc -O3`.

This means shipped L tools run without Python, but the compiler frontend itself is not yet self-hosted.

`runtime/native_vm.c` includes the native runtime and tracing GC used by that path.

## Tools written in L

Source is under `tools/`:

- Lace terminal modal editor;
- L language server;
- JSON language server;
- INI language server;
- shared server framework.

These programs were used as language stress tests. They are optional applications, not part of Core.

## Repository launchers and generated binaries

Top-level `./lace`, `./l-lsp`, `./json-lsp`, and `./ini-lsp` are small source-repository launchers. They build native tools into the ignored `build/` directory on demand using `./build.sh`, then execute them. Native binaries are intentionally not committed.

`./lc` and `./lr` are Python-bootstrap compiler/runner drivers. See the historical build notes under `notes/` for earlier snapshot measurements.

## Known implementation maturity caveats

- the bootstrap compiler is not self-hosted;
- the draft Core spec is being extracted after an implementation-led design process, so discrepancies should be reported;
- floating-point semantics deserve additional independent review;
- the core conformance corpus in this review bundle is a seed rather than a standards-grade suite;
- package management and a permanent standard-library API are intentionally unspecified.
