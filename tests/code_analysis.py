#!/usr/bin/env python3
from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bootstrap"))

from analyze import analyze_project, report, render_calls_mermaid, render_cfg_dot, render_cfg_mermaid

SOURCE = r'''
fn helper(x: i32) -> i32 {
    if (x > 0) {
        return x;
    } else {
        return 0;
    }
}

fn main() -> i32 {
    var i: i32 = 0;
    var once: i32 = 7;
    var cells: []i32 = [0];
    cells[0] = once;
    while (i < 3) {
        if (i == 1) {
            i += 1;
            continue;
        }
        i += 1;
    }
    return helper(i);
    i += 100;
}
'''

p = analyze_project({("main",): SOURCE}, ("main",))
assert len(p.modules) == 1
assert len(p.functions) == 2
main = next(f for f in p.functions if f.name == "main")
helper = next(f for f in p.functions if f.name == "helper")

assert main.metrics["loops"] == 1, main.metrics
assert main.metrics["decisions"] == 2, main.metrics
assert main.metrics["cyclomatic_complexity"] == 3, main.metrics
assert main.metrics["continues"] == 1, main.metrics
assert main.unreachable_lines, main.to_dict()
assert any(c.resolved == "main::helper" and c.internal for c in main.calls), main.calls
assert helper.metrics["cyclomatic_complexity"] == 2, helper.metrics

# Binding mutation is intentionally narrower than place/referent mutation.
# Direct assignment to i counts as rebinding. Updating cells[0] does not make
# the `cells` binding mutable, and `once` is never rebound either.
assert main.metrics["local_bindings"] == 3, main.metrics
assert main.metrics["rebound_local_bindings"] == 1, main.metrics
assert main.metrics["never_rebound_local_bindings"] == 2, main.metrics
bindings = {b.name: b for b in main.bindings}
assert bindings["i"].reassignments == 3, bindings
assert bindings["once"].reassignments == 0, bindings
assert bindings["cells"].reassignments == 0, bindings
model = p.to_dict()
assert model["summary"]["local_bindings"] == 3, model["summary"]
assert model["summary"]["rebound_local_bindings"] == 1, model["summary"]
main_json = next(f for f in model["modules"][0]["functions"] if f["name"] == "main")
assert next(b for b in main_json["bindings"] if b["name"] == "i")["reassigned"] is True
assert next(b for b in main_json["bindings"] if b["name"] == "cells")["reassigned"] is False
text = report(p, p.functions)
assert "bindings=3 rebound=1" in text, text
assert "local bindings=3 rebound=1 never-rebound=2" in text, text

mmd = render_cfg_mermaid([main])
assert "flowchart TD" in mmd
assert "while i &lt; 3" in mmd, mmd
assert "|continue|" in mmd, mmd
assert "main::main" in mmd

dot = render_cfg_dot([main])
assert "digraph l_cfg" in dot
assert "diamond" in dot

calls = render_calls_mermaid(p.functions)
assert "flowchart LR" in calls
assert "main::helper" in calls
assert "main::main" in calls

print("code analysis PASS")
