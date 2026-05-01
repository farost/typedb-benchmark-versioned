#!/usr/bin/env python3
"""
Compare two or more bench.py JSON summary files.

Usage:
    ./compare.py results/master.json results/cluster.json
    ./compare.py results/*.json
"""

from __future__ import annotations

import json
import sys


def fmt_pct(a: float, b: float) -> str:
    """Return percentage delta of b vs a, signed."""
    if a == 0:
        return "—"
    delta = (b - a) / a * 100.0
    sign = "+" if delta >= 0 else ""
    return f"{sign}{delta:.1f}%"


def load(path: str) -> dict:
    with open(path) as f:
        d = json.load(f)
    d.setdefault("label", path.rsplit("/", 1)[-1].replace(".json", ""))
    return d


def header(*labels: str) -> None:
    cols = ["metric"] + list(labels)
    if len(labels) >= 2:
        cols.append(f"Δ vs {labels[0]}")
    print(" | ".join(f"{c:>22}" for c in cols))
    print(" | ".join("-" * 22 for _ in cols))


def row(name: str, summaries: list, getter, *, fmt="{:>10.2f}", unit="") -> None:
    cells = [name]
    base = getter(summaries[0])
    for s in summaries:
        v = getter(s)
        cells.append(fmt.format(v) + (f" {unit}" if unit else ""))
    if len(summaries) >= 2:
        cells.append(fmt_pct(base, getter(summaries[-1])))
    print(" | ".join(f"{c:>22}" for c in cells))


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: compare.py FILE [FILE ...]\n")
        return 2

    summaries = [load(p) for p in sys.argv[1:]]
    labels = [s["label"] for s in summaries]

    header(*labels)
    row("elapsed (s)", summaries, lambda s: s["elapsed_seconds"])
    row("",            summaries, lambda s: 0, fmt="{:>10}")
    row("total ops/s", summaries, lambda s: s["results"]["total_ops_per_sec"])
    row("NewOrder ops/s", summaries, lambda s: s["results"]["new_order"]["ops_per_sec"])
    row("NewOrder avg ms", summaries, lambda s: s["results"]["new_order"]["avg_latency_ms"])
    row("Payment ops/s", summaries, lambda s: s["results"]["payment"]["ops_per_sec"])
    row("Payment avg ms", summaries, lambda s: s["results"]["payment"]["avg_latency_ms"])
    row("Stock ops/s",   summaries, lambda s: s["results"]["stock"]["ops_per_sec"])
    row("Stock avg ms",  summaries, lambda s: s["results"]["stock"]["avg_latency_ms"])
    row("",              summaries, lambda s: 0, fmt="{:>10}")
    row("total errors",  summaries, lambda s: s["results"]["total_err"], fmt="{:>10d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
