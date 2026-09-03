#!/usr/bin/env python3
from __future__ import annotations

import argparse,json,shutil,subprocess,sys
from pathlib import Path

from core import LangError,Program
from analysis_cfg import call_edges,render_calls_dot,render_calls_mermaid,render_cfg_dot,render_cfg_mermaid
from analysis_model import analyze_project,ast_value,select_functions


def report(project,funcs):
    out=[f"L code analysis: {'.'.join(project.entry_module)}",
         f"modules={len({f.module for f in funcs})} functions={len(funcs)} statements={sum(f.metrics['statements'] for f in funcs)} calls={sum(len(f.calls) for f in funcs)} bindings={sum(f.metrics['local_bindings'] for f in funcs)} rebound={sum(f.metrics['rebound_local_bindings'] for f in funcs)}",""]
    by={}
    for f in funcs:by.setdefault(f.module,[]).append(f)
    for mod in sorted(by):
        out.append("module "+".".join(mod))
        for f in by[mod]:
            p=", ".join(f"{x['name']}: {x['type']}" for x in f.params);m=f.metrics
            out.append(f"  fn {f.name}({p}) -> {f.return_type}  lines {f.line_start}-{f.line_end}")
            out.append(f"    statements={m['statements']} decisions={m['decisions']} loops={m['loops']} complexity={m['cyclomatic_complexity']} nesting={m['max_nesting']} returns={m['returns']} traps={m['traps']}")
            out.append(f"    local bindings={m['local_bindings']} rebound={m['rebound_local_bindings']} never-rebound={m['never_rebound_local_bindings']}")
            if f.calls:
                out.append("    calls: "+", ".join((c.resolved or c.callee)+(" [internal]" if c.internal else "") for c in f.calls))
            if f.unreachable_lines:out.append("    unreachable statements at lines: "+", ".join(map(str,f.unreachable_lines)))
        out.append("")
    return "\n".join(out).rstrip()+"\n"


def svg(dot):
    exe=shutil.which("dot")
    if exe is None:raise LangError("Graphviz 'dot' is required for --format svg; use dot or mermaid output without it")
    p=subprocess.run([exe,"-Tsvg"],input=dot,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode:raise LangError("Graphviz failed: "+p.stderr.strip())
    return p.stdout


def load_project(source,root,check,include_stdlib):
    from sdk_cli import cleanup,make_hosts,project_sources,stdlib_sources
    root=root or source.resolve().parent; sources,entry=project_sources(source.resolve(),root.resolve())
    if check:
        hosts,ph,th=make_hosts([])
        try:
            try:Program(sources,hosts)
            except LangError as e:
                mod=getattr(e,"module",None)
                if mod:
                    candidate=root.resolve().joinpath(*mod).with_suffix(".l")
                    if candidate.is_file():e.path=candidate
                    elif tuple(mod)==tuple(entry):e.path=source.resolve()
                raise
        finally:cleanup(ph,th)
    if not include_stdlib:
        std=set(stdlib_sources());sources={m:s for m,s in sources.items() if m not in std or m==entry}
    return sources,entry


def modes(ns,p):
    if sum(bool(x) for x in (ns.flowchart,ns.call_graph,ns.ast))>1:p.error("--flowchart, --call-graph, and --ast are mutually exclusive")
    view=ns.view;fmt=ns.format
    if ns.flowchart:view="cfg";fmt=fmt or "mermaid"
    elif ns.call_graph:view="calls";fmt=fmt or "mermaid"
    elif ns.ast:view="ast";fmt=fmt or "json"
    view=view or "report";fmt=fmt or {"report":"text","model":"json","ast":"json","cfg":"mermaid","calls":"mermaid"}[view]
    allowed={"report":{"text","json"},"model":{"json"},"ast":{"json"},"cfg":{"json","mermaid","dot","svg"},"calls":{"json","mermaid","dot","svg"}}
    if fmt not in allowed[view]:p.error(f"--view {view} does not support --format {fmt}")
    return view,fmt


def parser():
    p=argparse.ArgumentParser(prog="./lc analyze",description="L source analyzer: metrics, AST, call graphs, CFGs, and flowcharts")
    try:from cli_common import VERSION
    except Exception:VERSION="unknown"
    p.add_argument("--version",action="version",version=f"la {VERSION}")
    p.add_argument("source");p.add_argument("--root");p.add_argument("--view",choices=["report","model","ast","cfg","calls"])
    p.add_argument("--format",choices=["text","json","mermaid","dot","svg"]);p.add_argument("--flowchart",action="store_true")
    p.add_argument("--call-graph",action="store_true");p.add_argument("--ast",action="store_true");p.add_argument("--module");p.add_argument("--function")
    p.add_argument("--include-stdlib",action="store_true");p.add_argument("--no-check",action="store_true");p.add_argument("-o","--output")
    return p


def main(argv=None):
    p=parser();ns=p.parse_args(argv);view,fmt=modes(ns,p);source=Path(ns.source);root=Path(ns.root) if ns.root else None
    try:
        sources,entry=load_project(source,root,not ns.no_check,ns.include_stdlib);project=analyze_project(sources,entry);funcs=select_functions(project,ns.module,ns.function)
        if view=="report":
            out=report(project,funcs) if fmt=="text" else json.dumps({"entry_module":".".join(entry),"functions":[f.to_dict() for f in funcs]},indent=2,sort_keys=True)+"\n"
        elif view=="model":out=json.dumps(project.to_dict(),indent=2,sort_keys=True)+"\n"
        elif view=="ast":
            mods={f.module for f in funcs} if (ns.module or ns.function) else set(project.asts)
            out=json.dumps({"modules":{".".join(m):ast_value(project.asts[m]) for m in sorted(mods)}},indent=2,sort_keys=True)+"\n"
        elif view=="cfg":
            if fmt=="json":out=json.dumps({"functions":[f.to_dict() for f in funcs]},indent=2,sort_keys=True)+"\n"
            elif fmt=="mermaid":out=render_cfg_mermaid(funcs)
            else:
                dot=render_cfg_dot(funcs);out=svg(dot) if fmt=="svg" else dot
        else:
            if fmt=="json":out=json.dumps({"edges":[{"caller":a,"callee":b,"internal":i,"count":n} for a,b,i,n in call_edges(funcs)]},indent=2,sort_keys=True)+"\n"
            elif fmt=="mermaid":out=render_calls_mermaid(funcs)
            else:
                dot=render_calls_dot(funcs);out=svg(dot) if fmt=="svg" else dot
        if ns.output:Path(ns.output).write_text(out,encoding="utf-8")
        else:sys.stdout.write(out)
        return 0
    except LangError as e:
        try:
            from cli_common import emit_lang_error;emit_lang_error(e,source.resolve())
        except Exception:print(f"analysis error: {e}",file=sys.stderr)
        return 1

if __name__=="__main__":raise SystemExit(main())
