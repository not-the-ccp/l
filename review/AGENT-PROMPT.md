# Ready-made prompt for an AI reviewer

You are reviewing the attached L programming-language bundle.

Be adversarial, technical, and evidence-driven. Do not assume the current designers are correct. Actually inspect and run the implementation/tests; write L programs; create small experiments where useful.

The central goal is a small serious C-family language that is unusually easy to parse, interpret, compile, embed, and tool. It should support ordinary programming—including recursive data structures and reusable libraries—without accumulating mechanisms that mostly serve convenience.

Important: L Core is intentionally separated from optional portable libraries, hosted APIs, and tooling. Do not criticize Core for lacking filesystem/JSON/etc. unless you can show that the capability cannot cleanly live outside Core.

Please produce a Markdown review with:

1. **Executive verdict** — whether the current design meets its goals.
2. **Critical issues** — correctness, soundness, ambiguity, contradictions, or architectural flaws.
3. **Complexity audit** — features that are more expensive to implement/tool than claimed.
4. **Usability audit** — real programming patterns that are awkward or surprising.
5. **Core-vs-library audit** — things in the wrong layer.
6. **Generics/memory/modules/numeric semantics audit**.
7. **Implementation audit** — bugs or spec/implementation divergence found by running experiments.
8. **Feature proposals** — only when justified; include concrete examples and implementation cost.
9. **Features you explicitly think should remain absent**.
10. **Prioritized recommendations** — must-fix / should-fix / optional / reject.

For each important finding, include:

- minimal reproducer where possible;
- expected vs current behavior;
- whether it is a Core, library, host, or tooling issue;
- why the change improves the project goals;
- likely implementation/tooling complexity.

Return one self-contained Markdown file suitable for sending back to the project designer.
