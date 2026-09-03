#!/usr/bin/env python3
from __future__ import annotations

"""Enforce L's const-by-default array parameter policy.

A mutable ``[]T`` parameter is an explicit capability. Repository code should
only request it when the body demonstrably needs to mutate the outer array,
forward that mutable capability to another known mutable parameter, or return
it through a mutable array result. If the need crosses an opaque boundary that
this source audit cannot prove, document it immediately above the function:

    // mutable-array buffer: host callback retains a mutable scratch buffer
    fn use(buffer: []u8) { ... }

Read-only parameters should be ``const []T``. Const is shallow, so mutation of
an inner ``[]T`` or through a ``ref T`` does not justify a mutable outer array.
"""

from dataclasses import dataclass
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bootstrap"))

from core import LangError, N, Parser, is_const_array  # noqa: E402

WAIVER_RE = re.compile(
    r"^\s*//\s*mutable-array\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(\S.*)\s*$"
)


@dataclass
class Module:
    path: Path
    source: str
    ast: N
    funcs: dict[str, N]
    imports: dict[str, tuple[str, ...]]


def is_mutable_array(ty) -> bool:
    return getattr(ty, "kind", None) == "array" and not is_const_array(ty)


def direct_name(node: object, name: str) -> bool:
    return (
        isinstance(node, N)
        and node.kind == "qname"
        and node.a
        and tuple(node.a[0]) == (name,)
    )


def l_files() -> list[Path]:
    out: list[Path] = []
    for path in ROOT.rglob("*.l"):
        rel = path.relative_to(ROOT)
        if any(part in {".git", "build"} for part in rel.parts):
            continue
        # notes/research contains deliberately preserved experiments written
        # against older candidate grammars. They are research artifacts, not
        # source accepted by the current L frontend, so current-language API
        # policy cannot be meaningfully enforced on them.
        if rel.parts[:2] == ("notes", "research"):
            continue
        out.append(path)
    return sorted(out)


def parse_modules(paths: list[Path]) -> dict[Path, Module]:
    modules: dict[Path, Module] = {}
    errors: list[str] = []
    for path in paths:
        source = path.read_text(encoding="utf-8")
        try:
            ast = Parser(source).program()
        except LangError as exc:
            errors.append(f"{path.relative_to(ROOT)}: cannot audit: {exc}")
            continue
        funcs: dict[str, N] = {}
        imports: dict[str, tuple[str, ...]] = {}
        for decl in ast.a[0]:
            if decl.kind == "fn":
                funcs[decl.a[1]] = decl
            elif decl.kind == "import":
                qname, alias = decl.a
                imports[alias or qname[-1]] = tuple(qname)
        modules[path] = Module(path, source, ast, funcs, imports)
    if errors:
        raise SystemExit("\n".join(errors))
    return modules


def resolve_import(
    module: Module,
    qname: tuple[str, ...],
    modules: dict[Path, Module],
    by_stem: dict[str, list[Path]],
) -> Module | None:
    candidates = [
        module.path.parent.joinpath(*qname).with_suffix(".l"),
        ROOT.joinpath(*qname).with_suffix(".l"),
    ]
    if len(qname) == 1:
        candidates.extend(
            [
                ROOT / "lib" / "portable" / f"{qname[0]}.l",
                ROOT / "lib" / "hosted" / f"{qname[0]}.l",
                ROOT / "tools" / "lsp" / f"{qname[0]}.l",
            ]
        )
    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate in modules:
            return modules[candidate]
    if len(qname) == 1:
        matches = by_stem.get(qname[0], [])
        if len(matches) == 1:
            return modules[matches[0]]
    return None


def waivers(module: Module, fn: N) -> dict[str, str]:
    lines = module.source.splitlines()
    line = (fn.span.line if fn.span else 1) - 2
    found: dict[str, str] = {}
    while line >= 0:
        text = lines[line]
        stripped = text.strip()
        if not stripped:
            line -= 1
            continue
        if not stripped.startswith("//"):
            break
        match = WAIVER_RE.match(text)
        if match:
            found[match.group(1)] = match.group(2)
        line -= 1
    return found


def callee_param_type(
    module: Module,
    callee: N,
    index: int,
    modules: dict[Path, Module],
    by_stem: dict[str, list[Path]],
):
    if callee.kind != "qname":
        return None
    qname = tuple(callee.a[0])
    target: Module | None = None
    fn_name: str | None = None
    if len(qname) == 1:
        target = module
        fn_name = qname[0]
    elif qname[0] in module.imports:
        target = resolve_import(module, module.imports[qname[0]], modules, by_stem)
        fn_name = qname[-1]
    if target is None or fn_name is None:
        return None
    fn = target.funcs.get(fn_name)
    if fn is None:
        return None
    params = fn.a[3]
    if index >= len(params):
        return None
    return params[index][1]


def audit_function(
    module: Module,
    fn: N,
    modules: dict[Path, Module],
    by_stem: dict[str, list[Path]],
) -> list[str]:
    _public, fn_name, _gps, params, ret, body = fn.a
    mutable = {name for name, ty in params if is_mutable_array(ty)}
    if not mutable:
        return []

    reasons: dict[str, list[str]] = {name: [] for name in mutable}
    opaque: dict[str, list[str]] = {name: [] for name in mutable}

    def reason(name: str, text: str) -> None:
        if text not in reasons[name]:
            reasons[name].append(text)

    def escape(name: str, text: str) -> None:
        if text not in opaque[name]:
            opaque[name].append(text)

    def walk_expr(node: object) -> None:
        if not isinstance(node, N):
            return
        if node.kind == "call":
            callee, args = node.a
            callee_name = None
            if isinstance(callee, N) and callee.kind == "qname":
                q = tuple(callee.a[0])
                callee_name = ".".join(q)
                if len(q) == 1 and q[0] in {"push", "pop", "splice"} and args:
                    for name in mutable:
                        if direct_name(args[0], name):
                            reason(name, f"target of {q[0]}()")
            for index, arg in enumerate(args):
                for name in mutable:
                    if not direct_name(arg, name):
                        continue
                    # Builtin target mutation was handled above. len() and the
                    # splice replacement only read their arguments.
                    if callee_name == "len":
                        continue
                    if callee_name == "splice" and index == 3:
                        continue
                    if callee_name in {"push", "pop", "splice"} and index == 0:
                        continue
                    target_ty = callee_param_type(module, callee, index, modules, by_stem)
                    if target_ty is None:
                        escape(name, f"argument {index + 1} to opaque {callee_name or 'call'}")
                    elif is_mutable_array(target_ty):
                        reason(name, f"forwarded to mutable parameter {index + 1} of {callee_name}")
            walk_expr(callee)
            for arg in args:
                walk_expr(arg)
            return
        for item in node.a:
            walk_value(item)

    def walk_stmt(node: N) -> None:
        if node.kind == "assign":
            lhs, _op, rhs = node.a
            if isinstance(lhs, N) and lhs.kind == "index":
                base = lhs.a[0]
                for name in mutable:
                    # Only replacing a slot of the outer parameter needs its
                    # mutable capability. param[i][j] mutates an inner array and
                    # remains legal through const [][]T.
                    if direct_name(base, name):
                        reason(name, "outer array slot assignment")
            walk_expr(lhs)
            walk_expr(rhs)
            return
        if node.kind == "return":
            value = node.a[0]
            if is_mutable_array(ret):
                for name in mutable:
                    if direct_name(value, name):
                        reason(name, "returned as mutable array capability")
            walk_expr(value)
            return
        if node.kind == "var":
            _name, declared, value = node.a
            if declared is not None and is_mutable_array(declared):
                for name in mutable:
                    if direct_name(value, name):
                        reason(name, "bound into explicitly mutable local")
            walk_expr(value)
            return
        if node.kind == "for":
            init, cond, step, nested = node.a
            if isinstance(init, N):
                walk_stmt(init)
            walk_expr(cond)
            if isinstance(step, N):
                walk_stmt(step)
            for stmt in nested:
                walk_stmt(stmt)
            return
        if node.kind in {"if", "while", "forin", "match"}:
            # Generic recursion is sufficient here; statement nodes reached
            # through tuples are dispatched by walk_value().
            for item in node.a:
                walk_value(item)
            return
        if node.kind == "exprstmt":
            walk_expr(node.a[0])
            return
        # break/continue/trap and any future statement form: recursively inspect
        # child expressions/statements rather than silently ignoring them.
        for item in node.a:
            walk_value(item)

    def walk_value(value: object) -> None:
        if isinstance(value, N):
            if value.kind in {
                "assign", "return", "var", "for", "if", "while", "forin",
                "match", "exprstmt", "break", "continue", "trap"
            }:
                walk_stmt(value)
            else:
                walk_expr(value)
        elif isinstance(value, (tuple, list)):
            for item in value:
                walk_value(item)

    for stmt in body:
        walk_stmt(stmt)

    documented = waivers(module, fn)
    failures: list[str] = []
    rel = module.path.relative_to(ROOT)
    for name in sorted(mutable):
        if reasons[name]:
            continue
        if name in documented:
            continue
        where = f"{rel}:{fn.span.line if fn.span else '?'}: {fn_name}({name}: ...)"
        if opaque[name]:
            failures.append(
                f"{where}: mutable []T is not proven necessary; "
                f"opaque escape(s): {', '.join(opaque[name])}. Make it const or add "
                f"`// mutable-array {name}: <reason>` immediately above the function."
            )
        else:
            failures.append(
                f"{where}: mutable []T is never used as a mutable outer-array capability; "
                "use const []T."
            )
    return failures


def run(paths: list[Path]) -> list[str]:
    modules = parse_modules(paths)
    by_stem: dict[str, list[Path]] = {}
    for path in modules:
        by_stem.setdefault(path.stem, []).append(path)
    failures: list[str] = []
    for path in sorted(modules):
        module = modules[path]
        for fn in module.funcs.values():
            failures.extend(audit_function(module, fn, modules, by_stem))
    return failures


def self_test() -> None:
    samples = {
        "read": "fn f(xs: []u8) -> u64 { return len(xs); }",
        "write": "fn f(xs: []u8) { xs[0] = 1; }",
        "inner": "fn f(xs: [][]u8) { xs[0][0] = 1; }",
        "waive": "// mutable-array xs: opaque host retains it\nfn f(xs: []u8) { host.use(xs); }",
    }
    failures = {}
    for name, source in samples.items():
        path = ROOT / f".__const_policy_{name}.l"
        ast = Parser(source).program()
        funcs = {decl.a[1]: decl for decl in ast.a[0] if decl.kind == "fn"}
        imports = {}
        module = Module(path, source, ast, funcs, imports)
        # No cross-module calls are required in these focused cases.
        failures[name] = audit_function(module, funcs["f"], {path: module}, {path.stem: [path]})
    assert failures["read"], failures
    assert not failures["write"], failures
    assert failures["inner"], failures
    assert not failures["waive"], failures


def main() -> int:
    if "--self-test" in sys.argv:
        self_test()
        print("const-by-default policy self-test PASS")
        return 0
    failures = run(l_files())
    if failures:
        print("const-by-default policy violations:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("const-by-default array parameter policy PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
