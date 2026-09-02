#!/usr/bin/env python3
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path


def load(path: Path):
    sessions = []
    current = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        row = json.loads(raw)
        if row.get("type") == "session":
            current = {"meta": row, "events": []}
            sessions.append(current)
        elif row.get("type") == "key":
            if current is None:
                current = {"meta": {"type": "session", "task": ""}, "events": []}
                sessions.append(current)
            current["events"].append(row)
    return sessions


def is_text_mode(mode: str) -> bool:
    return mode.startswith(("i", "R", "r", "c"))


def chosen_key(event: dict) -> str:
    return event.get("typed") or event.get("mapped") or "<none>"


def operational(events):
    return [e for e in events if not is_text_mode(e.get("mode", ""))]


def ngrams(items, n):
    counter = collections.Counter()
    for i in range(len(items) - n + 1):
        counter[tuple(items[i : i + n])] += 1
    return counter


def repeated_runs(events):
    runs = collections.Counter()
    if not events:
        return runs
    last = (events[0].get("mode", ""), chosen_key(events[0]))
    count = 1
    for event in events[1:]:
        cur = (event.get("mode", ""), chosen_key(event))
        if cur == last:
            count += 1
        else:
            if count >= 2:
                runs[(last[0], last[1], count)] += 1
            last = cur
            count = 1
    if count >= 2:
        runs[(last[0], last[1], count)] += 1
    return runs


def movement_by_key(events):
    data = collections.defaultdict(lambda: [0, 0, 0, 0])
    for a, b in zip(events, events[1:]):
        if is_text_mode(a.get("mode", "")):
            continue
        dl = int(b.get("line", 0)) - int(a.get("line", 0))
        dc = int(b.get("col", 0)) - int(a.get("col", 0))
        key = (a.get("mode", ""), chosen_key(a))
        row = data[key]
        row[0] += 1
        row[1] += dl
        row[2] += abs(dl)
        row[3] += abs(dc)
    return data


def top(counter, limit):
    return counter.most_common(limit)


def summarize(session):
    events = session["events"]
    ops = operational(events)
    op_tokens = [f"{e.get('mode', '')}:{chosen_key(e)}" for e in ops]
    modes = [e.get("mode", "") for e in events]
    mode_transitions = collections.Counter(zip(modes, modes[1:]))
    key_counts = collections.Counter((e.get("mode", ""), chosen_key(e)) for e in ops)
    typed_counts = collections.Counter(chosen_key(e) for e in events if is_text_mode(e.get("mode", "")))

    elapsed = 0.0
    if events:
        elapsed = float(events[-1].get("time_ms", 0.0)) - float(events[0].get("time_ms", 0.0))

    return {
        "task": session["meta"].get("task", ""),
        "editor": session["meta"].get("editor", ""),
        "event_count": len(events),
        "operational_event_count": len(ops),
        "elapsed_ms": elapsed,
        "keys": key_counts,
        "text_keys": typed_counts,
        "bigrams": ngrams(op_tokens, 2),
        "trigrams": ngrams(op_tokens, 3),
        "runs": repeated_runs(ops),
        "mode_transitions": mode_transitions,
        "movement": movement_by_key(events),
    }


def print_counter(title, counter, limit=20):
    print(f"\n{title}")
    for key, count in top(counter, limit):
        if isinstance(key, tuple):
            label = " -> ".join(str(x) for x in key)
        else:
            label = str(key)
        print(f"  {count:6d}  {label}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Summarize Lace keymap dogfood telemetry")
    ap.add_argument("logs", nargs="+", type=Path)
    ap.add_argument("--top", type=int, default=25)
    ns = ap.parse_args()

    all_sessions = []
    for path in ns.logs:
        all_sessions.extend(load(path))

    aggregate_keys = collections.Counter()
    aggregate_bigrams = collections.Counter()
    aggregate_trigrams = collections.Counter()
    aggregate_runs = collections.Counter()
    aggregate_modes = collections.Counter()
    aggregate_movement = collections.defaultdict(lambda: [0, 0, 0, 0])

    print("Lace keymap dogfood telemetry")
    for session in all_sessions:
        summary = summarize(session)
        print(
            f"  task={summary['task'] or '-'} editor={summary['editor'] or '-'} "
            f"events={summary['event_count']} ops={summary['operational_event_count']} "
            f"elapsed={summary['elapsed_ms'] / 1000.0:.2f}s"
        )
        aggregate_keys.update(summary["keys"])
        aggregate_bigrams.update(summary["bigrams"])
        aggregate_trigrams.update(summary["trigrams"])
        aggregate_runs.update(summary["runs"])
        aggregate_modes.update(summary["mode_transitions"])
        for key, row in summary["movement"].items():
            dst = aggregate_movement[key]
            for i, value in enumerate(row):
                dst[i] += value

    print_counter("Operational keys", aggregate_keys, ns.top)
    print_counter("Operational bigrams", aggregate_bigrams, ns.top)
    print_counter("Operational trigrams", aggregate_trigrams, ns.top)
    print_counter("Repeated-key runs", aggregate_runs, ns.top)
    print_counter("Mode transitions", aggregate_modes, ns.top)

    print("\nObserved cursor movement by preceding operational key")
    movement_rows = sorted(aggregate_movement.items(), key=lambda kv: (-kv[1][0], kv[0]))
    for (mode, key), (count, signed_lines, abs_lines, abs_cols) in movement_rows[: ns.top]:
        print(
            f"  {count:6d}  {mode}:{key:<12} "
            f"mean_line={signed_lines / count:+.2f} "
            f"mean_abs_line={abs_lines / count:.2f} "
            f"mean_abs_col={abs_cols / count:.2f}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
