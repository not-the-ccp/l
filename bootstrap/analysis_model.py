from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Iterable

from core import N, Parser
from analysis_cfg import CFGBuilder

STMT_KINDS = {"var","if","while","for","forin","match","return","break","continue","trap","assign","exprstmt"}


@dataclass
class CallSite:
    callee: str
    line: int | None
    col: int | None
    resolved: str | None = None
    internal: bool = False


@dataclass
class LocalBinding:
    name: str
    line: int | None
    type: str | None
    reassignments: int = 0

    def to_dict(self):
        return {**asdict(self), "reassigned": self.reassignments > 0}


@dataclass
class FunctionAnalysis:
    module: tuple[str, ...]
    name: str
    params: list[dict[str, str]]
    return_type: str
    line_start: int | None
    line_end: int | None
    metrics: dict[str, int]
    calls: list[CallSite]
    bindings: list[LocalBinding]
    cfg_nodes: list[Any]
    cfg_edges: list[Any]
    unreachable_lines: list[int]
    anonymous: bool = False

    @property
    def qualified_name(self):
        return f"{'.'.join(self.module)}::{self.name}"

    def to_dict(self):
        return {
            "name":self.name,"qualified_name":self.qualified_name,"module":".".join(self.module),"anonymous":self.anonymous,
            "params":self.params,"return_type":self.return_type,"line_start":self.line_start,"line_end":self.line_end,
            "metrics":dict(self.metrics),"calls":[asdict(x) for x in self.calls],"bindings":[x.to_dict() for x in self.bindings],
            "unreachable_lines":list(self.unreachable_lines),
            "cfg":{"nodes":[asdict(x) for x in self.cfg_nodes],"edges":[asdict(x) for x in self.cfg_edges]},
        }


@dataclass
class ModuleAnalysis:
    name: tuple[str, ...]
    imports: dict[str, tuple[str, ...]]
    declarations: dict[str, int]
    functions: list[FunctionAnalysis] = field(default_factory=list)
    def to_dict(self):
        return {"name":".".join(self.name),"imports":{k:".".join(v) for k,v in sorted(self.imports.items())},
                "declarations":dict(sorted(self.declarations.items())),"functions":[f.to_dict() for f in self.functions]}


@dataclass
class ProjectAnalysis:
    entry_module: tuple[str, ...]
    modules: list[ModuleAnalysis]
    asts: dict[tuple[str, ...], N] = field(repr=False)
    @property
    def functions(self): return [f for m in self.modules for f in m.functions]
    def to_dict(self):
        fs=self.functions
        return {"entry_module":".".join(self.entry_module),"summary":{"modules":len(self.modules),"functions":len(fs),
                "statements":sum(f.metrics["statements"] for f in fs),"decisions":sum(f.metrics["decisions"] for f in fs),
                "loops":sum(f.metrics["loops"] for f in fs),"calls":sum(len(f.calls) for f in fs),
                "local_bindings":sum(f.metrics["local_bindings"] for f in fs),
                "rebound_local_bindings":sum(f.metrics["rebound_local_bindings"] for f in fs),
                "unreachable_statements":sum(len(f.unreachable_lines) for f in fs)},"modules":[m.to_dict() for m in self.modules]}


def children(value: Any) -> Iterable[N]:
    if isinstance(value,N): yield value
    elif isinstance(value,(tuple,list)):
        for x in value: yield from children(x)
    elif isinstance(value,dict):
        for x in value.values(): yield from children(x)


def walk(node:N, descend_anon=False):
    yield node
    if node.kind=="anonfn" and not descend_anon: return
    for child in children(node.a): yield from walk(child,descend_anon)


def callee_name(callee:N):
    if callee.kind=="qname": return ".".join(callee.a[0])
    if callee.kind=="field":
        base,name=callee.a; p=callee_name(base)
        if p!="<indirect>": return p+"."+name
    return "<indirect>"


def collect_calls(body):
    out=[]
    for stmt in body:
        for n in walk(stmt):
            if n.kind=="call":
                sp=getattr(n,"span",None)
                out.append(CallSite(callee_name(n.a[0]),getattr(sp,"line",None),getattr(sp,"col",None)))
    return out


def direct_local_name(node):
    if isinstance(node,N) and node.kind=="qname":
        parts=node.a[0]
        if len(parts)==1:return parts[0]
    return None


def collect_bindings(body):
    """Measure explicit `var` bindings, not mutation reachable through them.

    L has no shadowing, so a function-local name identifies one declaration.
    `x = ...` rebinds x; `x[i] = ...`, `x.field = ...`, and mutation through a
    referenced object do not. Anonymous functions are analyzed separately.
    """
    bindings=[]; by_name={}
    for stmt in body:
        for n in walk(stmt):
            if n.kind=="var":
                name,ty,_=n.a; sp=getattr(n,"span",None)
                binding=LocalBinding(name,getattr(sp,"line",None),None if ty is None else str(ty))
                bindings.append(binding);by_name[name]=binding
    for stmt in body:
        for n in walk(stmt):
            if n.kind!="assign":continue
            name=direct_local_name(n.a[0])
            if name in by_name:by_name[name].reassignments+=1
    return bindings


def metrics(body,max_nesting,bindings):
    c={k:0 for k in STMT_KINDS}; match_extra=0; short=0
    for stmt in body:
        for n in walk(stmt):
            if n.kind in c: c[n.kind]+=1
            if n.kind=="match": match_extra += max(0,len(n.a[1])-1)
            if n.kind=="binary" and n.a[0] in ("&&","||"): short+=1
    decisions=c["if"]+c["while"]+c["for"]+c["forin"]+match_extra
    rebound=sum(x.reassignments>0 for x in bindings)
    return {"statements":sum(c.values()),"decisions":decisions,"loops":c["while"]+c["for"]+c["forin"],"matches":c["match"],
            "returns":c["return"],"traps":c["trap"],"breaks":c["break"],"continues":c["continue"],
            "short_circuit_ops":short,"cyclomatic_complexity":1+decisions,"max_nesting":max_nesting,
            "local_bindings":len(bindings),"rebound_local_bindings":rebound,
            "never_rebound_local_bindings":len(bindings)-rebound}


def find_anons(body):
    out=[]
    for stmt in body:
        stack=[stmt]
        while stack:
            n=stack.pop()
            if n.kind=="anonfn": out.append(n); continue
            stack.extend(reversed(list(children(n.a))))
    return out


def analyze_fn(module,name,params,ret,body,node,source,anonymous=False):
    cfg=CFGBuilder(source); nodes,edges,unreachable,nesting=cfg.build(body); sp=getattr(node,"span",None);bindings=collect_bindings(body)
    fn=FunctionAnalysis(module,name,[{"name":n,"type":str(t)} for n,t in params],str(ret),getattr(sp,"line",None),getattr(sp,"end_line",None),
                        metrics(body,nesting,bindings),collect_calls(body),bindings,nodes,edges,unreachable,anonymous)
    nested=[]
    for anon in find_anons(body):
        a=getattr(anon,"span",None); nested.append((f"{name}::<anon@{getattr(a,'line','?')}:{getattr(a,'col','?')}>",anon))
    return fn,nested


def analyze_project(sources,entry):
    modules=[]; asts={}
    for modname in sorted(sources):
        source=sources[modname]; ast=Parser(source).program(); asts[modname]=ast
        m=ModuleAnalysis(modname,{},{}); modules.append(m); pending=[]
        for d in ast.a[0]:
            m.declarations[d.kind]=m.declarations.get(d.kind,0)+1
            if d.kind=="import":
                q,alias=d.a; m.imports[alias or q[-1]]=tuple(q)
            elif d.kind=="fn":
                _,name,_,params,ret,body=d.a; fn,nested=analyze_fn(modname,name,params,ret,body,d,source); m.functions.append(fn); pending+=nested
        while pending:
            name,anon=pending.pop(0); params,ret,body=anon.a
            fn,nested=analyze_fn(modname,name,params,ret,body,anon,source,True); m.functions.append(fn); pending+=nested
    p=ProjectAnalysis(entry,modules,asts); resolve_calls(p); return p


def resolve_calls(project):
    index={f.qualified_name for f in project.functions}
    for m in project.modules:
        local={f.name for f in m.functions if "::<anon@" not in f.name}
        for fn in m.functions:
            for c in fn.calls:
                if c.callee=="<indirect>": continue
                parts=c.callee.split("."); target=None
                if len(parts)==1 and parts[0] in local: target=f"{'.'.join(m.name)}::{parts[0]}"
                elif len(parts)>=2 and parts[0] in m.imports: target=f"{'.'.join(m.imports[parts[0]])}::{'.'.join(parts[1:])}"
                elif len(parts)>=2: target=f"{'.'.join(parts[:-1])}::{parts[-1]}"
                else: target=c.callee
                c.resolved=target; c.internal=target in index


def ast_value(value):
    if isinstance(value,N):
        sp=getattr(value,"span",None)
        span=None if sp is None else {"start":sp.start,"end":sp.end,"line":sp.line,"col":sp.col,"end_line":sp.end_line,"end_col":sp.end_col}
        return {"kind":value.kind,"span":span,"type":None if getattr(value,"ty",None) is None else str(value.ty),"args":[ast_value(x) for x in value.a]}
    if isinstance(value,(tuple,list)): return [ast_value(x) for x in value]
    if isinstance(value,bytes): return {"bytes_hex":value.hex()}
    if hasattr(value,"kind") and value.__class__.__name__=="Ty": return str(value)
    if isinstance(value,(str,int,float,bool)) or value is None: return value
    return str(value)


def select_functions(project,module=None,function=None):
    from core import LangError
    fs=project.functions
    if module:
        fs=[f for f in fs if ".".join(f.module)==module]
        if not fs: raise LangError(f"analysis module not found: {module}")
    if function:
        exact=[f for f in fs if f.qualified_name==function]
        if exact: return exact
        simple=[f for f in fs if f.name==function]
        if len(simple)==1:return simple
        if not simple:raise LangError(f"analysis function not found: {function}")
        raise LangError(f"analysis function name is ambiguous: {function} ({', '.join(f.qualified_name for f in simple)})")
    return fs
