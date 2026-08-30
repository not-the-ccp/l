from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from typing import Iterable

from core import N


@dataclass
class CFGNode:
    id: str
    kind: str
    label: str
    line: int | None = None
    col: int | None = None
    synthetic: bool = False


@dataclass
class CFGEdge:
    source: str
    target: str
    label: str | None = None
    kind: str = "flow"


@dataclass
class LoopContext:
    break_target: str
    continue_target: str
    break_used: bool = False


def compact(text: str, limit: int = 140) -> str:
    text = re.sub(r"\s+", " ", text.strip())
    return text if len(text) <= limit else text[:limit - 1] + "…"


class CFGBuilder:
    def __init__(self, source: str):
        self.source = source
        self.nodes: list[CFGNode] = []
        self.edges: list[CFGEdge] = []
        self.serial = 0
        self.unreachable: set[int] = set()
        self.max_nesting = 0
        self.entry = self.node("entry", "entry", synthetic=True)
        self.exit = self.node("exit", "exit", synthetic=True)

    def node(self, kind: str, label: str, ast: N | None = None, synthetic: bool = False) -> str:
        ident = f"n{self.serial}"
        self.serial += 1
        sp = getattr(ast, "span", None)
        self.nodes.append(CFGNode(ident, kind, compact(label), getattr(sp, "line", None), getattr(sp, "col", None), synthetic))
        return ident

    def edge(self, src: str, dst: str, label: str | None = None, kind: str = "flow") -> None:
        self.edges.append(CFGEdge(src, dst, label, kind))

    def connect(self, frontier: list[tuple[str, str | None]], dst: str) -> None:
        for src, label in frontier:
            self.edge(src, dst, label)

    def text(self, ast: N | None, fallback: str = "?") -> str:
        sp = getattr(ast, "span", None)
        if sp is None:
            return fallback
        try:
            return self.source[sp.start:sp.end].strip() or fallback
        except Exception:
            return fallback

    def stmt_text(self, stmt: N) -> str:
        if stmt.kind == "assign":
            lhs, op, rhs = stmt.a
            return f"{self.text(lhs)} {op} {self.text(rhs)}"
        if stmt.kind == "var":
            name, ty, expr = stmt.a
            return f"var {name}{': ' + str(ty) if ty is not None else ''} = {self.text(expr)}"
        if stmt.kind == "exprstmt":
            return self.text(stmt.a[0])
        if stmt.kind == "return":
            return "return" if stmt.a[0] is None else f"return {self.text(stmt.a[0])}"
        return self.text(stmt, stmt.kind)

    def build(self, body: tuple[N, ...]) -> tuple[list[CFGNode], list[CFGEdge], list[int], int]:
        out = self.block(body, [(self.entry, None)], None, 0)
        for src, label in out:
            self.edge(src, self.exit, label)
        return self.nodes, self.edges, sorted(self.unreachable), self.max_nesting

    def block(self, body: Iterable[N], frontier: list[tuple[str, str | None]], loop: LoopContext | None, depth: int):
        self.max_nesting = max(self.max_nesting, depth)
        cur = list(frontier)
        for stmt in body:
            if not cur and getattr(stmt, "span", None) is not None:
                self.unreachable.add(stmt.span.line)
            cur = self.stmt(stmt, cur, loop, depth)
        return cur

    def stmt(self, stmt: N, frontier: list[tuple[str, str | None]], loop: LoopContext | None, depth: int):
        k = stmt.kind
        if k == "if":
            cond, yes, no = stmt.a
            d = self.node("decision", f"if {self.text(cond)}", stmt)
            self.connect(frontier, d)
            a = self.block(yes, [(d, "yes")], loop, depth + 1)
            b = self.block(no, [(d, "no")], loop, depth + 1) if no else [(d, "no")]
            outs = a + b
            if not outs:
                return []
            m = self.node("merge", "merge", synthetic=True)
            self.connect(outs, m)
            return [(m, None)]

        if k == "while":
            cond, body = stmt.a
            d = self.node("decision", f"while {self.text(cond)}", stmt)
            self.connect(frontier, d)
            after = self.node("merge", "after while", synthetic=True)
            self.edge(d, after, "no")
            ctx = LoopContext(after, d)
            for src, label in self.block(body, [(d, "yes")], ctx, depth + 1):
                self.edge(src, d, label or "next", "back")
            return [(after, None)]

        if k == "forin":
            name, expr, body = stmt.a
            d = self.node("decision", f"for {name} in {self.text(expr)}", stmt)
            self.connect(frontier, d)
            after = self.node("merge", "after for", synthetic=True)
            self.edge(d, after, "done")
            ctx = LoopContext(after, d)
            for src, label in self.block(body, [(d, "next")], ctx, depth + 1):
                self.edge(src, d, label or "next", "back")
            return [(after, None)]

        if k == "for":
            init, cond, step, body = stmt.a
            cur = list(frontier)
            if init is not None:
                n = self.node("stmt", "for init: " + self.stmt_text(init), init)
                self.connect(cur, n)
                cur = [(n, None)]
            d = self.node("decision", "for true" if cond is None else f"for {self.text(cond)}", stmt)
            self.connect(cur, d)
            after = self.node("merge", "after for", synthetic=True)
            if cond is not None:
                self.edge(d, after, "no")
            step_node = None
            if step is not None:
                step_node = self.node("stmt", "for step: " + self.stmt_text(step), step)
            ctx = LoopContext(after, step_node or d)
            body_out = self.block(body, [(d, "yes")], ctx, depth + 1)
            if step_node:
                self.connect(body_out, step_node)
                self.edge(step_node, d, "next", "back")
            else:
                for src, label in body_out:
                    self.edge(src, d, label or "next", "back")
            return [(after, None)] if cond is not None or ctx.break_used else []

        if k == "match":
            expr, arms = stmt.a
            d = self.node("decision", f"match {self.text(expr)}", stmt)
            self.connect(frontier, d)
            outs = []
            for pattern, arm in arms:
                outs += self.block(arm, [(d, self.text(pattern, pattern.kind))], loop, depth + 1)
            if not outs:
                return []
            m = self.node("merge", "after match", synthetic=True)
            self.connect(outs, m)
            return [(m, None)]

        terminal = k in {"return", "trap", "break", "continue"}
        n = self.node("terminal" if terminal else "stmt", self.stmt_text(stmt), stmt)
        self.connect(frontier, n)
        if k in {"return", "trap"}:
            self.edge(n, self.exit, k, "terminal")
            return []
        if k == "break":
            if loop:
                loop.break_used = True
                self.edge(n, loop.break_target, "break", "jump")
            return []
        if k == "continue":
            if loop:
                self.edge(n, loop.continue_target, "continue", "back")
            return []
        return [(n, None)]


def mermaid_escape(text: str) -> str:
    return text.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def dot_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render_cfg_mermaid(funcs) -> str:
    out = ["flowchart TD"]
    for fi, fn in enumerate(funcs):
        out.append(f'  subgraph sg{fi}["{mermaid_escape(fn.qualified_name)}"]')
        ids = {n.id: f"f{fi}_{n.id}" for n in fn.cfg_nodes}
        for n in fn.cfg_nodes:
            i, label = ids[n.id], mermaid_escape(n.label)
            if n.kind in {"entry", "exit"}: s = f'{i}(["{label}"])'
            elif n.kind == "decision": s = f'{i}{{"{label}"}}'
            elif n.kind == "terminal": s = f'{i}[["{label}"]]'
            elif n.kind == "merge": s = f'{i}(("{label}"))'
            else: s = f'{i}["{label}"]'
            out.append("    " + s)
        for e in fn.cfg_edges:
            label = f"|{mermaid_escape(e.label).replace('|', '/')}|" if e.label else ""
            out.append(f"    {ids[e.source]} -->{label} {ids[e.target]}")
        out.append("  end")
    return "\n".join(out) + "\n"


def render_cfg_dot(funcs) -> str:
    out = ["digraph l_cfg {", "  rankdir=TB;"]
    for fi, fn in enumerate(funcs):
        out += [f"  subgraph cluster_{fi} {{", f'    label="{dot_escape(fn.qualified_name)}";']
        ids = {n.id: f"f{fi}_{n.id}" for n in fn.cfg_nodes}
        for n in fn.cfg_nodes:
            shape = {"entry":"oval","exit":"oval","decision":"diamond","terminal":"box","merge":"circle"}.get(n.kind,"box")
            out.append(f'    {ids[n.id]} [shape={shape}, label="{dot_escape(n.label)}"];')
        for e in fn.cfg_edges:
            extra = f' [label="{dot_escape(e.label)}"]' if e.label else ""
            out.append(f"    {ids[e.source]} -> {ids[e.target]}{extra};")
        out.append("  }")
    return "\n".join(out + ["}"]) + "\n"


def call_edges(funcs):
    selected = {f.qualified_name for f in funcs}
    counts = {}
    for fn in funcs:
        for call in fn.calls:
            target = call.resolved or call.callee
            key = (fn.qualified_name, target, target in selected)
            counts[key] = counts.get(key, 0) + 1
    return [(a,b,internal,n) for (a,b,internal),n in sorted(counts.items())]


def render_calls_mermaid(funcs) -> str:
    edges = call_edges(funcs)
    internal = {f.qualified_name for f in funcs}
    names = sorted(internal | {b for _,b,_,_ in edges})
    ids = {n:f"c{i}" for i,n in enumerate(names)}
    out = ["flowchart LR"]
    for name in names:
        suffix = "" if name in internal else " (external/indirect)"
        out.append(f'  {ids[name]}["{mermaid_escape(name + suffix)}"]')
    for a,b,_,n in edges:
        label = f"|{n}|" if n > 1 else ""
        out.append(f"  {ids[a]} -->{label} {ids[b]}")
    return "\n".join(out) + "\n"


def render_calls_dot(funcs) -> str:
    edges = call_edges(funcs)
    internal = {f.qualified_name for f in funcs}
    names = sorted(internal | {b for _,b,_,_ in edges})
    ids = {n:f"c{i}" for i,n in enumerate(names)}
    out = ["digraph l_calls {", "  rankdir=LR;"]
    for name in names:
        out.append(f'  {ids[name]} [shape={"box" if name in internal else "ellipse"}, label="{dot_escape(name)}"];')
    for a,b,_,n in edges:
        label = f' [label="{n}"]' if n > 1 else ""
        out.append(f"  {ids[a]} -> {ids[b]}{label};")
    return "\n".join(out + ["}"]) + "\n"
