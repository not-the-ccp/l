#!/usr/bin/env python3
from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bootstrap"))

from analyze import analyze_project, render_calls_mermaid, render_cfg_dot, render_cfg_mermaid

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
