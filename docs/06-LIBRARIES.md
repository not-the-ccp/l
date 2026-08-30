# Optional library layers

## Portable libraries included

`lib/portable/` contains ordinary L source that should require no host capability:

- `arrays.l` — array algorithms built on Core primitives;
- `bytes.l` — byte/string helpers;
- `strconv.l` — scalar parsing/formatting helpers;
- `utf8.l` — UTF-8 algorithms over `[]u8`;
- `json.l` — JSON value/parser/formatter code;
- `lsp.l` — LSP/JSON-RPC protocol data helpers independent of process I/O;
- `slang_syntax.l` — an L lexer/parser-oriented syntax frontend written in L.

Their existence is evidence that L Core is usable, not a promise that these exact APIs form a permanent standard library.

## Hosted libraries included

`lib/hosted/` currently contains `lsp_client.l`, which depends on the optional `proc` host module.

## Standard-library policy proposed for review

The project should distinguish:

1. **Core builtins** — operations impossible or unreasonably expensive to express portably (`new`, `len`, `push`, `pop`, `splice`, primitive arithmetic/indexing/etc.).
2. **Portable standard library** — normal L source, versioned separately from Core when useful.
3. **Hosted standard library/profile** — wrappers around an environment's host modules.
4. **Third-party ecosystem** — ordinary modules/packages.

An implementer should be able to advertise “L Core 1.x compatible” without implementing layers 2–4.

## Why `splice` is core while `copy` is not

A generic array copy is easily expressible in L using indexing and `push`.

Efficiently inserting/removing a range cannot be expressed in a tiny VM without potentially executing one language operation per moved element. `splice` gives implementations a representation-independent bulk mutation primitive and proved important in the Lace editor workload.

This boundary is reviewable; if reviewers can demonstrate a better smaller primitive set, that is valuable feedback.
