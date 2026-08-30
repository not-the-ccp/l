# Code analysis and flowcharts

`./lc analyze` is the source-analysis frontend for L. It uses the same bootstrap lexer/parser as the compiler and, by default, runs the normal project linker/type-checker before producing analysis output. The graph model is therefore derived from L syntax and control-flow constructs, not from text matching.

The analyzer is intentionally optional tooling. It is not part of L Core and does not affect language semantics.

## Quick use

```sh
# Human-readable metrics and findings.
./lc analyze examples/hosted/hello.l

# Compile every function in the project into a Mermaid control-flow chart.
./lc analyze examples/hosted/hello.l --flowchart -o hello.mmd

# One function only. A simple name is accepted when unambiguous.
./lc analyze examples/hosted/project/main.l --flowchart --function main -o main.mmd

# Graphviz DOT, or an SVG if Graphviz `dot` is installed.
./lc analyze examples/hosted/project/main.l --view cfg --format dot -o main.dot
./lc analyze examples/hosted/project/main.l --view cfg --format svg -o main.svg

# Inter-function call graph.
./lc analyze examples/hosted/project/main.l --call-graph -o calls.mmd

# Machine-readable analysis model and raw parser AST.
./lc analyze examples/hosted/project/main.l --view model > analysis.json
./lc analyze examples/hosted/project/main.l --ast > ast.json
```

`--root` has the same project-root meaning as the other bootstrap drivers. Imported bundled standard-library modules are type-checked but omitted from analysis output by default; pass `--include-stdlib` to include them. `--no-check` is available for parser/CFG work on incomplete programs.

## Views

The `report` view is the default. Per function it reports source extent, statement/decision/loop counts, a structured cyclomatic-complexity estimate, maximum control nesting, returns/traps, direct calls, and syntactically unreachable statements following non-fallthrough control flow.

The `model` view serializes the reusable analysis model as JSON: module/import/declaration information, function metrics, call sites and resolution status, unreachable lines, and the complete control-flow graph as nodes and labeled edges.

The `ast` view serializes the parser AST, including source spans and types when present on nodes.

The `cfg` view exports per-function control-flow graphs. `if`, `while`, C-style `for`, `for-in`, and `match` become decision nodes; `return` and `trap` terminate at function exit; `break` and `continue` become explicit loop jumps; normal branch fallthroughs get merge nodes. Formats are `mermaid`, `dot`, `svg`, and `json`.

The `calls` view exports the call graph. Calls to same-project functions are resolved when the spelling is statically obvious (local top-level functions and imported-module member calls). Function-valued/indirect calls remain explicitly marked as indirect/external instead of being guessed. Formats are `mermaid`, `dot`, `svg`, and `json`.

## Complexity model

`cyclomatic_complexity` is a source-structure metric, currently:

```text
1
+ one for each if
+ one for each while / for / for-in
+ (number of match arms - 1) for each match
```

Short-circuit `&&` / `||` operators are counted separately as `short_circuit_ops`; they are not currently expanded into separate CFG nodes, so they are intentionally excluded from the headline complexity number. This keeps the metric consistent with the graph abstraction rather than pretending the CFG is lower-level than it is.

## Scope and intended extension points

`bootstrap/analyze.py`, `bootstrap/analysis_model.py`, and `bootstrap/analysis_cfg.py` separate project loading/CLI, AST analysis/modeling, CFG construction, call resolution, and graph rendering. Additional analyses should consume the shared model or add fields to it rather than reparsing source independently. Natural extensions include data-flow/liveness, def-use chains, constant propagation views, dominators, loop nesting/irreducibility checks, typed call resolution, and editor/LSP visualization hooks.
