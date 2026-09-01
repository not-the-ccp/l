# L 0.8 / Lace 0.8 build record

Final development bundle build date: 2026-08-30.

## Build environment

```text
Python 3.13.5
cc (Debian 14.2.0-19) 14.2.0
Linux 6.18.35 x86_64 GNU/Linux
```

Native L programs are built with the bootstrap frontend and a C translation unit containing checked L bytecode + the native VM/runtime, then `cc -std=gnu11 -O3 -DNDEBUG`.

The shipped `lace`, `l-lsp`, `json-lsp`, and `ini-lsp` files are x86-64 ELF PIE executables.

## Native binary SHA-256

```text
cc5a6f2e37f6f30dd16163eb2694944b7cc46c78a4988d67ad59b76a64f5a9ab  lace
11238b472b7da9da0d2f0426bb6a6e48f0f5d1b3979d28eae0ee27cfa6d0b58d  l-lsp
6a69987e419cdbc25499ee320ff01bcda81e243abaf15e7a85d93962e1dc8d37  json-lsp
370cd04446e5cb4f45377de5994172a354652d954d8d42434cf8e6a83a93d8e2  ini-lsp
```

## Final regression pass

`./smoke-test.sh` passed with:

```text
incremental UTF-16 LSP PASS
editor terminal/shell safety PASS
highlight cache stability PASS
lace usability PTY PASS
lace terminal cell positioning PASS
native editor + exact incremental JSON LSP PASS
L 0.8 / Lace 0.8 smoke test PASS
```

The terminal safety test covers dirty-buffer `Ctrl-C`, `:!` shell suspension/return, interrupting a child command without killing Lace, and restoration after an L runtime trap.

The display-positioning test covers tabs, CJK wide text, combining marks, a ZWJ emoji sequence, and a regional-indicator flag pair.

## Editor benchmark

PTY benchmark using the compiled Lace editor with the compiled L LSP enabled:

```text
file       startup      insert     newline  post-sync-motion
  10 KiB      50.5 ms     40.1 ms     24.8 ms      41.5 ms
 100 KiB     126.3 ms     30.1 ms     22.3 ms      35.6 ms
 500 KiB     477.2 ms     35.5 ms     23.8 ms      37.2 ms
1024 KiB     939.6 ms     21.6 ms     27.3 ms      38.5 ms
```

Startup includes loading/indexing the file and starting the adjacent language server. Interactive edits use incremental document synchronization and viewport semantic tokens; their latency does not scale linearly with the whole document.

## Known scope / limitations

- `lc` remains a Python bootstrap compiler frontend. Its generated programs are native executables; the compiler itself is not self-hosted yet.
- Lace is intentionally single-buffer/single-window today. It is a usable small editor, not yet a replacement for every Vim/Helix workflow.
- Its grapheme/display handling deliberately covers common terminal cases but is not a complete implementation of every Unicode grapheme-width rule across every terminal/font.
- LSP support is a useful subset, not the complete LSP specification.
- Prebuilt ELF files target the build environment above; run `./rebuild-tools.sh` on another Linux system if needed.
